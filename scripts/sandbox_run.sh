#!/bin/bash
# 沙盒端定时任务的一键入口：完整性自检 → 凭证拉取 → 执行签到
# 用法: sandbox_run.sh [verify]   参数原样透传给 checkin.sh（verify 为晚间核验模式）
# 自包含、无状态（手册 §6.10.1）：每次运行假设是全新沙箱，不依赖任何上次残留；
# 本体损坏自检靠 check_integrity.sh（缺失时不自行重装，那是 Agent 的职责）；
# 凭证跨实例持久靠资料库（fetch_creds_from_library.sh 按需拉取）
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用）
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"
LOG_FILE="$DIR/logs/sandbox_run.log"
mkdir -p "$DIR/logs"

# 带时间戳的日志：终端可见 + 落 sandbox_run.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# 参数解析：--quiet / -q 只保留「开始 / 关键结果 / 结尾」三类输出，过程细节全部落日志。
# 云端定时任务用它把一次运行的终端输出压到十几行，省模型 context（即省积分）；
# 参数解析后再 set --，因此 --quiet 不会被当成 mode 误传给 checkin.sh。
QUIET=0
_ARGS=()
for _a in "$@"; do
  case "$_a" in
    --quiet|-q) QUIET=1 ;;
    *) _ARGS+=("$_a") ;;
  esac
done
set -- ${_ARGS[@]+"${_ARGS[@]}"}

# 运行子命令并同时写入日志；返回子命令自身的退出码（tee 不掩盖真实状态）
runlog() {
  local rc=0
  if [ "$QUIET" = "1" ]; then
    "$@" >>"$LOG_FILE" 2>&1          # 静默：细节只进日志，终端不刷屏（云端调用省 context）
    rc=$?
  else
    "$@" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

# 凭证回写资料库（签到跑完后调用，统一发起并收尾）
# 软失败模式（WB_PUSHBACK_SOFTFAIL=1）下 push 脚本退出码恒为 0、无法靠退出码分辨成败，
# 成败以 .rt_snapshot 是否已与 refresh_token 对齐为准——push 脚本只在"上传 + node-info 复查通过"后
# 才会更新快照，因此快照对齐 ⇔ 回写成功（fetch_creds_from_library.sh 导入时写入同一快照，约定一致）
pushback() {
  runlog env WB_PUSHBACK_SOFTFAIL=1 bash "$DIR/scripts/push_creds_to_library.sh"
  if [ -s "$CONFIG_DIR/.rt_snapshot" ] && [ "$(cat "$CONFIG_DIR/refresh_token")" = "$(cat "$CONFIG_DIR/.rt_snapshot")" ]; then
    log "凭证已回写资料库，.rt_snapshot 已与当前 refresh_token 对齐"
  else
    log "WARN: 凭证回写未完成——资料库中的凭证不会更新，长效凭证（refresh token）到期后需人工在本机重新生成上传；下次运行将自动重试"
  fi
}

log "==== sandbox_run 开始（参数: $*） ===="

# 1. 完整性自检：不通过即报错退出；不自行重装（重装是 Agent 的职责）
if ! runlog bash "$DIR/scripts/check_integrity.sh"; then
  log "ERROR: skill 本体缺失或损坏（check_integrity.sh 未通过），需重新安装；缺损清单见上方输出"
  echo "==> skill 本体缺失或损坏，需重新安装（本脚本不会自动重装）" >&2
  exit 1
fi

PY="$(command -v python3 || command -v python || command -v py)"

# 打印凭证身份摘要（sid + 过期日）：不打印 token 本身。
# 排查"401 到底是过期还是会话被换"时，sid 是最快的判据——本机与资料库比一个 sid 就够。
token_id() {
  [ -s "$CONFIG_DIR/token" ] || { echo "（无 token）"; return; }
  "$PY" - "$CONFIG_DIR/token" <<'PYEOF' 2>/dev/null || echo "（解析失败）"
import sys, base64, json, time
try:
    t = open(sys.argv[1]).read().strip()
    p = t.split('.')[1]
    p += '=' * ((4 - len(p) % 4) % 4)
    d = json.loads(base64.urlsafe_b64decode(p))
    exp = d.get('exp') or 0
    print('sid=%s exp=%s' % (d.get('sid') or '-',
          time.strftime('%Y-%m-%d', time.localtime(exp)) if exp else '-'))
except Exception:
    print('（解析失败）')
PYEOF
}

# 凭证有效性预检：0=可用 / 1=被服务端拒绝（失效或会话被换）/ 2=无法判定（网络问题）
# 关键：会话被服务端销毁时（如客户端升级/重登后），refresh token 也会报 invalid_grant，
# 各分支内部的自动续期**必然失败**。所以必须在跑签到前先探活，失效就强制从资料库重拉，
# 否则实例里残留的旧凭证会让整轮静默 401。
probe_token() {
  local code body hdr head1
  [ -s "$CONFIG_DIR/token" ] || return 1
  hdr=$(mktemp) || return 2
  body=$(mktemp) || { rm -f "$hdr"; return 2; }
  # 敏感头走文件，避免凭证出现在 curl 进程 argv
  printf 'Authorization: Bearer %s\nX-User-Id: %s\nX-Domain: www.workbuddy.cn\n' \
    "$(cat "$CONFIG_DIR/token")" "$(cat "$CONFIG_DIR/user_id" 2>/dev/null)" > "$hdr"
  code=$(curl -s -o "$body" -w '%{http_code}' --max-time 20 \
    "https://www.workbuddy.cn/activity/growth/buddy/travel/status" \
    -H @"$hdr" -H 'Accept: application/json' 2>/dev/null) || code=000
  head1=$(head -c 1 "$body" 2>/dev/null)
  rm -f "$hdr" "$body"
  case "$code" in
    401|403) return 1 ;;
    200) [ "$head1" = "{" ] && return 0 || return 1 ;;   # 200 但返回 HTML = 网关拦截页
    *) return 2 ;;
  esac
}

# 2. 凭证就绪：存在且探活通过直接跑；缺失或被拒则从资料库重拉，拉完再验
FETCHED=0
if [ ! -s "$CONFIG_DIR/token" ]; then
  log "config/token 不存在，从资料库拉取凭证..."
  FETCHED=1
else
  log "config/token 存在（$(token_id)），探活校验..."
  probe_token
  case $? in
    0) log "凭证探活通过，直接运行签到（续期由各分支内部处理）" ;;
    1) log "WARN: 凭证被服务端拒绝（401/403 或网关拦截页），判定为失效；改为强制从资料库重新拉取"
       FETCHED=1 ;;
    2) log "WARN: 凭证探活无法判定（网络异常或无响应），按原流程继续" ;;
  esac
fi

if [ "$FETCHED" = "1" ]; then
  if ! runlog bash "$DIR/scripts/fetch_creds_from_library.sh"; then
    log "ERROR: 从资料库拉取凭证失败，请检查资料库"
    echo "==> 凭证拉取失败：请检查资料库（我的资料）中是否存在 sandbox-creds-WB2.txt" >&2
    exit 1
  fi
  log "凭证已从资料库导入（$(token_id)），复验中..."
  probe_token
  case $? in
    0) log "凭证复验通过" ;;
    1) log "ERROR: 刚拉取的凭证仍被服务端拒绝 —— 这不是过期，是登录会话已被服务端销毁（客户端升级/重新登录/换设备）"
       log "ERROR: 在线续期不可能救回（refresh token 同样会报 invalid_grant），必须回本机重取后重新上传资料库"
       echo "==> 凭证会话已失效：请在 PC 端重跑取证脚本生成新凭证 → make_cred_file.sh → 上传资料库沙盒标识节点" >&2
       exit 1 ;;
    2) log "WARN: 复验未能判定（网络异常），继续运行" ;;
  esac
fi

# 3. 执行签到，透传退出码
log "执行签到: checkin.sh $*"
CHECK_OUT="$(mktemp 2>/dev/null || echo /tmp/wb_check_out.$$)"
if [ "$QUIET" = "1" ]; then
  bash "$DIR/scripts/checkin.sh" "$@" >"$CHECK_OUT" 2>&1
  RC=$?
else
  bash "$DIR/scripts/checkin.sh" "$@" 2>&1 | tee "$CHECK_OUT"
  RC=${PIPESTATUS[0]}
fi
cat "$CHECK_OUT" >>"$LOG_FILE" 2>/dev/null

# 关键结果汇总：四个分支的结论行集中打印（成败、领取数、派出情况一目了然）
# 静默模式下这是唯一的过程输出，因此必须覆盖四个分支 + ERROR/WARN，不能漏。
RESULT_LINES=$(grep -aE "签到|打卡|旅行|采风|已派出|已领取|可兑换|失败|ERROR|WARN|==>" "$CHECK_OUT" 2>/dev/null | tail -n 14)
if [ -n "$RESULT_LINES" ]; then
  log "---- 关键结果 ----"
  printf '%s\n' "$RESULT_LINES" | sed 's/^/  /' | tee -a "$LOG_FILE"
fi
rm -f "$CHECK_OUT"

# 4. 凭证回写资料库（签到跑完后）：若本次运行期间发生过凭证刷新（refresh_token 与导入时的快照
#    .rt_snapshot 不一致，或快照缺失——说明凭证可能刚从资料库拉取/刚被续期），就把新凭证覆盖回传
#    资料库，让长效凭证 60 天窗口滚动续期（资料库是跨实例唯一可靠持久化，手册 §6.8）。
#    回写失败只记 WARN、绝不影响本脚本退出码：签到已成功，回写失败下次运行会自动重试。
if [ "${WB_NO_LIBRARY_PUSHBACK:-}" = "1" ]; then
  log "WB_NO_LIBRARY_PUSHBACK=1：已关闭凭证回写资料库，跳过"
elif [ ! -s "$CONFIG_DIR/refresh_token" ]; then
  log "config/refresh_token 缺失，跳过凭证回写"
elif [ ! -s "$CONFIG_DIR/.rt_snapshot" ]; then
  log ".rt_snapshot 缺失（首次启用回写或快照被清），触发凭证回写..."
  pushback
elif [ "$(cat "$CONFIG_DIR/refresh_token")" != "$(cat "$CONFIG_DIR/.rt_snapshot")" ]; then
  log "检测到本次运行期间凭证已刷新（refresh_token 与快照不一致），触发凭证回写..."
  pushback
else
  log "凭证未变化，无需回写资料库"
fi

log "==== sandbox_run 结束（checkin.sh 退出码: ${RC}） ===="
exit "$RC"
#!/bin/bash
# WorkBuddy 成长计划连续天数奖励【只读检查】（profile/growth-center）
# 作用：查询 streak 接口的 redemption_status，报告 7d/14d/28d 梯队状态。
#       兑换能力已从代码中物理删除：不存在 redeem 请求、不存在 payload 构造，
#       任何开关都无法恢复。available 只作提示，由用户到成长中心手动领取。
#       全部 locked/claimed 时静默记日志退出 0。
# 用法: checkin_rewards.sh          只读检查（定时任务用）
#       checkin_rewards.sh verify   晚间核验：语义相同
# 凭证：本 skill config/token（有效期约 30 天，到期自动续期）
set -u

MODE="${1:-claim}"
# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用）：沙盒/本机安装路径各不相同，
# 一律以脚本实际所在位置推导 skill 根目录，凭证因此必然落在 skill 自身的持久化目录内
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
# 本地运行策略（默认关闭自动兑换 / 凭证自取 / 凭证上云 / 本体自动更新）
. "$DIR/scripts/_policy.sh"
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"
TOKEN_FILE="$CONFIG_DIR/token"
UID_FILE="$CONFIG_DIR/user_id"
LOG_DIR="$DIR/logs"
LOG="$LOG_DIR/checkin.log"
BASE="https://www.workbuddy.cn"

mkdir -p "$LOG_DIR" "$CONFIG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [奖励检查] $*" | tee -a "$LOG"; }

# 跨平台：macOS 用 osascript 弹通知；Windows（Git Bash）用 PowerShell Toast；都没有就只记日志
notify() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"WorkBuddy 奖励检查\"" 2>/dev/null || true
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);\$x.GetElementsByTagName('text')[0].AppendChild(\$x.CreateTextNode('WorkBuddy 奖励检查'))|Out-Null;\$x.GetElementsByTagName('text')[1].AppendChild(\$x.CreateTextNode('$1'))|Out-Null;[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WorkBuddy').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" >/dev/null 2>&1 || true
  fi
}

# 跨平台：macOS 是 BSD date（-r 秒），Linux/Git Bash 是 GNU date（-d @秒）
fmtdate() { date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d'; }

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

fail() { log "ERROR: $1"; notify "连续天数奖励检查失败：$1"; exit 1; }

[ -f "$TOKEN_FILE" ] || { log "未找到凭证，跳过（由积分签到分支负责初始化）"; exit 0; }
TOKEN=$(cat "$TOKEN_FILE")
WB_UID=$(cat "$UID_FILE" 2>/dev/null || true)
[ -n "$WB_UID" ] || fail "缺少 $UID_FILE"

# 本地预检 token 过期时间（JWT payload 的 exp）
EXP=$("$PY" -c "
import json, base64
p = '$TOKEN'.split('.')[1]
p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))['exp'])
" 2>/dev/null) || fail "token 格式异常，请重新提取"
NOW=$(date +%s)
# token 已过期或 3 天内将过期：自动续期
# 优先用保存的 refresh token 直接调接口（不碰 App）；失败才走 extract_token.sh 读本地凭证文件兜底
EXTRACT="$DIR/scripts/extract_token.sh"
REFRESH="$DIR/scripts/refresh_token.sh"
if [ $((EXP - NOW)) -lt 259200 ]; then
  if [ "${WB_REFRESH_TRIED:-0}" != "1" ] && [ "${WB_ALLOW_AUTO_REFRESH:-1}" != "0" ]; then
    log "token 将于 $(fmtdate "$EXP") 过期，尝试自动续期..."
    if [ -f "$REFRESH" ] && bash "$REFRESH" >>"$LOG" 2>&1; then
      log "已通过 refresh token 续期"
      exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
    fi
    if [ -f "$EXTRACT" ] && bash "$EXTRACT" >>"$LOG" 2>&1; then
      log "凭证重建成功"
      exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
    fi
    fail "token 自动续期失败，请打开 WorkBuddy 确认登录态后手动运行 scripts/extract_token.sh"
  fi
  fail "token 已过期（$(fmtdate "$EXP")），请运行 scripts/extract_token.sh 重新提取"
fi

api() { # $1=path（GET）；网络失败/5xx 重试 3 次，业务错误不重试
  local path="$1" attempt http_code body hdr result
  # 敏感鉴权头写入临时文件，避免凭证出现在 curl 进程 argv
  hdr=$(mktemp) || { log "无法创建临时 header 文件" >&2; return 1; }
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\nX-User-Id: %s\nX-Domain: www.workbuddy.cn\n' "$TOKEN" "$WB_UID" > "$hdr"
  result=""
  for attempt in 1 2 3; do
    body=$(curl -s --noproxy '*' "$BASE$path" \
      -H @"$hdr" \
      -H "Accept: application/json" \
      --max-time 20 -w $'\n%{http_code}') || body=""
    http_code=$(echo "$body" | tail -n1)
    body=$(echo "$body" | sed '$d')
    if [ "${http_code:0:1}" = "2" ] && [ -n "$body" ]; then
      result="$body"; break
    fi
    if [ "${http_code:0:1}" = "4" ] && [ -n "$body" ]; then
      result="$body"; break
    fi
    log "请求 $path 失败（HTTP ${http_code:-无响应}），第 $attempt/3 次" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 10 - 5))
  done
  rm -f "$hdr"
  if [ -n "$result" ]; then echo "$result"; return 0; fi
  return 1
}


parse_streak() {
  "$PY" -c "
import sys, json
d = json.load(sys.stdin)
if d.get('code') != 0:
    print('ERR|%s' % d.get('msg', 'unknown')); sys.exit(0)
r = d['data'].get('redemption_status') or {}
tiers = {t['tier']: t for t in (r.get('tiers') or []) if isinstance(t, dict)}
for tier in ('7d', '14d', '28d'):
    st = r.get('tier_%s_status' % tier) or 'unknown'
    t = tiers.get(tier) or {}
    print('%s|%s|%s|%s|%s|%s' % (tier, st, t.get('credit', 0), t.get('energy', 0), t.get('cards', 0), t.get('chances', 0)))
"
}

handle_err() { # $1=错误消息；识别 token 失效走续期链路，其余直接失败
  local msg="$1"
  if echo "$msg" | grep -qiE "token|auth|登录|401"; then
    if [ "${WB_REFRESH_TRIED:-0}" != "1" ] && [ "${WB_ALLOW_AUTO_REFRESH:-1}" != "0" ]; then
      log "服务端判定 token 失效（${msg}），尝试自动续期..."
      if [ -f "$REFRESH" ] && bash "$REFRESH" >>"$LOG" 2>&1; then
        exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
      fi
      if [ -f "$EXTRACT" ] && bash "$EXTRACT" >>"$LOG" 2>&1; then
        exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
      fi
      fail "token 失效且自动续期失败，请打开 WorkBuddy 确认登录态后手动运行 scripts/extract_token.sh"
    fi
    fail "token 已失效（${msg}），请运行 scripts/extract_token.sh 重新提取"
  fi
  fail "查询奖励状态失败：$msg"
}

STREAK=$(api "/activity/growth/streak") || fail "网络请求失败，已重试 3 次（streak）"
ROWS=$(echo "$STREAK" | parse_streak) || fail "streak 接口返回异常（非 JSON 响应）"
if echo "$ROWS" | head -n1 | grep -q '^ERR|'; then
  handle_err "$(echo "$ROWS" | head -n1 | cut -d'|' -f2-)"
fi


# ==== 连续天数奖励：只读检查（兑换能力已物理删除） ====
# 原 /activity/growth/redeem 的 POST 逻辑与 payload 构造已整段删除，本脚本不再具备兑换任何
# 奖励的能力——即使服务端状态为 available，也只汇报，不会产生任何消耗性请求。
# 兑换会花掉积分 / 补签卡 / 抽奖机会，且客户端按"可兑即兑"设计，无人值守下不可控，
# 因此改为只读 + 人工到成长中心手动领取。
AVAIL_SUMMARY=""
ST_SUMMARY=""
while IFS='|' read -r TIER ST CREDIT ENERGY CARDS CHANCES; do
  [ -n "$TIER" ] || continue
  case "$ST" in
    locked)    ST_SUMMARY="$ST_SUMMARY $TIER(未解锁)" ;;
    claimed)   ST_SUMMARY="$ST_SUMMARY $TIER(已兑换)" ;;
    available) AVAIL_SUMMARY="$AVAIL_SUMMARY $TIER(积分 ${CREDIT}/能量 ${ENERGY}/补签卡 ${CARDS}/抽奖机会 ${CHANCES})" ;;
  esac
done <<< "$ROWS"

if [ -n "$AVAIL_SUMMARY" ]; then
  log "可兑换（不自动兑换，请到成长中心手动领取）：${AVAIL_SUMMARY# }｜其余：${ST_SUMMARY:-无}"
  notify "有奖励可兑换（请到成长中心手动领取）：${AVAIL_SUMMARY# }"
else
  log "当前无可兑换奖励（${ST_SUMMARY:-全部未解锁}）"
fi
exit 0

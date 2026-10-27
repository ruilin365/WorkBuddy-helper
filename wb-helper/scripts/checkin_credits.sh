#!/bin/bash
# WorkBuddy 每日签到（Buddy加油站）
# 流程：查状态 -> 未签到则领取 -> 记录日志。幂等，重复执行无副作用。
# 用法: checkin_credits.sh          正常签到（定时任务用）
#       checkin_credits.sh verify   晚间核验：已签到则静默记日志；未签到则补签并通知
set -u

MODE="${1:-claim}"

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用）：沙盒/本机安装路径各不相同，
# 一律以脚本实际所在位置推导 skill 根目录，凭证因此必然落在 skill 自身的持久化目录内
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
# 本地运行策略（默认关闭自动兑换 / 凭证自取 / 凭证上云 / 本体自动更新）
. "$DIR/scripts/_policy.sh"
# 凭证目录：默认 skill 自身 config/（沙盒中即持久化目录）；WB_CONFIG_DIR 仅作显式覆盖
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"
TOKEN_FILE="$CONFIG_DIR/token"
UID_FILE="$CONFIG_DIR/user_id"
LOG_DIR="$DIR/logs"
LOG="$LOG_DIR/checkin.log"
BASE="https://copilot.tencent.com"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 跨平台：macOS 用 osascript 弹通知；Windows（Git Bash）用 PowerShell Toast；都没有就只记日志
notify() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"WorkBuddy 签到\"" 2>/dev/null || true
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);\$x.GetElementsByTagName('text')[0].AppendChild(\$x.CreateTextNode('WorkBuddy 签到'))|Out-Null;\$x.GetElementsByTagName('text')[1].AppendChild(\$x.CreateTextNode('$1'))|Out-Null;[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WorkBuddy').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" >/dev/null 2>&1 || true
  fi
}

# 跨平台：macOS 是 BSD date（-r 秒），Linux/Git Bash 是 GNU date（-d @秒）
fmtdate() { date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d'; }

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

fail() { log "ERROR: $1"; notify "签到失败：$1"; exit 1; }

# 无凭证（首次运行/未登录）：自动拉起初始化流程，每天最多一次（避免 3 小时兜底任务反复重启 App）
if [ ! -f "$TOKEN_FILE" ]; then
  # 运行策略：缺少凭证时的自动获取默认关闭（该链路会重启 WorkBuddy 并开调试端口）
  if [ "${WB_ALLOW_SELF_FETCH:-0}" != "1" ]; then
    fail "缺少 config/token。云端沙盒请先运行 scripts/fetch_creds_from_library.sh 从资料库拉取；本机请手动导入凭证"
  fi
  MARKER="$DIR/config/.extract-$(date +%F)"
  if mkdir "$MARKER" 2>/dev/null; then
    log "未找到凭证，自动启动初始化：请在 WorkBuddy 中完成登录，脚本会自动捕获凭证"
    notify "首次使用：请在打开的 WorkBuddy 中登录，完成后签到将自动进行"
    if bash "$DIR/scripts/extract_token.sh" >>"$LOG" 2>&1; then
      log "初始化成功，继续签到"
      exec bash "$0" "$@"
    fi
    fail "初始化未完成（5 分钟内未登录），明天会自动重试，或手动运行 scripts/extract_token.sh"
  fi
  fail "缺少 config/token，今日已尝试过初始化；请运行 scripts/extract_token.sh"
fi
TOKEN=$(cat "$TOKEN_FILE")
WB_UID=$(cat "$UID_FILE" 2>/dev/null || true)
[ -n "$WB_UID" ] || fail "缺少 config/user_id"

# 本地预检 token 过期时间（JWT payload 的 exp）
EXP=$("$PY" -c "
import sys, json, base64
p = '$TOKEN'.split('.')[1]
p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))['exp'])
" 2>/dev/null) || fail "token 格式异常，请重新提取"
NOW=$(date +%s)
# token 已过期或 3 天内将过期：自动续期
# 优先用本地 refresh token 直接调接口（不碰 App）；失败才走 extract_token.sh 读本地凭证文件兜底
if [ $((EXP - NOW)) -lt 259200 ]; then
  if [ "${WB_REFRESH_TRIED:-0}" != "1" ] && [ "${WB_ALLOW_AUTO_REFRESH:-1}" != "0" ]; then
    log "token 将于 $(fmtdate "$EXP") 过期，尝试自动续期..."
    if bash "$DIR/scripts/refresh_token.sh" >>"$LOG" 2>&1; then
      log "已通过 refresh token 续期"
      exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
    fi
    log "refresh token 续期失败，尝试读取本地凭证文件重建..."
    if bash "$DIR/scripts/extract_token.sh" >>"$LOG" 2>&1; then
      log "凭证重建成功"
      exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
    fi
    fail "token 自动续期失败，请打开 WorkBuddy 确认登录态后手动运行 scripts/extract_token.sh"
  fi
  fail "token 已过期（$(fmtdate "$EXP")），请运行 scripts/extract_token.sh 重新提取"
fi

api() { # $1=path；网络失败/5xx 重试 3 次（间隔 5s、15s），业务错误不重试
  local path="$1" attempt http_code body hdr result
  # 敏感鉴权头写入临时文件，避免凭证出现在 curl 进程 argv
  hdr=$(mktemp) || { log "无法创建临时 header 文件" >&2; return 1; }
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\nX-User-Id: %s\nX-Domain: www.workbuddy.cn\n' "$TOKEN" "$WB_UID" > "$hdr"
  result=""
  for attempt in 1 2 3; do
    body=$(curl -s --noproxy '*' -X POST "$BASE$path" \
      -H @"$hdr" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d '{}' --max-time 20 -w $'\n%{http_code}') || body=""
    http_code=$(echo "$body" | tail -n1)
    body=$(echo "$body" | sed '$d')
    # 2xx 且有 JSON body：成功，直接返回
    if [ "${http_code:0:1}" = "2" ] && [ -n "$body" ]; then
      result="$body"; break
    fi
    # 4xx：业务/鉴权错误，重试无意义，直接返回让上层处理
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

# 1. 查询签到状态
STATUS=$(api "/v2/billing/meter/checkin-activity-status") || fail "网络请求失败，已重试 3 次（checkin-activity-status）"
PARSED=$(echo "$STATUS" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
if d.get('code') != 0:
    print('STATUS_ERR|%s' % d.get('msg', 'unknown')); sys.exit(0)
data = d['data']
print('OK|%s|%s|%s|%s' % (data.get('active'), data.get('today_checked_in'), data.get('total_credits'), data.get('streak_days')))
") || fail "状态接口返回异常（非 JSON 响应）"
IFS='|' read -r RESULT ACTIVE CHECKED TOTAL STREAK <<< "$PARSED"
[ -n "$RESULT" ] || fail "状态接口返回异常（非 JSON 响应）：$(echo "$STATUS" | head -c 120)"
if [ "$RESULT" = "STATUS_ERR" ]; then
  if echo "$ACTIVE" | grep -qiE "token|auth|登录|401"; then
    # 服务端判定 token 失效（本地 exp 未过期但被吊销等情况）：同样尝试自动续期一次
    if [ "${WB_REFRESH_TRIED:-0}" != "1" ] && [ "${WB_ALLOW_AUTO_REFRESH:-1}" != "0" ]; then
      log "服务端判定 token 失效（${ACTIVE}），尝试自动续期..."
      if bash "$DIR/scripts/refresh_token.sh" >>"$LOG" 2>&1; then
        exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
      fi
      if bash "$DIR/scripts/extract_token.sh" >>"$LOG" 2>&1; then
        exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
      fi
      fail "token 失效且自动续期失败，请打开 WorkBuddy 确认登录态后手动运行 scripts/extract_token.sh"
    fi
    fail "token 已失效（${ACTIVE}），请运行 scripts/extract_token.sh 重新提取"
  fi
  fail "查询状态失败：$ACTIVE"
fi
[ "$ACTIVE" = "True" ] || { log "签到活动未开启（可能已结束），跳过"; exit 0; }
if [ "$CHECKED" = "True" ]; then
  if [ "$MODE" = "verify" ]; then
    log "晚间核验：今日已签到，累计 $TOTAL 分，连续 $STREAK 天"
  else
    log "今日已签到，累计 $TOTAL 分，连续 $STREAK 天"
  fi
  exit 0
fi
# 2. 领取今日积分
CLAIM=$(api "/v2/billing/meter/daily-checkin") || fail "网络请求失败，已重试 3 次（daily-checkin）"
CODE=$(echo "$CLAIM" | "$PY" -c "import sys,json; print(json.load(sys.stdin).get('code'))" 2>/dev/null)
MSG=$(echo "$CLAIM" | "$PY" -c "import sys,json; print(json.load(sys.stdin).get('msg',''))" 2>/dev/null)
case "$CODE" in
  0)
    if [ "$MODE" = "verify" ]; then
      log "晚间核验：发现未签到，已补签成功：$MSG"; notify "今日漏签，已自动补签成功"
    else
      log "签到成功：$MSG"; notify "签到成功 +积分"
    fi;;
  10001) log "今日已签到（服务端幂等返回）";;
  *)     fail "领取失败：code=$CODE msg=$MSG";;
esac

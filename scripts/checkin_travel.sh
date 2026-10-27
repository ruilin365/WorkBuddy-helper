#!/bin/bash
# WorkBuddy 猫猫旅行（成长中心 · 派猫猫旅行）
# 原理：派猫出门旅行（POST depart），1~4 小时后回家（state=arrived），
#       领取带回的积分礼物（POST claim，5~10 积分）；领完后状态回到 idle，可再派下一段。
#       本脚本在一次运行内连续推进状态机：arrived -> 领取 -> idle -> 立即再派 -> traveling，
#       最终一定停在"已送出"或"确实无法再派"（daily_limit_reached / 服务端拒绝）上，
#       不会出现"只领了积分、猫却闲置在家"的情况。
#       触发越密，一天能跑的段数越多（每段 1~4 小时）；只在收到奖励时才占用积分。
# 用法: checkin_travel.sh          正常执行（定时任务用）
#       checkin_travel.sh verify   晚间核验：逻辑相同（idle 未派出则补派，arrived 则补领并再派）
# 凭证：本 skill config/token（Bearer JWT，30 天有效）
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

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# 跨平台：macOS 用 osascript 弹通知；Windows（Git Bash）用 PowerShell Toast；都没有就只记日志
# 通知一律后台发出：Windows 上首次唤起 Toast 组件要几十秒，绝不能拖住签到主流程
# （WB_NOTIFY=0 可彻底关闭）
notify() {
  [ "${WB_NOTIFY:-1}" = "0" ] && return 0
  if command -v osascript >/dev/null 2>&1; then
    ( osascript -e "display notification \"$1\" with title \"WorkBuddy 猫猫旅行\"" >/dev/null 2>&1 & )
  elif command -v powershell.exe >/dev/null 2>&1; then
    ( powershell.exe -NoProfile -Command "[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime];\$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(1);\$x.GetElementsByTagName('text')[0].AppendChild(\$x.CreateTextNode('WorkBuddy 猫猫旅行'))|Out-Null;\$x.GetElementsByTagName('text')[1].AppendChild(\$x.CreateTextNode('$1'))|Out-Null;[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('WorkBuddy').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" >/dev/null 2>&1 & )
  fi
  return 0
}

# 跨平台：macOS 是 BSD date（-r 秒），Linux/Git Bash 是 GNU date（-d @秒）
fmtdate() { date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d'; }

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

fail() { log "ERROR: $1"; notify "猫猫旅行失败：$1"; exit 1; }

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

api() { # $1=method(GET/POST) $2=path $3=POST body（可选）；网络失败/5xx 重试 3 次，业务错误不重试
  local method="$1" path="$2" body="${3:-}" attempt http_code resp hdr result
  # 敏感鉴权头写入临时文件，避免凭证出现在 curl 进程 argv
  hdr=$(mktemp) || { log "无法创建临时 header 文件" >&2; return 1; }
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\nX-User-Id: %s\nX-Domain: www.workbuddy.cn\n' "$TOKEN" "$WB_UID" > "$hdr"
  result=""
  for attempt in 1 2 3; do
    if [ "$method" = "POST" ]; then
      resp=$(curl -s --noproxy '*' -X POST "$BASE$path" \
        -H @"$hdr" -H "Content-Type: application/json" \
        -H "Accept: application/json" -d "$body" --max-time 20 -w $'\n%{http_code}') || resp=""
    else
      resp=$(curl -s --noproxy '*' "$BASE$path" \
        -H @"$hdr" -H "Accept: application/json" \
        --max-time 20 -w $'\n%{http_code}') || resp=""
    fi
    http_code=$(echo "$resp" | tail -n1)
    resp=$(echo "$resp" | sed '$d')
    if [ "${http_code:0:1}" = "2" ] && [ -n "$resp" ]; then
      result="$resp"; break
    fi
    if [ "${http_code:0:1}" = "4" ] && [ -n "$resp" ]; then
      result="$resp"; break
    fi
    log "请求 $path 失败（HTTP ${http_code:-无响应}），第 $attempt/3 次" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 10 - 5))
  done
  rm -f "$hdr"
  if [ -n "$result" ]; then echo "$result"; return 0; fi
  return 1
}

# 1. 查询旅行状态（结果写入全局 R / STATE / LIMITED / ARRIVE_AT / SERVER_NOW / REWARD / LOC_NAME / DURATION_H）
query_status() {
  local status parsed
  status=$(api GET "/activity/growth/buddy/travel/status") || fail "网络请求失败，已重试 3 次（travel/status）"
  parsed=$(echo "$status" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
if d.get('code') != 0:
    print('ERR|%s' % d.get('msg', 'unknown')); sys.exit(0)
s = d['data']
loc = s.get('location') or {}
print('OK|%s|%s|%s|%s|%s|%s|%s' % (
    s.get('state'), s.get('daily_limit_reached'), s.get('arrive_at') or 0,
    s.get('server_now') or 0, s.get('reward_credit') or 0,
    loc.get('name') or '', s.get('duration_hours') or 0))
" 2>/dev/null) || fail "travel/status 返回异常（非 JSON 响应）"

  IFS='|' read -r R STATE LIMITED ARRIVE_AT SERVER_NOW REWARD LOC_NAME DURATION_H <<< "$parsed"

  if [ "$R" = "ERR" ]; then
    if echo "$STATE" | grep -qiE "token|auth|登录|401"; then
      if [ "${WB_REFRESH_TRIED:-0}" != "1" ] && [ "${WB_ALLOW_AUTO_REFRESH:-1}" != "0" ]; then
        log "服务端判定 token 失效（${STATE}），尝试自动续期..."
        if [ -f "$REFRESH" ] && bash "$REFRESH" >>"$LOG" 2>&1; then
          exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
        fi
        if [ -f "$EXTRACT" ] && bash "$EXTRACT" >>"$LOG" 2>&1; then
          exec env WB_REFRESH_TRIED=1 bash "$0" "$@"
        fi
        fail "token 失效且自动续期失败，请打开 WorkBuddy 确认登录态后手动运行 scripts/extract_token.sh"
      fi
      fail "token 已失效（${STATE}），请运行 scripts/extract_token.sh 重新提取"
    fi
    fail "查询旅行状态失败：$STATE"
  fi
}

# 2. 状态机推进：一次运行内连续处理，直到猫重新上路（traveling）或今日确实无法再派。
#    关键点：领完礼物后状态会回到 idle，此时必须再派一次，否则积分领完就没有下一段旅行。
ROUND=0
DEPARTED=0   # 本次运行已派出次数（防重复派出）
CLAIMED=0    # 本次运行已领取次数（防重复领取）
while [ "$ROUND" -lt 4 ]; do
  ROUND=$((ROUND + 1))
  query_status
  case "$STATE" in
    idle)
      if [ "$LIMITED" = "True" ]; then
        log "猫猫旅行：今日已达上限，无需操作"
        exit 0
      fi
      if [ "$DEPARTED" -ge 1 ]; then
        # 派出成功但状态未及时同步，避免重复派出
        log "猫猫旅行：已派出（服务端状态仍为 idle，可能尚未同步），本次结束"
        exit 0
      fi
      # 3. 派出：从目的地列表随机选一个（各目的地时长 1~4h、奖励 5~10 积分，规则相同）
      CONFIG=$(api GET "/activity/growth/buddy/travel/config") || fail "网络请求失败，已重试 3 次（travel/config）"
      LOC_ID=$(echo "$CONFIG" | "$PY" -c "
import sys, json, random
locs = json.load(sys.stdin)['data']['locations']
print(random.choice(locs)['id'])
" 2>/dev/null) || fail "travel/config 返回异常"
      DEPART=$(api POST "/activity/growth/buddy/travel/depart" "{\"location_id\": $LOC_ID}") || fail "网络请求失败，已重试 3 次（travel/depart）"
      PARSED=$(echo "$DEPART" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
if d.get('code') != 0:
    print('ERR|%s' % d.get('msg', 'unknown')); sys.exit(0)
s = d['data']
loc = s.get('location') or {}
print('OK|%s|%s|%s' % (loc.get('name') or '?', s.get('arrive_at') or 0, s.get('duration_hours') or 0))
") || fail "travel/depart 返回异常（非 JSON 响应）"
      IFS='|' read -r R LNAME ARRIVE HOURS <<< "$PARSED"
      [ -n "$R" ] || fail "travel/depart 返回异常（非 JSON 响应）"
      if [ "$R" = "ERR" ]; then
        # 服务端日限/次数限制的措辞不固定，命中即视为"今天确实不能再派"，不算故障
        if echo "$LNAME" | grep -qiE "上限|限制|次数|已达|已用|limit|already"; then
          log "猫猫旅行：今日已无法再派出（$LNAME），结束"
          exit 0
        fi
        fail "派出失败：$LNAME"
      fi
      DEPARTED=1
      # duration_hours 服务端可能返回 0（整数取整），优先按 arrive_at 实算剩余时长
      if [ "${ARRIVE:-0}" -gt 0 ] 2>/dev/null; then
        HOURS=$(awk -v a="$ARRIVE" -v n="$(date +%s)" 'BEGIN{d=(a-n)/3600; if(d<0)d=0; printf "%.1f", d}')
      fi
      log "猫猫旅行：已派出前往「${LNAME}」，预计 ${HOURS} 小时后回家（$(fmtdate "$ARRIVE") $(date -r "$ARRIVE" '+%H:%M' 2>/dev/null || date -d "@$ARRIVE" '+%H:%M')）"
      notify "猫猫已出发去${LNAME}，回家后可领积分"
      continue   # 再看一次状态：正常会变成 traveling，随后记录倒计时退出
      ;;
    traveling)
      # SERVER_NOW 缺失（为 0）时回退本机时间，避免算出荒谬的倒计时
      [ "$SERVER_NOW" -gt 0 ] || SERVER_NOW=$(date +%s)
      LEFT=$(( (ARRIVE_AT - SERVER_NOW) / 60 ))
      [ "$LEFT" -lt 0 ] && LEFT=0
      log "猫猫旅行：「${LOC_NAME}」采风进行中，约 $LEFT 分钟后回家"
      break
      ;;
    arrived)
      if [ "$CLAIMED" -ge 1 ]; then
        log "猫猫旅行：礼物已领取（服务端状态未同步），本次结束"
        exit 0
      fi
      # 4. 领取积分礼物
      CLAIM=$(api POST "/activity/growth/buddy/travel/claim" "{}") || fail "网络请求失败，已重试 3 次（travel/claim）"
      PARSED=$(echo "$CLAIM" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
if d.get('code') != 0:
    print('ERR|%s' % d.get('msg', 'unknown')); sys.exit(0)
s = d.get('data') or {}
print('OK|%s' % (s.get('reward_credit') or '?'))
") || fail "travel/claim 返回异常（非 JSON 响应）"
      IFS='|' read -r R CREDIT <<< "$PARSED"
      [ -n "$R" ] || fail "travel/claim 返回异常（非 JSON 响应）"
      [ "$R" = "ERR" ] && fail "领取失败：$CREDIT"
      CLAIMED=1
      if [ "$MODE" = "verify" ]; then
        log "晚间核验：发现猫猫已回家未领取，已补领 $CREDIT 积分"
        notify "猫猫带回家 $CREDIT 积分，已自动领取"
      else
        log "猫猫旅行：已领取旅行礼物 $CREDIT 积分"
        notify "猫猫回家了，领取 $CREDIT 积分"
      fi
      continue   # 领完后状态回到 idle，继续下一轮把猫重新派出去
      ;;
    *)
      log "猫猫旅行：未知状态 ${STATE}，跳过"
      break
      ;;
  esac
done

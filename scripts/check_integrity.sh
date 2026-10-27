#!/bin/bash
# 校验 wb-helper skill 脚本完整性（Agent / 沙盒端定时任务在签到前调用）
# 用法: check_integrity.sh
# 输出（机器可读）：每行 <脚本名>: <OK|MISSING|SYNTAX_ERROR>，末尾「汇总: ...」行；
# 全部通过 exit 0；任一缺失或语法错误 exit 1——**仅用于报告**，不得据此触发联网重装
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
SCRIPTS_DIR="$DIR/scripts"

# 受检脚本：22 个（签到分支 + 凭证链路 + 资料库包同步 + 工具脚本 + 随包默认策略）
FILES="_policy.sh default-policy.env checkin.sh checkin_credits.sh checkin_growth.sh checkin_travel.sh checkin_rewards.sh extract_token.sh check_local_creds.sh import_manual.sh refresh_token.sh import_creds.sh fetch_creds_from_library.sh make_cred_file.sh export_creds.sh push_creds_to_library.sh self_fetch.sh self_fetch_key.mjs library_get.sh fetch_bundle_from_library.sh bootstrap_bundle.sh pack_bundle.sh"

OK_COUNT=0
BAD_COUNT=0
MISS_LIST=""
SYNTAX_LIST=""
for f in $FILES; do
  p="$SCRIPTS_DIR/$f"
  if [ ! -f "$p" ]; then
    echo "$f: MISSING"
    MISS_LIST="$MISS_LIST $f"
    BAD_COUNT=$((BAD_COUNT + 1))
    continue
  fi
  case "$f" in
    *.sh)
      if bash -n "$p" 2>/dev/null; then
        echo "$f: OK"
        OK_COUNT=$((OK_COUNT + 1))
      else
        echo "$f: SYNTAX_ERROR"
        SYNTAX_LIST="$SYNTAX_LIST $f"
        BAD_COUNT=$((BAD_COUNT + 1))
      fi ;;
    *.mjs)
      # node 可用则做语法校验；不可用视为通过（完整性以文件存在为准）
      NODE_BIN="$(command -v node || true)"
      if [ -z "$NODE_BIN" ] || "$NODE_BIN" --check "$p" >/dev/null 2>&1; then
        echo "$f: OK"
        OK_COUNT=$((OK_COUNT + 1))
      else
        echo "$f: SYNTAX_ERROR"
        SYNTAX_LIST="$SYNTAX_LIST $f"
        BAD_COUNT=$((BAD_COUNT + 1))
      fi ;;
    *)
      echo "$f: OK"
      OK_COUNT=$((OK_COUNT + 1)) ;;
  esac
done

echo "----"
TOTAL=$(echo "$FILES" | wc -w | tr -d ' ')
if [ "$BAD_COUNT" -eq 0 ]; then
  echo "汇总: ${TOTAL} 个脚本全部通过（OK=${OK_COUNT}）"
  exit 0
fi
echo "汇总: ${TOTAL} 个脚本，通过 ${OK_COUNT}，异常 ${BAD_COUNT}（exit 1）"
echo "说明: 本脚本只报告缺件/语法错误，不提供也不得触发任何自动更新或联网重装。"
[ -n "$MISS_LIST" ] && echo "缺失: ${MISS_LIST# }"
[ -n "$SYNTAX_LIST" ] && echo "语法错误: ${SYNTAX_LIST# }"
exit 1
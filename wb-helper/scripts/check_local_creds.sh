#!/bin/bash
# 第零步 · 本地凭证复用检查（最高优先级：有可用凭证就不重新获取）
# 判定：
#   config/ 三件套齐全 且 token 剩余有效期 > 1 天            → exit 0（直接用）
#   三件套齐全 但 token 临期/过期                             → 自动调 refresh_token.sh 在线续期，
#                                                               成功 exit 0；失败 exit 1（refresh 已死）
#   缺件 / token 非法                                        → exit 1（需走获取阶梯）
# 用法: check_local_creds.sh   （Agent 在extract/self_fetch/浏览器 之前必调）
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"
# 本地运行策略（默认关闭自动兑换 / 凭证自取 / 凭证上云 / 本体自动更新）
. "$DIR/scripts/_policy.sh"

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "==> 需要 python3/python/py 才能校验凭证有效期" >&2; exit 1; }

for f in token user_id refresh_token; do
  [ -s "$CONFIG_DIR/$f" ] || { echo "==> 缺少 ${CONFIG_DIR}/${f}：本地无完整凭证" >&2; exit 1; }
done

EXP=$("$PY" -c '
import base64, json, sys
try:
    tok = open(sys.argv[1]).read().strip()
    p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
    print(json.loads(base64.urlsafe_b64decode(p))["exp"])
except Exception:
    print(0)
' "$CONFIG_DIR/token")
NOW=$(date +%s)

if [ "${EXP:-0}" -gt $((NOW + 86400)) ]; then
  echo "==> 本地凭证有效（token 剩余 $(( (EXP - NOW) / 86400 )) 天以上），直接复用"
  exit 0
fi

echo "==> token 已过期或剩余不足 1 天，尝试在线续期（refresh_token）..."
if [ "${WB_ALLOW_AUTO_REFRESH:-1}" = "0" ]; then
  echo "==> 自动续期已被策略禁用（config/policy.env: WB_ALLOW_AUTO_REFRESH=0）：本地凭证不可用" >&2
  exit 1
fi
if bash "$DIR/scripts/refresh_token.sh" >/dev/null 2>&1; then
  echo "==> 续期成功，本地凭证可用"
  exit 0
fi

echo "==> 在线续期失败（refresh_token 很可能已失效）：需重新获取凭证" >&2
echo "==> 依次尝试：extract_token.sh → self_fetch 阶梯 → 浏览器 import_manual.sh" >&2
exit 1

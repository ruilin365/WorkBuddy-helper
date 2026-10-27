#!/bin/bash
# 导出本机凭证串（用于小程序云端沙盒部署的数据交换）
# 用法: export_creds.sh          输出一行 WB1:<base64> 凭证串，复制粘贴给沙盒 Agent
# 凭证串内含 token/user_id/refresh_token（敏感！只允许粘贴到自己的沙盒会话，勿外传）
# 沙盒侧配套脚本: import_creds.sh
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），凭证目录随 skill 实际安装位置而定
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

for f in token user_id refresh_token; do
  [ -s "$CONFIG_DIR/$f" ] || {
    echo "==> 缺少 $CONFIG_DIR/${f}，请先在装有 WorkBuddy 的本机运行 scripts/extract_token.sh" >&2
    exit 1
  }
done

"$PY" - "$CONFIG_DIR" <<'EOF'
import base64, json, sys
d = sys.argv[1]
cred = {
    'token': open(f'{d}/token').read().strip(),
    'user_id': open(f'{d}/user_id').read().strip(),
    'refresh_token': open(f'{d}/refresh_token').read().strip(),
}
print('WB1:' + base64.b64encode(json.dumps(cred).encode()).decode())
EOF

#!/bin/bash
# 凭证续期：用本地保存的长效凭证在线换取新的访问凭证（纯接口调用，不依赖桌面端运行）
# 长效凭证每次续期会轮换，但旧值不作废，因此本机与云端可各自独立续期、互不影响。
# 仅当长效凭证也失效（如用户在 App 中退出登录）时，才需要 extract_token.sh 重新生成。
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），凭证目录随 skill 实际安装位置而定
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"
TOKEN_FILE="$CONFIG_DIR/token"
UID_FILE="$CONFIG_DIR/user_id"
RT_FILE="$CONFIG_DIR/refresh_token"

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

[ -f "$RT_FILE" ] || { echo "缺少 config/refresh_token，请运行 extract_token.sh 重建凭证" >&2; exit 1; }
RT=$(cat "$RT_FILE")
OLD_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)
WB_UID=$(cat "$UID_FILE" 2>/dev/null || true)

# 敏感鉴权头写入临时文件，避免凭证出现在 curl 进程 argv；非敏感头走普通 -H
HDR=$(mktemp) || { echo "无法创建临时 header 文件" >&2; exit 1; }
chmod 600 "$HDR"
printf 'Authorization: Bearer %s\nX-Refresh-Token: %s\nX-User-Id: %s\nX-Domain: www.workbuddy.cn\n' "$OLD_TOKEN" "$RT" "$WB_UID" > "$HDR"

# 网络失败/5xx 重试 3 次（与其他脚本 api() 一致）；4xx 直接返回让上层判断
RESP=""
for attempt in 1 2 3; do
  body=$(curl -s --noproxy '*' -X POST "https://copilot.tencent.com/v2/plugin/auth/token/refresh" \
    -H @"$HDR" \
    -H "X-Product: SaaS" \
    -H "Content-Type: application/json" \
    -d '{}' --max-time 20 -w $'\n%{http_code}') || body=""
  http_code=$(echo "$body" | tail -n1)
  body=$(echo "$body" | sed '$d')
  if [ "${http_code:0:1}" = "2" ] && [ -n "$body" ]; then
    RESP="$body"; break
  fi
  if [ "${http_code:0:1}" = "4" ] && [ -n "$body" ]; then
    RESP="$body"; break
  fi
  echo "刷新请求失败（HTTP ${http_code:-无响应}），第 $attempt/3 次" >&2
  [ "$attempt" -lt 3 ] && sleep $((attempt * 10 - 5))
done
rm -f "$HDR"
[ -n "$RESP" ] || { echo "刷新接口网络错误，已重试 3 次" >&2; exit 1; }

# 原子写：先校验字段完整，再经临时文件 + os.replace 落盘（避免截断有效 token）
echo "$RESP" | "$PY" -c '
import os, sys, json
d = json.load(sys.stdin)
if d.get("code") != 0:
    print("刷新失败: %s" % d.get("msg"), file=sys.stderr); sys.exit(1)
data = d["data"]
tok, rt = data.get("accessToken"), data.get("refreshToken")
if not tok or not rt:
    print("刷新失败: 响应缺少 token 字段", file=sys.stderr); sys.exit(1)
for path, val in ((sys.argv[1], tok), (sys.argv[2], rt)):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: f.write(val)
    os.chmod(tmp, 0o600); os.replace(tmp, path)
print("OK")
' "$TOKEN_FILE" "$RT_FILE" || exit 1
chmod 600 "$TOKEN_FILE" "$RT_FILE"
echo "token 续期成功"
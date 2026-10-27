#!/bin/bash
# 生成 WorkBuddy 登录凭证（有效期约 30 天）
# 作用：从本机 WorkBuddy 桌面端的本地登录数据读取凭证，写入 skill 的 config/。
# 前置：本机已安装 WorkBuddy 桌面端且处于登录状态。
# 说明：凭证文件位置随平台而异，见下方 INFO 候选路径；云端沙盒没有桌面端，
#       须改由本机 export_creds.sh 导出凭证串、在沙盒 import_creds.sh 导入。
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），凭证目录随 skill 实际安装位置而定
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

# 凭证文件候选路径（按平台逐个探测）
APPDATA_POSIX="${APPDATA:-}"
LOCALAPPDATA_POSIX="${LOCALAPPDATA:-}"
if command -v cygpath >/dev/null 2>&1; then
  [ -n "$APPDATA_POSIX" ] && APPDATA_POSIX="$(cygpath "$APPDATA_POSIX" 2>/dev/null || echo "$APPDATA_POSIX")"
  [ -n "$LOCALAPPDATA_POSIX" ] && LOCALAPPDATA_POSIX="$(cygpath "$LOCALAPPDATA_POSIX" 2>/dev/null || echo "$LOCALAPPDATA_POSIX")"
fi
INFO=""
for c in \
  "$HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info" \
  "$LOCALAPPDATA_POSIX/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info" \
  "$APPDATA_POSIX/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"; do
  [ -n "$c" ] && [ -f "$c" ] && INFO="$c" && break
done

mkdir -p "$DIR/config"
umask 077

[ -n "$INFO" ] || {
  echo "==> 未找到 WorkBuddy 凭证文件（已尝试 macOS/Windows 常见路径）" >&2
  echo "==> 请先打开 WorkBuddy 并登录，再重新运行本脚本" >&2
  exit 1
}

RESULT=$("$PY" - "$INFO" <<'EOF'
import json, sys, time, base64
d = json.load(open(sys.argv[1]))
tok = d['auth']['accessToken']
rt = d['auth'].get('refreshToken', '')
uid = d['account']['uid']
# 新版客户端（2026-09 起）对本地凭证启用 $wbEncrypted 信封加密（AES-GCM），
# 解密密钥派生依赖应用构建期内嵌密钥，脚本无法自行提取。
# 明确给出替代路径（浏览器获取 + import_manual.sh），而不是抛 AttributeError 让用户看不懂
if isinstance(tok, dict) or isinstance(rt, dict):
    sys.stderr.write('==> 当前 WorkBuddy 版本的本地凭证已加密存储（$wbEncrypted 信封），无法自动提取\n')
    sys.stderr.write('==> 注意：这只影响"生成新凭证"；config/ 已有凭证完全不受影响——\n')
    sys.stderr.write('==> 签到、export_creds.sh 导出、make_cred_file.sh 入库、refresh_token.sh 在线续期全部照常\n')
    sys.stderr.write('==> 确需新凭证时，改用浏览器获取：打开 workbuddy.cn 登录 → F12 → Network 复制含 token 的响应，\n')
    sys.stderr.write("==>   然后执行: echo '<JSON>' | bash scripts/import_manual.sh\n")
    sys.stderr.write('==> 详细步骤见 SKILL.md「客户端部署 · 加密存储的替代获取路径」\n')
    sys.exit(3)
p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
exp = json.loads(base64.urlsafe_b64decode(p))['exp']
if exp - time.time() < 86400:
    sys.stderr.write('==> 文件内 token 将于 %s 过期，请打开 WorkBuddy 让它刷新登录态后重试\n'
                     % time.strftime('%F', time.localtime(exp)))
    sys.exit(1)
print(tok); print(uid); print(rt)
EOF
) || exit 1

echo "$RESULT" | sed -n '1p' > "$DIR/config/token"
echo "$RESULT" | sed -n '2p' > "$DIR/config/user_id"
RT=$(echo "$RESULT" | sed -n '3p')
[ -n "$RT" ] && echo "$RT" > "$DIR/config/refresh_token"
chmod 600 "$DIR/config/token" "$DIR/config/user_id"
[ -f "$DIR/config/refresh_token" ] && chmod 600 "$DIR/config/refresh_token"
echo "==> 提取成功（来源：${INFO}），已写入 config/token、config/user_id$([ -n "$RT" ] && echo '、config/refresh_token')"

#!/bin/bash
# 手动导入凭证（新版客户端加密存储的替代获取路径，与 extract_token.sh 殊途同归）
# 背景：2026-09 起 WorkBuddy 桌面端对本地凭证启用 $wbEncrypted 信封加密，extract_token.sh 无法
#       自动提取。此时改从浏览器登录态复制 token，经本脚本写入 config/，后续流程与自动提取完全一致。
# 用法: echo '<JSON>' | bash scripts/import_manual.sh
# 输入（经 stdin，不进入 ps argv）为任意含凭证的 JSON，脚本递归全文搜索键名，兼容：
#   ① 扁平形态：{"token":"eyJ...","user_id":"...","refresh_token":"..."}
#   ② workbuddy 登录/刷新接口响应（含 {"code":0,"data":{...}} 包装层）：data.accessToken / data.refreshToken
#   ③ 桌面端 info 文件形态：{"auth":{"accessToken":"...","refreshToken":"..."},"account":{"uid":"..."}}
# accessToken / refreshToken 必需；uid 可缺省（自动从 token JWT 的 sub 字段推导，实测与账号 uid 一致）
# 写入目录: ${WB_CONFIG_DIR:-<skill根>/config}（600 权限），写完可继续 make_cred_file.sh / checkin.sh
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

[ -t 0 ] && {
  echo "==> 用法: echo '<含 accessToken/refreshToken/uid 的 JSON>' | bash scripts/import_manual.sh" >&2
  echo "==> 获取步骤见 SKILL.md「客户端部署 · 加密存储的替代获取路径」" >&2
  exit 1
}

# 经环境变量传给 python（凭证不进 ps argv；python 程序体来自 heredoc，stdin 已被程序占用）
IN="$(cat)" || { echo "==> 读取 stdin 失败" >&2; exit 1; }
[ -n "$IN" ] || { echo "==> 输入为空" >&2; exit 1; }
export WB_JSON_IN="$IN"

mkdir -p "$CONFIG_DIR"
umask 077

RESULT=$("$PY" - "$CONFIG_DIR" <<'EOF'
import json, sys, time, base64, os
cfg = sys.argv[1]
try:
    d = json.loads(os.environ.get('WB_JSON_IN', ''))
except Exception:
    print('ERR|输入不是合法 JSON（应直接粘贴含 accessToken/refreshToken 的完整响应）'); sys.exit(0)
# 递归全文搜索键名——真实接口响应可能带 {"code":0,"data":{...}} 包装层，
# 也可能像 workbuddy-desktop.info 一样是 {"auth":{...},"account":{...}} 结构，逐键探测两种都兼容
found = {}
def walk(v):
    if isinstance(v, dict):
        for k, x in v.items():
            kl = k.lower()
            if kl in ('accesstoken', 'token'):
                if isinstance(x, str) and 'tok' not in found:
                    found['tok'] = x
                elif isinstance(x, dict):
                    found['tok_env'] = True
                else:
                    walk(x)
            elif kl in ('refreshtoken', 'refresh_token'):
                if isinstance(x, str) and 'rt' not in found:
                    found['rt'] = x
                elif isinstance(x, dict):
                    found['rt_env'] = True
                else:
                    walk(x)
            elif kl in ('uid', 'user_id') and isinstance(x, str) and 'uid' not in found:
                found['uid'] = x
            else:
                walk(x)
    elif isinstance(v, list):
        for x in v:
            walk(x)
walk(d)
if found.get('tok_env') or found.get('rt_env'):
    print('ERR|拿到的是 $wbEncrypted 加密信封而不是明文 token——请从浏览器开发者工具重新复制明文值'); sys.exit(0)
tok, rt, uid = found.get('tok', ''), found.get('rt', ''), found.get('uid', '')
missing = [n for n, v in (('accessToken', tok), ('refreshToken', rt)) if not v]
if missing:
    print('ERR|JSON 中找不到字段: %s（请复制含 accessToken/refreshToken 的完整响应体）' % ', '.join(missing)); sys.exit(0)
p = tok.split('.')
if len(p) != 3:
    print('ERR|accessToken 不是合法 JWT（应为 eyJ 开头的三段式 token）'); sys.exit(0)
p = p[1] + '=' * (-len(p[1]) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(p))
    exp = payload['exp']
except Exception:
    print('ERR|无法解析 token 有效期'); sys.exit(0)
# uid 缺失时从 JWT payload 的 sub 推导（实测 sub 与 account.uid 一致）
if not uid:
    uid = str(payload.get('sub') or '')
    if uid:
        sys.stderr.write('==> JSON 中无 uid，已从 token 的 sub 字段推导\n')
if not uid:
    print('ERR|无法确定 uid（JSON 中无 uid，token payload 中也无 sub）'); sys.exit(0)
if exp - time.time() < 86400:
    print('ERR|token 已过期或剩余不足 1 天，请在浏览器里刷新页面后重新复制'); sys.exit(0)
open(f'{cfg}/token', 'w').write(tok)
open(f'{cfg}/user_id', 'w').write(uid)
open(f'{cfg}/refresh_token', 'w').write(rt)
for f in ('token', 'user_id', 'refresh_token'):
    os.chmod(f'{cfg}/{f}', 0o600)
print('OK|%s' % time.strftime('%Y-%m-%d', time.localtime(exp)))
EOF
) || { echo "==> 凭证解析失败（详见上方输出）" >&2; exit 1; }

R="${RESULT%%|*}"
if [ "$R" != "OK" ]; then
  echo "==> ${RESULT#*|}" >&2
  exit 1
fi
echo "==> 凭证导入成功（写入 ${CONFIG_DIR}，权限 600），token 有效期至 ${RESULT#*|}"
echo "==> 下一步：bash scripts/checkin.sh 验证签到；如选小程序云端部署，再 bash scripts/make_cred_file.sh 生成资料库凭证文件"

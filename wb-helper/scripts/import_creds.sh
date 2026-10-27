#!/bin/bash
# 导入凭证串（小程序云端沙盒侧配套脚本，与本机 export_creds.sh 配对）
# 用法:
#   import_creds.sh '<WB1:xxxx 凭证串>'        参数传入（沙盒 Agent 直接调用）
#   echo '<WB1:xxxx>' | import_creds.sh        stdin 传入
#   cat 凭证文件 | import_creds.sh             整份文件 stdin 传入（自动提取 WB1: 行）
#   WB_CREDS='<WB1:xxxx>' import_creds.sh      环境变量传入
# 输入兼容「警告行 + WB1 行」的两行文件（make_cred_file.sh 产物）与纯 WB1 串：自动提取 WB1: 开头的行
# 写入目录: ${WB_CONFIG_DIR:-<skill根>/config}（沙盒中指向可持久化目录）
# 导入后沙盒内即可运行 checkin.sh；token 续期由 refresh_token.sh 在线完成，无需本机 App
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用）：沙盒路径因实例而异
# （如 /root/.codebuddy/skills/@<user>/wb-helper），必须以脚本实际位置推导，
# 确保凭证写入 skill 自身目录——即沙盒的持久化层，而非调用时的 cwd
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

# 落点提示：默认仍写 skill 自身 config/；仅当解析出的落点位于 /workspace 或 /root/uploads 时打印警告。
# 手册 §6.10.6：/workspace 并不比 /root 更持久（同一 overlay 卷），硬性拒绝只增加摩擦不增加安全——改为只警告不拒绝
case "$CONFIG_DIR" in
  /workspace/*|*/workspace/*|/root/uploads/*)
    echo "==> 警告：${CONFIG_DIR} 位于用户可见区域，且 /workspace、/root 同属一个 overlay 卷、不跨实例持久" >&2
    echo "==>     建议使用 skill 自身 config/（默认位置）；如需使用当前落点，脚本将照常写入" >&2 ;;
esac

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

# 凭证来源：参数 > 环境变量 > stdin。stdin 可能是整份文件（警告行 + WB1 行），须整体读入
IN="${1:-${WB_CREDS:-}}"
if [ -z "$IN" ] && [ ! -t 0 ]; then
  IN="$(cat)" || true
fi
# 从输入中提取以 WB1: 开头的那一行：兼容「警告行 + WB1 行」两行文件与纯 WB1 串。
# WB1 行的内容是 base64（不含换行），按行首匹配即可精确定位；找不到即报错
CRED="$(printf '%s\n' "$IN" | grep -m1 '^WB1:')" || CRED=""
[ -n "$CRED" ] || {
  echo "==> 输入中找不到以 WB1: 开头的凭证行（应为 export_creds.sh / make_cred_file.sh 生成的 WB1: 凭证串）" >&2
  echo "==> 用法: import_creds.sh '<WB1:...>'；或 echo '<WB1:...>' | import_creds.sh；或 WB_CREDS='<WB1:...>' import_creds.sh" >&2
  exit 1
}

mkdir -p "$CONFIG_DIR"
umask 077

RESULT=$(printf '%s' "$CRED" | "$PY" -c "
import base64, json, sys, time
cfg = sys.argv[1]
raw = sys.stdin.read().strip()
if raw.startswith('WB1:'):
    raw = raw[4:]
try:
    d = json.loads(base64.b64decode(raw))
    tok, uid, rt = d['token'], d['user_id'], d['refresh_token']
except Exception:
    print('ERR|凭证串解析失败（格式应为 WB1:<base64>，且含 token/user_id/refresh_token）')
    sys.exit(0)
if not tok or not uid:
    print('ERR|凭证缺少 token/user_id'); sys.exit(0)
p = tok.split('.')
if len(p) != 3:
    print('ERR|token 不是合法 JWT'); sys.exit(0)
p = p[1] + '=' * (-len(p[1]) % 4)
try:
    exp = json.loads(base64.urlsafe_b64decode(p))['exp']
except Exception:
    print('ERR|无法解析 token 有效期'); sys.exit(0)
if exp - time.time() < 86400:
    print('ERR|token 已过期或不足 1 天有效，请在本机重新运行 extract_token.sh + export_creds.sh')
    sys.exit(0)
open(f'{cfg}/token', 'w').write(tok)
open(f'{cfg}/user_id', 'w').write(uid)
open(f'{cfg}/refresh_token', 'w').write(rt)
import os
for f in ('token', 'user_id', 'refresh_token'):
    os.chmod(f'{cfg}/{f}', 0o600)
print('OK|%s' % time.strftime('%Y-%m-%d', time.localtime(exp)))
" "$CONFIG_DIR")

R="${RESULT%%|*}"
if [ "$R" != "OK" ]; then
  echo "==> ${RESULT#*|}" >&2
  exit 1
fi
echo "==> 凭证导入成功（写入 ${CONFIG_DIR}），token 有效期至 ${RESULT#*|}"
echo "==> 现在可运行: bash scripts/checkin.sh"

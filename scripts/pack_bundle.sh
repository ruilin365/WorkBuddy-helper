#!/bin/bash
# 把本 skill 打成可上传资料库的「单文件文本包」（bundle）
# 用法: pack_bundle.sh [-o 输出目录]（默认 $DIR/dist）
# 产物:
#   <out>/wb-helper-local-bundle.txt    首行元信息 + 单行 base64 的 tar.gz（包内根目录 wb-helper/）
#   <out>/wb-helper-local-bundle.txt.sha256  外层文件自身的 sha256（便于人工核对）
# 排除: config/（凭证）、logs/（含敏感信息）、dist/、.git/、*.bak、日志残留
# 本机用；沙盒端不打包
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
PARENT="$(cd "$DIR/.." && pwd)"
NAME="$(basename "$DIR")"

OUT="$DIR/dist"
if [ "${1:-}" = "-o" ] && [ -n "${2:-}" ]; then OUT="$2"; fi
mkdir -p "$OUT" || { echo "无法创建输出目录 $OUT" >&2; exit 1; }

# 版本号取自 SKILL.md frontmatter 的 version 字段（唯一事实来源）
VER="$(sed -n 's/^version:[[:space:]]*//p' "$DIR/SKILL.md" 2>/dev/null | head -1 | tr -d '\r' | tr -d ' ')"
[ -n "$VER" ] || VER="unknown"

TMP_TGZ="$(mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
trap 'rm -f "$TMP_TGZ"' EXIT

# Windows(Git Bash) 下 GNU tar 会把 "C:/..." 当成远程主机名（host:path），必须 --force-local
TAR_FL=""
case "$(uname -s 2>/dev/null || echo unknown)" in
  MSYS*|CYGWIN*|MINGW*) TAR_FL="--force-local" ;;
esac

# 打包：-C 到父目录，包内根目录即为 wb-helper/
if ! tar $TAR_FL -czf "$TMP_TGZ" -C "$PARENT" \
    --exclude="${NAME}/config" \
    --exclude="${NAME}/logs" \
    --exclude="${NAME}/dist" \
    --exclude="${NAME}/.git" \
    --exclude="${NAME}/backup" \
    --exclude="*.bak" \
    --exclude="*.log" \
    --exclude=".DS_Store" \
    "$NAME" 2>/tmp/pack_err.$$; then
  echo "==> tar 打包失败：" >&2
  cat /tmp/pack_err.$$ >&2
  rm -f /tmp/pack_err.$$
  exit 1
fi
rm -f /tmp/pack_err.$$

SHA="$(sha256sum < "$TMP_TGZ" | awk '{print $1}')"
SIZE="$(wc -c < "$TMP_TGZ" | tr -d ' ')"
FILES="$(tar $TAR_FL -tzf "$TMP_TGZ" | grep -vc '/$' || true)"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
BUNDLE="$OUT/wb-helper-local-bundle-v${VER}.txt"
rm -f "$OUT/wb-helper-local-bundle.txt" "$OUT/wb-helper-local-bundle.txt.sha256"

{
  echo "WBHELPER-BUNDLE version=${VER} sha256=${SHA} size=${SIZE} files=${FILES} built=${STAMP}"
  base64 "$TMP_TGZ" | tr -d '\n'
  echo
} > "$BUNDLE" || { echo "无法写入 $BUNDLE" >&2; exit 1; }

sha256sum < "$BUNDLE" | awk '{print $1}' > "$BUNDLE.sha256"

# 引导脚本：与 scripts/bootstrap_bundle.sh 同一份内容，作为独立文件上传资料库
BOOTSTRAP="$OUT/wb-helper-local-bootstrap-v${VER}.txt"
rm -f "$OUT/wb-helper-local-bootstrap.txt" "$OUT/wb-helper-local-bootstrap.txt.sha256"
cp "$DIR/scripts/bootstrap_bundle.sh" "$BOOTSTRAP" || { echo "无法生成 $BOOTSTRAP" >&2; exit 1; }
sha256sum < "$BOOTSTRAP" | awk '{print $1}' > "$BOOTSTRAP.sha256"

# 自检：确认包内不含凭证/日志，且解出来的目录结构正确
LEAK="$(tar $TAR_FL -tzf "$TMP_TGZ" | grep -E "/config/|/logs/|sandbox-creds|\\.rt_snapshot|/token$" || true)"
if [ -n "$LEAK" ]; then
  echo "==> 打包自检失败：包内出现凭证或日志文件，已中止" >&2
  printf '%s\n' "$LEAK" >&2
  rm -f "$BUNDLE" "$BUNDLE.sha256"
  exit 1
fi
if ! tar $TAR_FL -tzf "$TMP_TGZ" | grep -q "^${NAME}/scripts/checkin.sh$"; then
  echo "==> 打包自检失败：包内缺少 ${NAME}/scripts/checkin.sh" >&2
  rm -f "$BUNDLE" "$BUNDLE.sha256"
  exit 1
fi

echo "==> 打包完成"
echo "    版本     : ${VER}"
echo "    源文件数 : ${FILES}"
echo "    tar 大小 : ${SIZE} 字节"
echo "    tar sha256: ${SHA}"
echo "    包文件   : ${BUNDLE}"
echo "    引导脚本 : ${BOOTSTRAP}"
echo "    外层sha256: $(cat "$BUNDLE.sha256")"
echo
echo "==> 上传到资料库个人空间（标题含基础标识即可，保持 .txt 扩展名）"
echo "    上传能力不支持覆盖：同名会新建节点且无法删除，请直接上传本版本化文件名"
echo "    云端按「基础标识 + 版本号最大」匹配，历史节点留着不影响取新版"

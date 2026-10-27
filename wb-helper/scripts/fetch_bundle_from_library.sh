#!/bin/bash
# 从资料库同步本 skill 本体（沙盒端用；skill 已存在时重新拉取最新上传的分支包）
# 用法: fetch_bundle_from_library.sh [--dest <skills 父目录>]
#   默认目标 ~/.workbuddy/skills（包内根目录 wb-helper/ 会被合并进去）
# 前置: CodeBuddy 沙盒（auth-proxy 网关注入身份）；本机没有该网关，必然失败
# 行为: 下载 → 校验首行 sha256 → 解 base64 → 解 tar 到临时目录 → 合并覆盖到目标
#       只覆盖包内文件，**不删除**目标目录里的 config/ 与 logs/（凭证与日志必须保留）
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }

BUNDLE_ID='wb-helper-local-bundle'
DEST_PARENT="$HOME/.workbuddy/skills"
if [ "${1:-}" = "--dest" ] && [ -n "${2:-}" ]; then DEST_PARENT="$2"; fi

TMP_BUNDLE="$(mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_TGZ="$(mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_DIR="$(mktemp -d)" || { echo "无法创建临时目录" >&2; exit 1; }
cleanup() { rm -f "$TMP_BUNDLE" "$TMP_TGZ"; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

bash "$DIR/scripts/library_get.sh" "$BUNDLE_ID" "$TMP_BUNDLE" || {
  echo "==> 从资料库获取 skill 包失败" >&2
  exit 1
}

META="$(head -1 "$TMP_BUNDLE" | tr -d '\r')"
case "$META" in
  WBHELPER-BUNDLE*) : ;;
  *) echo "==> 下载内容首行不是 bundle 元信息，文件不匹配（首行：$(printf '%s' "$META" | head -c 100)）" >&2; exit 1 ;;
esac
VER="$(printf '%s' "$META" | sed -n 's/.*version=\([^ ]*\).*/\1/p')"
EXP="$(printf '%s' "$META" | sed -n 's/.*sha256=\([0-9a-fA-F]\{64\}\).*/\1/p')"
[ -n "$EXP" ] || { echo "==> 元信息缺少 sha256，拒绝解包" >&2; exit 1; }

if command -v base64 >/dev/null 2>&1; then
  tail -n +2 "$TMP_BUNDLE" | tr -d '\r\n' | base64 -d > "$TMP_TGZ" 2>/dev/null
else
  python3 -c 'import base64,sys;d=open(sys.argv[1],"rb").read().split(b"\n",1)[1];open(sys.argv[2],"wb").write(base64.b64decode(b"".join(d.split())))' "$TMP_BUNDLE" "$TMP_TGZ"
fi
[ -s "$TMP_TGZ" ] || { echo "==> base64 解码结果为空（包文件可能被截断）" >&2; exit 1; }

GOT="$(sha256sum < "$TMP_TGZ" | awk '{print $1}')"
if [ "$GOT" != "$EXP" ]; then
  echo "==> sha256 校验失败，已中止解包" >&2
  echo "    期望: $EXP" >&2
  echo "    实际: $GOT" >&2
  exit 1
fi
echo "==> 校验通过（version=${VER:-未知}）"

tar -xzf "$TMP_TGZ" -C "$TMP_DIR" || { echo "==> tar 解包失败" >&2; exit 1; }
SRC="$TMP_DIR/wb-helper"
[ -d "$SRC" ] || { echo "==> 包内缺少 wb-helper/ 目录，包结构异常" >&2; exit 1; }

mkdir -p "$DEST_PARENT" || { echo "无法创建目标目录 $DEST_PARENT" >&2; exit 1; }
mkdir -p "$DEST_PARENT/wb-helper"
cp -a "$SRC/." "$DEST_PARENT/wb-helper/" || { echo "==> 合并复制失败" >&2; exit 1; }
chmod +x "$DEST_PARENT/wb-helper/scripts/"*.sh 2>/dev/null || true

echo "==> 已同步到 $DEST_PARENT/wb-helper（config/ 与 logs/ 已保留，未覆盖）"
if bash "$DEST_PARENT/wb-helper/scripts/check_integrity.sh"; then
  echo "==> 完整性校验通过"
else
  echo "==> 完整性校验未通过，见上方缺件清单（只报告，不自动重装）" >&2
  exit 1
fi

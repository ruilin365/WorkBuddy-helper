#!/bin/bash
# 生成待上传到资料库（Library）的凭证文件（本机客户端用）
# 文件内容两行：第 1 行为中文警告；第 2 行为 WB1:<base64>（与 export_creds.sh 同格式）
# 文件名同样带警告语（资料库里浏览即可见，充分提醒），并含稳定标识 sandbox-creds-WB2 供沙盒端匹配
# 用法: make_cred_file.sh [输出路径]   默认输出 ${CONFIG_DIR}/<警告语>sandbox-creds-WB2.txt（权限 600）
# 沙盒端配套脚本: fetch_creds_from_library.sh（两端常量必须同步）
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），凭证目录随 skill 实际安装位置而定
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

# === 硬编码常量（与 fetch_creds_from_library.sh 必须完全一致，改名需两端同步）===
# 警告语：既写进文件内容第 1 行，也作为文件名前缀（资料库列表里直接可见）
CREDS_WARNING='重要凭证，切勿分享和发给别人！！！'
# 稳定标识：沙盒端按"标题包含此标识"匹配节点。
# 注意：资料库后端会把标题的扩展名剥掉（上传 sandbox-creds-WB2.txt，list-nodes 返回的 title 是
# sandbox-creds-WB2），所以匹配一律基于不含扩展名的标识，不能按完整文件名精确匹配。
CREDS_ID='sandbox-creds-WB2'
CREDS_FILE_NAME="${CREDS_WARNING}${CREDS_ID}.txt"

OUT="${1:-$CONFIG_DIR/$CREDS_FILE_NAME}"

# Windows 上 python 命令名可能是 python / py
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

# 前置检查：三个凭证文件必须齐全且非空，否则无从打包（缺任何一个都提示先提取）
for f in token user_id refresh_token; do
  [ -s "$CONFIG_DIR/$f" ] || {
    echo "==> 缺少 ${CONFIG_DIR}/${f}：凭证不完整，请先在装有 WorkBuddy 的本机运行 scripts/extract_token.sh" >&2
    echo "==> （新版客户端为加密存储时 extract_token.sh 会明确提示，改走浏览器获取 + scripts/import_manual.sh）" >&2
    exit 1
  }
done

# 复用 export_creds.sh 的生成逻辑（读 config/ 三件套 → JSON → base64 → 加 WB1: 前缀）
WB1_LINE=$(bash "$DIR/scripts/export_creds.sh") || {
  echo "==> 生成 WB1 凭证串失败（export_creds.sh 异常退出）" >&2
  exit 1
}
[ -n "$WB1_LINE" ] || { echo "==> 生成 WB1 凭证串失败（export_creds.sh 无输出）" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
umask 077
printf '%s\n%s\n' "$CREDS_WARNING" "$WB1_LINE" > "$OUT"
chmod 600 "$OUT"

echo "==> 凭证文件已生成：${OUT}（权限 600）"
echo "==> 文件内容：第 1 行警告语「${CREDS_WARNING}」，第 2 行 WB1 凭证串"
echo "==> 请上传到资料库个人空间（我的资料），文件名保持：${CREDS_FILE_NAME}"
echo "==> 注意：资料库会把标题的扩展名剥掉，上传后 list-nodes 看到的标题是「${CREDS_WARNING}${CREDS_ID}」，属正常现象"
echo "==> 若资料库中已存在同名节点，必须带 --node-id 覆盖上传（个人空间同名会并存且无删除 API）"
#!/bin/bash
# 引导脚本（bootstrap）：在没有 skill 的全新沙盒里，从资料库取回 skill 分支包并安装
# 用法: bash bootstrap_bundle.sh [--dest <skills 父目录>]
#   默认目标 ~/.workbuddy/skills（包内根目录 wb-helper/ 会被解到该目录下）
# 前置: CodeBuddy 沙盒（auth-proxy 网关注入资料库身份）+ python3 + curl
# 自包含：不依赖 skill 自身任何文件（此脚本存在的意义就是"skill 还不存在"）
# 安全约束: 只从资料库个人空间取包，sha256 不符即中止；不从任何网络地址安装 skill
set -u

BUNDLE_ID='wb-helper-local-bundle'
DEST_PARENT="$HOME/.workbuddy/skills"
if [ "${1:-}" = "--dest" ] && [ -n "${2:-}" ]; then DEST_PARENT="$2"; fi

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "==> 需要 python3 / python / py" >&2; exit 1; }

LB=/root/.codebuddy/skills/library
[ -d "$LB" ] || LB=/opt/sandbox-prefetched/blobs/skill/library/latest
if [ ! -d "$LB" ]; then
  echo "==> 无法定位资料库技能目录，当前环境可能不是 CodeBuddy 沙盒" >&2
  exit 1
fi
export CODEBUDDY_SKILL_DIR="$LB"

# 前置检查：资料库技能的脚本布局随版本变化过，缺件时要能一眼看出是"技能版本不匹配"，
# 而不是笼统的"获取失败"。把目录内容打出来，下一轮修的时候不用再让云端探一次。
if [ ! -f "$LB/space_api.py" ]; then
  echo "==> 资料库技能缺少 space_api.py（$LB）" >&2
  echo "    目录内容: $(ls "$LB" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi
if [ ! -f "$LB/drive/get_download_link.py" ]; then
  echo "==> 资料库技能缺少 drive/get_download_link.py（$LB）" >&2
  echo "    目录内容: $(ls "$LB" 2>/dev/null | tr '\n' ' ')" >&2
  echo "    drive 目录: $(ls "$LB/drive" 2>/dev/null | head -20 | tr '\n' ' ')" >&2
  exit 1
fi

CHK=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://spaceengine.agent-gateway.auth-proxy.local" 2>/dev/null || true)
if [ -z "$CHK" ] || [ "$CHK" = "000" ]; then
  echo "==> 资料库通道无响应（auth-proxy 网关连不上）" >&2
  exit 1
fi

TMP_BUNDLE="$(mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_TGZ="$(mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_DIR="$(mktemp -d)" || { echo "无法创建临时目录" >&2; exit 1; }
cleanup() { rm -f "$TMP_BUNDLE" "$TMP_TGZ"; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# 第 1 步：定位节点（list-nodes + 标题匹配，递归 1 层 folder）
NID=$("$PY" - "$LB" "$BUNDLE_ID" <<'PYEOF'
import json, os, subprocess, sys

lb, ident = sys.argv[1], sys.argv[2]
api = os.path.join(lb, "space_api.py")


def call(*args):
    p = subprocess.run([sys.executable, api] + list(args),
                       capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        sys.stderr.write("==> %s 失败: %s\n" % (" ".join(args), (p.stderr or "")[:200]))
        return None
    try:
        return json.loads(p.stdout)
    except Exception:
        sys.stderr.write("==> %s 返回非 JSON: %s\n" % (" ".join(args), (p.stdout or "")[:120]))
        return None


sp = call("space.workspace.list-user-spaces", "--limit", "100")
if sp is None:
    sys.exit(2)
personals = [s for s in ((sp.get("data") or {}).get("spaces") or [])
             if s.get("category") == "personal"]
if not personals:
    sys.stderr.write("==> 未找到个人空间（category=personal）\n")
    sys.exit(2)

hits = []
for s in personals:
    sid = s.get("spaceId") or ""
    queue, seen = [("", 0)], 0
    while queue and seen < 300:
        pid, depth = queue.pop(0)
        args = ["space.workspace.list-nodes", "--space-id", sid, "--limit", "100"]
        if pid:
            args += ["--parent-id", pid]
        nd = call(*args)
        if nd is None:
            continue
        data = nd.get("data") or {}
        nodes = data.get("nodes") or []
        seen += len(nodes)
        for n in nodes:
            if ident in (n.get("title") or ""):
                hits.append(n)
            if (n.get("kind") or n.get("nodeKind") or "") == "folder" and depth < 1:
                fid = n.get("id") or ""
                if fid:
                    queue.append((fid, depth + 1))

if not hits:
    sys.stderr.write("==> 资料库中未找到标题含「%s」的文件\n" % ident)
    sys.exit(1)

# 历史版本会并存（同名上传新建节点、无删除 API）：按标题里的版本号取最大，同版本取最短标题
import re


def _vkey(n):
    t = n.get("title") or ""
    m = re.findall(r"(\d+)\.(\d+)\.(\d+)(?:-local\.(\d+))?", t)
    if not m:
        return ((0, 0, 0, 0), -len(t))
    a, b, c, d = m[-1]
    return ((int(a), int(b), int(c), int(d or 0)), -len(t))


hits.sort(key=_vkey, reverse=True)
if len(hits) > 1:
    sys.stderr.write("WARN: 匹配到 %d 个 skill 包节点，已取版本最新者「%s」\n"
                     % (len(hits), hits[0].get("title")))
print(hits[0].get("id") or "")
PYEOF
)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$NID" ]; then
  echo "==> 定位资料库中的 skill 包失败（请确认「${BUNDLE_ID}.txt」已上传到个人空间根目录）" >&2
  exit 1
fi

# 第 2 步：取下载链接（只解析第一行 KS_DRIVE_DOWNLOAD）
DLINK_OUTPUT=$("$PY" "$LB/drive/get_download_link.py" --node-id "$NID" 2>/dev/null) || {
  echo "==> get_download_link 失败（node-id: ${NID}）" >&2
  exit 1
}
URL=$(printf '%s\n' "$DLINK_OUTPUT" | head -1 | sed 's/^KS_DRIVE_DOWNLOAD //' \
  | "$PY" -c 'import sys,json; print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null) || URL=""
[ -n "$URL" ] || { echo "==> 无法解析 download_url" >&2; exit 1; }

# 第 3 步：立即下载（COS 临时签名有时效）
curl -sSL --max-time 60 -o "$TMP_BUNDLE" "$URL" || { echo "==> 下载失败" >&2; exit 1; }
[ -s "$TMP_BUNDLE" ] || { echo "==> 下载内容为空" >&2; exit 1; }

# 第 4 步：解析元信息并校验 sha256
META="$(head -1 "$TMP_BUNDLE" | tr -d '\r')"
case "$META" in
  WBHELPER-BUNDLE*) : ;;
  *) echo "==> 首行不是 bundle 元信息，文件不匹配（首行：$(printf '%s' "$META" | head -c 100)）" >&2; exit 1 ;;
esac
VER="$(printf '%s' "$META" | sed -n 's/.*version=\([^ ]*\).*/\1/p')"
EXP="$(printf '%s' "$META" | sed -n 's/.*sha256=\([0-9a-fA-F]\{64\}\).*/\1/p')"
[ -n "$EXP" ] || { echo "==> 元信息缺少 sha256，拒绝解包" >&2; exit 1; }

tail -n +2 "$TMP_BUNDLE" | tr -d '\r\n' | base64 -d > "$TMP_TGZ" 2>/dev/null || true
[ -s "$TMP_TGZ" ] || { echo "==> base64 解码失败或为空" >&2; exit 1; }

GOT="$(sha256sum < "$TMP_TGZ" | awk '{print $1}')"
if [ "$GOT" != "$EXP" ]; then
  echo "==> sha256 校验失败，已中止解包" >&2
  echo "    期望: $EXP" >&2
  echo "    实际: $GOT" >&2
  exit 1
fi

# 第 5 步：解包（先解到临时目录，确认结构后再合并，避免半截安装）
tar -xzf "$TMP_TGZ" -C "$TMP_DIR" || { echo "==> tar 解包失败" >&2; exit 1; }
SRC="$TMP_DIR/wb-helper"
[ -d "$SRC" ] || { echo "==> 包内缺少 wb-helper/ 目录" >&2; exit 1; }

mkdir -p "$DEST_PARENT/wb-helper" || { echo "无法创建目标目录" >&2; exit 1; }
cp -a "$SRC/." "$DEST_PARENT/wb-helper/" || { echo "==> 复制失败" >&2; exit 1; }
chmod +x "$DEST_PARENT/wb-helper/scripts/"*.sh 2>/dev/null || true

echo "==> 安装完成：version=${VER:-未知} → $DEST_PARENT/wb-helper"
echo "==> 下一步：bash $DEST_PARENT/wb-helper/scripts/check_integrity.sh"

#!/bin/bash
# 引导脚本（bootstrap）：在没有 skill 的全新沙盒里，从资料库取回 skill 分支包并安装
# 用法: bash bootstrap_bundle.sh [--dest <skills 父目录>]
#   默认目标 ~/.workbuddy/skills（包内根目录 wb-helper/ 会被解到该目录下）
# 前置: CodeBuddy 沙盒（auth-proxy 网关注入资料库身份）+ python3 + curl
# 自包含：不依赖 skill 自身任何文件（此脚本存在的意义就是"skill 还不存在"）
# 安全约束: 只从资料库个人空间取包，sha256 不符即中止；不从任何网络地址安装 skill
#
# 修订（bootstrap v2，2026-11-04）：
#   · 多候选重试：资料库同名上传会新建节点且无删除 API，历史版本必然并存；
#     同一版本号也可能有多个节点，其中可能有上传不完整/已失效的坏节点。
#     旧逻辑只认排第一的那个，一旦命中坏节点就整体失败。现在按版本号取前 3 个依次尝试。
#   · 失败回显原始输出：旧逻辑用 2>/dev/null 吞掉 get_download_link 的报错，
#     只剩一句"无法解析 download_url"，无法定位。现在打印每个候选的退出码与返回首行。
set -u

BUNDLE_ID='wb-helper-local-bundle'
MAX_CANDIDATES=3
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

# 临时文件统一优先放 /tmp：Windows 上 mktemp 可能返回
# C:\Users\...\Temp/tmp.xxx 这种混合路径，GNU tar 的 -C 处理不了（会报 Cannot open）。
TMP_BUNDLE="$(mktemp /tmp/wbbsb.XXXXXX 2>/dev/null || mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_TGZ="$(mktemp /tmp/wbbst.XXXXXX 2>/dev/null || mktemp)" || { echo "无法创建临时文件" >&2; exit 1; }
TMP_DIR="$(mktemp -d /tmp/wbbsd.XXXXXX 2>/dev/null || mktemp -d)" || { echo "无法创建临时目录" >&2; exit 1; }
cleanup() { rm -f "$TMP_BUNDLE" "$TMP_TGZ"; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Windows 版 GNU tar（msys/MinGW）会把 C:/... 当成远程主机名而报
# "Cannot connect to C:"；Linux 沙盒不需要这个开关，也不能无条件加（BusyBox tar 不认）。
TAR_FORCE_LOCAL=""
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) TAR_FORCE_LOCAL="--force-local" ;;
esac

# 第 1 步：定位节点（list-nodes + 标题匹配，递归 1 层 folder），输出前 N 个候选 nodeId
NID_LIST=$("$PY" - "$LB" "$BUNDLE_ID" "$MAX_CANDIDATES" <<'PYEOF'
import json, os, subprocess, sys

lb, ident, maxc = sys.argv[1], sys.argv[2], int(sys.argv[3])
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
top = hits[:maxc]
if len(hits) > 1:
    sys.stderr.write("WARN: 匹配到 %d 个节点，按版本取前 %d 个候选：\n" % (len(hits), len(top)))
    for n in top:
        sys.stderr.write("       - %s  node=%s\n" % (n.get("title"), n.get("id")))
for n in top:
    nid = n.get("id") or ""
    if nid:
        print(nid)
PYEOF
)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$NID_LIST" ]; then
  echo "==> 定位资料库中的 skill 包失败（请确认「${BUNDLE_ID}」已上传到个人空间根目录）" >&2
  exit 1
fi

# 第 2~5 步：逐个候选尝试（取链接 → 下载 → 校验 → 解包），第一个成功的即采用
LAST_ERR=""
BUNDLE_VER=""

try_install_from() {
  local nid="$1" out rc first url meta exp got src
  out=$("$PY" "$LB/drive/get_download_link.py" --node-id "$nid" 2>&1)
  rc=$?
  first=$(printf '%s\n' "$out" | head -1)

  # 首行形如 `KS_DRIVE_DOWNLOAD {"download_url": "..."}`；不是这个形态说明接口返回异常
  url=$(printf '%s' "$first" | sed 's/^KS_DRIVE_DOWNLOAD //' | "$PY" -c '
import sys, json
raw = sys.stdin.read().strip()
try:
    print(json.loads(raw).get("download_url") or "")
except Exception:
    print("")
' 2>/dev/null)
  if [ -z "$url" ]; then
    LAST_ERR="get_download_link 退出码=${rc}，首行(前 160 字符)=$(printf '%s' "$first" | head -c 160)"
    return 1
  fi

  # COS 临时签名有时效，拿到链接立即下载
  : > "$TMP_BUNDLE"
  if ! curl -sSL --max-time 60 -o "$TMP_BUNDLE" "$url"; then
    LAST_ERR="curl 下载失败（签名可能已过期）"
    return 1
  fi
  if [ ! -s "$TMP_BUNDLE" ]; then
    LAST_ERR="下载内容为空（节点可能是空文件或上传未完成）"
    return 1
  fi

  meta="$(head -1 "$TMP_BUNDLE" | tr -d '\r')"
  case "$meta" in
    WBHELPER-BUNDLE*) : ;;
    *)
      LAST_ERR="首行不是 bundle 元信息（首行前 100 字符=$(printf '%s' "$meta" | head -c 100)）"
      return 1
      ;;
  esac

  exp="$(printf '%s' "$meta" | sed -n 's/.*sha256=\([0-9a-fA-F]\{64\}\).*/\1/p')"
  if [ -n "$exp" ]; then
    : > "$TMP_TGZ"
    tail -n +2 "$TMP_BUNDLE" | tr -d '\r\n' | base64 -d > "$TMP_TGZ" 2>/dev/null || true
    if [ ! -s "$TMP_TGZ" ]; then
      LAST_ERR="base64 解码失败或为空（包文件可能被截断）"
      return 1
    fi
    got="$(sha256sum < "$TMP_TGZ" | awk '{print $1}')"
    if [ "$got" != "$exp" ]; then
      LAST_ERR="sha256 校验失败（期望 ${exp:0:16}…）"
      return 1
    fi
  else
    echo "    WARN: 元信息缺少 sha256，跳过校验" >&2
  fi

  # 解包到临时目录，确认结构后再合并，避免半截安装；每换一个候选都重建空目录
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR" || { LAST_ERR="无法重建临时目录"; return 1; }
  if ! tar $TAR_FORCE_LOCAL -xzf "$TMP_TGZ" -C "$TMP_DIR"; then
    LAST_ERR="tar 解包失败"
    return 1
  fi
  src="$TMP_DIR/wb-helper"
  if [ ! -d "$src" ]; then
    LAST_ERR="包内缺少 wb-helper/ 目录（包结构异常）"
    return 1
  fi

  mkdir -p "$DEST_PARENT/wb-helper" || { LAST_ERR="无法创建目标目录"; return 1; }
  if ! cp -a "$src/." "$DEST_PARENT/wb-helper/"; then
    LAST_ERR="复制到目标目录失败"
    return 1
  fi
  chmod +x "$DEST_PARENT/wb-helper/scripts/"*.sh 2>/dev/null || true

  BUNDLE_VER="$(printf '%s' "$meta" | sed -n 's/.*version=\([^ ]*\).*/\1/p')"
  return 0
}

OK=0
USED_NID=""
FAILS=""
for nid in $NID_LIST; do
  echo "==> 尝试节点 ${nid}" >&2
  if try_install_from "$nid"; then
    OK=1
    USED_NID="$nid"
    break
  fi
  echo "    失败：${LAST_ERR}" >&2
  FAILS="${FAILS}    - node ${nid}: ${LAST_ERR}
"
done

if [ "$OK" -ne 1 ]; then
  echo "==> 所有候选节点都取不到可用的安装包" >&2
  printf '%s' "$FAILS" >&2
  echo "==> 原因可能是：节点上传不完整 / 已被删除 / 与版本号不匹配" >&2
  echo "==> 处置：在本机重新 bash scripts/pack_bundle.sh 并上传新 bundle（文件名带更大版本号）" >&2
  exit 1
fi

echo "==> 安装完成：version=${BUNDLE_VER:-未知} → $DEST_PARENT/wb-helper"
echo "==> 使用节点：${USED_NID}"
echo "==> 下一步：bash $DEST_PARENT/wb-helper/scripts/check_integrity.sh"

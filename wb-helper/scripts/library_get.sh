#!/bin/bash
# 按标题标识从资料库（Library）下载 drive 文件到本地指定路径
# 用法: library_get.sh <标题包含的标识> <输出文件路径>
# 前置: 运行于 CodeBuddy 沙盒内（身份由 auth-proxy 网关在传输层注入，进程内不持任何资料库凭证）；
#       本机没有该网关，本脚本在本机必然失败——仅沙盒/定时任务环境使用
# 说明: drive 类文件不进搜索索引，必须 list-nodes + 标题匹配；递归 1 层 folder（用户可能移动过文件）
set -u

IDENT="${1:-}"
OUT="${2:-}"
if [ -z "$IDENT" ] || [ -z "$OUT" ]; then
  echo "用法: $0 <标题包含的标识> <输出文件路径>" >&2
  exit 2
fi

PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3 / python / py" >&2; exit 1; }

# 定位资料库技能根目录：写死 + fallback（定时任务环境不保证注入 CODEBUDDY_SKILL_DIR）
LB=/root/.codebuddy/skills/library
[ -d "$LB" ] || LB=/opt/sandbox-prefetched/blobs/skill/library/latest
if [ ! -d "$LB" ]; then
  echo "==> 无法定位资料库技能目录（/root/.codebuddy/skills/library 与 /opt/sandbox-prefetched/... 均不存在）" >&2
  echo "==> 当前环境可能不是 CodeBuddy 沙盒；本机没有资料库网关" >&2
  exit 1
fi
export CODEBUDDY_SKILL_DIR="$LB"

# 通道自检：auth-proxy 网关在传输层注入身份，能连上（任意 HTTP 码，含 404）即通道可用
CHK=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://spaceengine.agent-gateway.auth-proxy.local" 2>/dev/null || true)
if [ -z "$CHK" ] || [ "$CHK" = "000" ]; then
  echo "==> 资料库通道无响应（10 秒内无法连接 auth-proxy 网关）" >&2
  exit 1
fi

# 定位节点：单个 python 进程完成「列空间 → list-nodes → 递归 folder → 标题匹配」
# 命中多个时取标题最短者（最贴合标识本身的那个），并打印 WARN 提示并存风险
NID=$("$PY" - "$LB" "$IDENT" <<'PYEOF'
import json, os, subprocess, sys

lb, ident = sys.argv[1], sys.argv[2]
api = os.path.join(lb, "space_api.py")


def call(*args):
    p = subprocess.run([sys.executable, api] + list(args),
                       capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        sys.stderr.write("==> %s 失败（退出码 %d，stderr: %s）\n"
                         % (" ".join(args), p.returncode, (p.stderr or "")[:200]))
        return None
    try:
        d = json.loads(p.stdout)
    except Exception:
        sys.stderr.write("==> %s 返回非 JSON（前 120 字符: %s）\n"
                         % (" ".join(args), (p.stdout or "")[:120]))
        return None
    # 接口名/参数错误时 space_api.py 退出码仍为 0，错误码藏在响应体里，必须显式识别
    body = json.dumps(d, ensure_ascii=False).lower()
    for marker in ("unknown api", "invalid_params"):
        if marker in body:
            sys.stderr.write("==> 接口调用异常（%s）：%s\n" % (marker, " ".join(args)))
            return None
    return d


sp = call("space.workspace.list-user-spaces", "--limit", "100")
if sp is None:
    sys.exit(2)
spaces = (sp.get("data") or {}).get("spaces") or []
personals = [s for s in spaces if s.get("category") == "personal"]
if not personals:
    sys.stderr.write("==> 未找到个人空间（category=personal）\n")
    sys.exit(2)

hits, diag = [], []
for s in personals:
    sid, stitle = s.get("spaceId") or "", s.get("title") or ""
    queue, seen, titles = [("", 0)], 0, []
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
            t = n.get("title") or ""
            titles.append(t[:40])
            if ident in t:
                hits.append(n)
            if (n.get("kind") or n.get("nodeKind") or "") == "folder" and depth < 1:
                fid = n.get("id") or ""
                if fid:
                    queue.append((fid, depth + 1))
    diag.append("空间「%s」共 %d 个节点，标题：%s" % (stitle, len(titles), "、".join(titles) or "（空）"))

if not hits:
    sys.stderr.write("==> 资料库中未找到标题含「%s」的文件\n" % ident)
    for line in diag:
        sys.stderr.write("    诊断: %s\n" % line)
    sys.exit(1)

# 命中多个时按「版本号最大」取（文件名形如 xxx-v1.5.0-local.3.txt）。
# 资料库同名上传会新建节点且无删除 API，历史版本必然会并存，靠版本号排序才能稳定取到最新。
# 注意 -local.N 后缀必须参与比较：1.5.0 主体不变、只改 local 后段时，
# 若正则只取前三位，(1,5,0) 会让 local.1/2/3 全部平局，取谁取决于节点返回顺序 —— 会一直吃旧包。
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
    sys.stderr.write("WARN: 匹配到 %d 个节点（%s），已按版本号取最新「%s」\n"
                     % (len(hits), ", ".join(repr(n.get("title")) for n in hits),
                        hits[0].get("title")))

print(hits[0].get("id") or "")
PYEOF
)
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$NID" ]; then
  echo "==> 未能定位资料库节点「${IDENT}」" >&2
  exit 1
fi

# 取下载链接：get_download_link.py 输出两行，只解析第一行（前缀 KS_DRIVE_DOWNLOAD）
DLINK_OUTPUT=$("$PY" "$LB/drive/get_download_link.py" --node-id "$NID" 2>/dev/null) || {
  echo "==> get_download_link 调用失败（node-id: ${NID}）" >&2
  exit 1
}
URL=$(printf '%s\n' "$DLINK_OUTPUT" | head -1 | sed 's/^KS_DRIVE_DOWNLOAD //' \
  | "$PY" -c 'import sys, json; print(json.load(sys.stdin).get("download_url", ""))' 2>/dev/null) || URL=""
[ -n "$URL" ] || {
  echo "==> 无法解析 download_url（首行前 120 字符：$(printf '%s' "$DLINK_OUTPUT" | head -1 | head -c 120)）" >&2
  exit 1
}

# 立即下载：download_url 带 COS 临时签名，有时效
curl -sSL --max-time 60 -o "$OUT" "$URL" || {
  echo "==> 下载失败（签名可能已过期，请重试）" >&2
  exit 1
}
[ -s "$OUT" ] || { echo "==> 下载结果为空文件" >&2; exit 1; }
echo "==> 已下载「${IDENT}」→ ${OUT}"

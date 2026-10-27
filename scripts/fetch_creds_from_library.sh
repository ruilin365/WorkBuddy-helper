#!/bin/bash
# 从资料库（Library）拉取凭证文件并导入 skill 的 config/（沙盒端用，与本机 make_cred_file.sh 配对）
# 用法: fetch_creds_from_library.sh
# 前置: 运行于 CodeBuddy 沙盒内（身份由 auth-proxy 网关在传输层注入，脚本进程内不持任何凭证）；
#       本机没有资料库网关，本脚本在本机必然失败——仅沙盒/定时任务环境使用
# 无状态、可重复执行：每次独立完成「定位 → 自检 → 拉取 → 导入」，不依赖任何上次残留（手册 §6.10.1）
set -u

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），导入目标 = skill 自身 config/
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

# Windows 上 python 命令名可能是 python / py（沙盒内固定为 python3）
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || { echo "需要 python3/python/py，请先安装 Python 3" >&2; exit 1; }

# === 第 1 步：定位资料库技能根目录（写死 + fallback，手册 §0：定时任务环境不保证注入 CODEBUDDY_SKILL_DIR） ===
# 优先符号链接路径（每次会话启动重建、随版本指向最新），镜像内实体路径兜底
LB=/root/.codebuddy/skills/library
[ -d "$LB" ] || LB=/opt/sandbox-prefetched/blobs/skill/library/latest
if [ ! -d "$LB" ]; then
  echo "==> 无法定位资料库技能目录：/root/.codebuddy/skills/library 与 /opt/sandbox-prefetched/blobs/skill/library/latest 均不存在" >&2
  echo "==> 当前环境可能不是 CodeBuddy 沙盒（本机没有资料库网关与技能，本脚本仅沙盒内可用）" >&2
  exit 1
fi
# 第 2 步：显式注入技能根目录（不依赖宿主注入）
export CODEBUDDY_SKILL_DIR="$LB"

# === 第 3 步：通道自检——auth-proxy 网关在传输层注入身份，能连上（任意 HTTP 码，含 404）即通道可用 ===
CHK=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://spaceengine.agent-gateway.auth-proxy.local" 2>/dev/null || true)
if [ -z "$CHK" ] || [ "$CHK" = "000" ]; then
  echo "==> 资料库通道无响应（10 秒内无法连接 auth-proxy 网关，无任何 HTTP 响应）" >&2
  echo "==> 请确认当前为 CodeBuddy 沙盒环境且网络可达" >&2
  exit 1
fi

# === 硬编码常量（与 make_cred_file.sh / push_creds_to_library.sh 必须完全一致，改名需三端同步）===
CREDS_WARNING='重要凭证，切勿分享和发给别人！！！'
CREDS_ID='sandbox-creds-WB2'
CREDS_FILE_NAME="${CREDS_WARNING}${CREDS_ID}.txt"

# === 第 4 步：定位凭证节点（单个 python 进程完成：列空间 → 逐空间 list-nodes → folder 递归 → 匹配）===
# 手册 §1.7：drive 类文件不进搜索索引，绝不能用 search-nodes 定位，必须 list-nodes + 标题匹配。
# 匹配策略：后端会把标题扩展名剥掉（上传 x.txt → title 为 x）且文件名带警告语前缀，因此按
# "标题包含稳定标识 CREDS_ID"匹配；命中多个时优先取与预期标题完全一致者（含/不含扩展名两种形态
# 都认），仍有歧义则 WARN 并取第一个（失败要可见，手册 §6.10.5）。
# 鲁棒性加固（2026-09-21 云端"文件在但匹配失败"后加入）：
# - 遍历全部 personal 空间，不假设只有一个「我的资料」
# - 递归进入 folder（用户可能在客户端把凭证移进文件夹；list-nodes 默认只列当前层，手册 §1.2 --parent-id）
# - 失败时输出诊断（每空间节点数、标题列表、疑似分页键），便于分辨"空间不对/被移动/分页截断/返回结构变化"
NID=""
NID=$("$PY" - "$LB" "$CREDS_ID" "$CREDS_WARNING" <<'PYEOF'
import json, os, subprocess, sys

lb, cid, cwarn = sys.argv[1], sys.argv[2], sys.argv[3]
expected = {cwarn + cid, cwarn + cid + ".txt", cid, cid + ".txt"}
api = os.path.join(lb, "space_api.py")

def call(*args):
    try:
        p = subprocess.run([sys.executable, api] + list(args),
                           capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, "调用异常: %s" % e
    if p.returncode != 0:
        return None, "退出码 %d（stderr: %s）" % (p.returncode, (p.stderr or "")[:120])
    try:
        return json.loads(p.stdout), None
    except Exception:
        return None, "JSON 解析失败（输出前 120 字符: %s）" % (p.stdout or "")[:120]


def check_body(d, args):
    # 接口名错误（如把 list-nodes 写成 list-node）或参数非法时，space_api.py 会把错误码放在
    # 响应体里且退出码为 0——必须显式识别，否则会被当成"正常返回但无匹配"静默吞掉（2026-09-22 实际踩坑）
    if isinstance(d, dict):
        body = json.dumps(d, ensure_ascii=False).lower()
        for marker, desc in (("unknown api", "接口名不被识别（unknown api）"),
                             ("invalid_params", "参数非法（INVALID_PARAMS）")):
            if marker in body:
                return "%s：%s" % (desc, " ".join(args))
    return None

d, err = call("space.workspace.list-user-spaces", "--limit", "100")
if err is None:
    err = check_body(d, ["space.workspace.list-user-spaces"])
if err:
    sys.stderr.write("==> list-user-spaces 失败：%s\n" % err)
    sys.exit(2)
spaces = (d.get("data") or {}).get("spaces") or []
personals = [s for s in spaces if s.get("category") == "personal"]
if not personals:
    sys.stderr.write("==> 未找到个人空间（category=personal），原始返回前 200 字符：%s\n"
                     % json.dumps(d, ensure_ascii=False)[:200])
    sys.exit(2)

hits, diag = [], []
for s in personals:
    sid = s.get("spaceId") or ""
    stitle = s.get("title") or ""
    queue = [("", 0)]          # (parent_id, depth)；空串 = 空间根
    seen, stitles = 0, []
    while queue and seen < 300:
        pid, depth = queue.pop(0)
        args = ["space.workspace.list-nodes", "--space-id", sid, "--limit", "100"]
        if pid:
            args += ["--parent-id", pid]
        nd, err = call(*args)
        if err is None:
            err = check_body(nd, args)
        if err:
            diag.append("空间「%s」list-nodes(parent=%s) 失败：%s" % (stitle, pid or "根", err))
            continue
        data = nd.get("data") or {}
        nodes = data.get("nodes") or []
        seen += len(nodes)
        for n in nodes:
            t = n.get("title") or ""
            stitles.append(t[:40])
            if cid in t:
                hits.append(n)
            if (n.get("kind") or n.get("nodeKind") or "") == "folder" and depth < 3:
                fid = n.get("id") or ""
                if fid:
                    queue.append((fid, depth + 1))
        pkeys = [k for k in ("has_more", "hasMore", "next_cursor", "nextCursor", "total") if k in data]
        if pkeys:
            diag.append("空间「%s」list-nodes 返回含疑似分页键 %s（若凭证在截断页之后会匹配不到）"
                        % (stitle, {k: data.get(k) for k in pkeys}))
    diag.append("空间「%s」(%s)：共 %d 个节点，标题：%s"
                % (stitle, sid, len(stitles), "、".join(stitles) or "（空）"))

if not hits:
    sys.stderr.write("==> 全部 personal 空间中均未找到凭证文件（标识「%s」）\n" % cid)
    for line in diag:
        sys.stderr.write("    诊断: %s\n" % line)
    sys.exit(1)
if len(hits) > 1:
    sys.stderr.write("WARN: 资料库中匹配到 %d 个凭证节点（%s），已取第一个；请用 --node-id 覆盖上传避免并存\n"
                     % (len(hits), ", ".join(repr(n.get("title")) for n in hits)))
exact = [n for n in hits if (n.get("title") or "") in expected]
print(((exact or hits)[0]).get("id") or "")
PYEOF
)
RC=$?
if [ "$RC" -eq 2 ]; then
  echo "==> 资料库通道/技能层失败（诊断见上），请确认当前为 CodeBuddy 沙盒环境且资料库技能可用" >&2
  exit 1
fi
[ -n "$NID" ] || {
  echo "==> 请在本机运行 scripts/make_cred_file.sh 生成「${CREDS_FILE_NAME}」并上传到资料库个人空间（我的资料）" >&2
  echo "==> 注意：资料库会把标题扩展名剥掉，属正常现象；定位按标识「${CREDS_ID}」匹配（含 folder 递归）" >&2
  exit 1
}

# === 第 6 步：取下载链接。get_download_link.py 输出两行，只取第 1 行解析（手册 §1.5/§4.3 的坑） ===
DLINK_OUTPUT=$("$PY" "$LB/drive/get_download_link.py" --node-id "$NID" 2>/dev/null) || {
  echo "==> get_download_link 调用失败（node-id: ${NID}）" >&2
  exit 1
}
URL=$(printf '%s\n' "$DLINK_OUTPUT" | head -1 | sed 's/^KS_DRIVE_DOWNLOAD //' \
  | "$PY" -c 'import sys, json; print(json.load(sys.stdin).get("download_url", ""))' 2>/dev/null) || URL=""
[ -n "$URL" ] || {
  echo "==> 无法从 get_download_link 输出中解析 download_url（输出首行：$(printf '%s' "$DLINK_OUTPUT" | head -1 | head -c 120)）" >&2
  exit 1
}

# === 第 7 步：立即下载。download_url 带 COS 临时签名（x-cos-security-token），有时效，取到后马上用 ===
TMP=$(mktemp) || { echo "==> 无法创建临时文件" >&2; exit 1; }
# 第 9 步：临时文件清理——trap 确保异常退出也会删除
trap 'rm -f "$TMP"' EXIT
curl -sSL --max-time 30 -o "$TMP" "$URL" || {
  echo "==> 凭证文件下载失败（download_url 带 COS 临时签名有时效，可能已过期，请重试或重新生成上传）" >&2
  exit 1
}

# === 第 8 步：提取 WB1: 行（文件第 1 行为中文警告，跳过），经 stdin 喂给 import_creds.sh ===
# 不走命令行参数，避免凭证进入 ps argv（本项目既有安全约定）
WB1_LINE=$(grep -m1 '^WB1:' "$TMP" 2>/dev/null) || WB1_LINE=""
[ -n "$WB1_LINE" ] || {
  echo "==> 下载内容中找不到以 WB1: 开头的凭证行（文件内容与预期不符）" >&2
  echo "==> 请在本机重新运行 scripts/make_cred_file.sh 生成后覆盖上传到资料库" >&2
  exit 1
}
if ! printf '%s\n' "$WB1_LINE" | bash "$DIR/scripts/import_creds.sh"; then
  echo "==> 凭证导入失败（import_creds.sh 返回非 0，详见其输出）" >&2
  exit 1
fi

echo "==> 已从资料库拉取凭证并导入 ${CONFIG_DIR}"

# === 快照 refresh_token（供 sandbox_run.sh 判断"本次运行期间是否发生过刷新"） ===
# refresh_token 每次续期都会轮换（refresh_token.sh 在线写回新值）。此处把导入当时的快照存到
# config/.rt_snapshot；之后若 config/refresh_token 与快照不一致，即说明本次运行内发生了刷新，
# 需要把新凭证回写资料库（push_creds_to_library.sh）以滚动续期，否则资料库那份凭证在上传约 60 天后过期。
# 注意：快照本身是凭证明文，必须 600 权限（与 config/ 下其他凭证文件同级保护）；回写成功时
# push_creds_to_library.sh 也会更新此快照，两者保持同一约定。
if [ -s "$CONFIG_DIR/refresh_token" ]; then
  cp "$CONFIG_DIR/refresh_token" "$CONFIG_DIR/.rt_snapshot"
  chmod 600 "$CONFIG_DIR/.rt_snapshot"
fi
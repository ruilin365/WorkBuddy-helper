#!/bin/bash
# 把本地 config/ 的凭证回写到资料库（覆盖同一节点），让长效凭证（refresh token）的 60 天窗口滚动续期
# 背景：沙盒持久卷按实例绑定、换实例即空盘（手册 §6.1）。签到脚本在 token 临近过期时会自动调用
#       refresh_token.sh 在线续期并写回 config/，但新凭证只存在于沙盒本地、实例回收即丢；
#       资料库中那份凭证的 refresh token 在上传后约 60 天过期，届时云端断链，需人工回本机重新生成上传。
#       本脚本在刷新发生后把新凭证覆盖回传资料库（个人空间同名节点，手册 §2.2），实现滚动续期、零人工干预。
# 用法: push_creds_to_library.sh
# 环境变量:
#   WB_NO_LIBRARY_PUSHBACK=1   跳过回写（打印一行说明后 exit 0，供用户关闭此功能）
#   WB_PUSHBACK_SOFTFAIL=1     软失败模式（供 sandbox_run.sh 在签到成功后调用）：任何失败只打印
#                              WARN 并 exit 0——签到本身已成功，回写失败不该让整次任务判定为失败
# 与 fetch_creds_from_library.sh 配对：本脚本回写、对方拉取；本机没有资料库网关，本脚本仅沙盒内可用
# 成功时同步更新 config/.rt_snapshot（与拉取脚本写入快照的约定一致，sandbox_run 靠它判断下次是否还需回写）
set -u

# 用户关闭开关：任何环境都直接跳过（即使本机没有资料库网关也只打印一行说明）
if [ "${WB_NO_LIBRARY_PUSHBACK:-}" = "1" ]; then
  echo "==> WB_NO_LIBRARY_PUSHBACK=1：已跳过凭证回写资料库"
  exit 0
fi

# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），凭证目录随 skill 实际安装位置而定
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
CONFIG_DIR="${WB_CONFIG_DIR:-$DIR/config}"

# ==== 本地安全策略：默认禁止把凭证上传到资料库 ====
# 凭证离开本机是本 skill 最高风险的动作（长效 refresh token 落到云盘节点），
# 本机客户端场景完全用不到，因此默认关闭，需显式放开才上传。
. "$DIR/scripts/_policy.sh"
if [ "${WB_ALLOW_UPLOAD_CREDS:-0}" != "1" ]; then
  echo "==> 凭证上传资料库已被策略禁用（config/policy.env: WB_ALLOW_UPLOAD_CREDS=0），未上传任何内容"
  exit 0
fi

# === 硬编码常量（与 make_cred_file.sh / fetch_creds_from_library.sh 必须完全一致，改名需三端同步）===
CREDS_WARNING='重要凭证，切勿分享和发给别人！！！'
CREDS_ID='sandbox-creds-WB2'
CREDS_FILE_NAME="${CREDS_WARNING}${CREDS_ID}.txt"

SOFTFAIL="${WB_PUSHBACK_SOFTFAIL:-}"

# 统一失败出口：独立运行（缺省）报错后 exit 1；软失败模式（sandbox_run.sh 调用）只打印 WARN 后 exit 0
fail() {
  if [ "${SOFTFAIL}" = "1" ]; then
    echo "WARN: 凭证回写失败（软失败模式，不影响签到任务结果）：$*" >&2
    exit 0
  fi
  echo "==> 凭证回写失败：$*" >&2
  exit 1
}

# Windows 上 python 命令名可能是 python / py（沙盒内固定为 python3）
PY="$(command -v python3 || command -v python || command -v py)"
[ -n "$PY" ] || fail "需要 python3/python/py，请先安装 Python 3"

# === 第 1 步：定位资料库技能根目录（写死 + fallback，手册 §0：定时任务环境不保证注入 CODEBUDDY_SKILL_DIR） ===
# 优先符号链接路径（每次会话启动重建、随版本指向最新），镜像内实体路径兜底
LB=/root/.codebuddy/skills/library
[ -d "$LB" ] || LB=/opt/sandbox-prefetched/blobs/skill/library/latest
if [ ! -d "$LB" ]; then
  fail "无法定位资料库技能目录：/root/.codebuddy/skills/library 与 /opt/sandbox-prefetched/blobs/skill/library/latest 均不存在；当前环境可能不是 CodeBuddy 沙盒（本机没有资料库网关与技能，本脚本仅沙盒内可用）"
fi
# 第 2 步：显式注入技能根目录（不依赖宿主注入）
export CODEBUDDY_SKILL_DIR="$LB"

# === 第 3 步：通道自检——auth-proxy 网关在传输层注入身份，能连上（任意 HTTP 码，含 404）即通道可用 ===
CHK=$(timeout 10 curl -s -o /dev/null -w "%{http_code}" "http://spaceengine.agent-gateway.auth-proxy.local" 2>/dev/null || true)
if [ -z "${CHK}" ] || [ "${CHK}" = "000" ]; then
  fail "资料库通道无响应（10 秒内无法连接 auth-proxy 网关，无任何 HTTP 响应）"
fi

# === 第 4 步：定位既有凭证节点（与 fetch_creds_from_library.sh 同一套定位逻辑，改名/改策略需同步）===
# 手册 §1.7：drive 类文件不进搜索索引，绝不能用 search-nodes 定位，必须 list-nodes + 标题匹配。
# 匹配策略：后端会把标题扩展名剥掉（上传 x.txt → title 为 x）且文件名带警告语前缀，因此按
# "标题包含稳定标识 CREDS_ID"匹配；命中多个时优先取与预期标题完全一致者，仍有歧义则 WARN 取第一个。
# 鲁棒性加固（2026-09-21 云端"文件在但匹配失败"后加入）：
# - 遍历全部 personal 空间，不假设只有一个「我的资料」
# - 递归进入 folder（用户可能在客户端把凭证移进文件夹；list-nodes 默认只列当前层，手册 §1.2 --parent-id）
# - 未找到时输出诊断（每空间节点数、标题列表、疑似分页键）后继续走"新建上传"分支；
#   若凭证明明已上传过却匹配不到，诊断信息可直接定位原因（空间不对/被移动/分页截断/返回结构变化）
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
    sys.stderr.write("==> 资料库中未找到既有凭证节点，将新建上传（若确认已上传过，请据以下诊断排查）\n")
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
  fail "资料库通道/技能层失败（诊断见上），请确认当前为 CodeBuddy 沙盒环境且资料库技能可用"
fi

# 解析 node-info 输出：两行，第 1 行 nodeId、第 2 行 version（字段名未穷举，容错解析；取不到时为空串）
parse_node_info() {
  printf '%s' "$1" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get("data") or {}
    if not isinstance(data, dict):
        data = {}
    nid = data.get("nodeId") or data.get("node_id") or data.get("id") or ""
    ver = data.get("version")
    print(nid)
    print("" if ver is None else str(ver))
except Exception:
    print(""); print("")
' 2>/dev/null || printf '\n\n'
}

# 既有节点：先记录旧 version，便于覆盖后对比递增（手册 §2.2：覆盖必须带 --node-id）
OLD_VER="?"
if [ -n "$NID" ]; then
  OLD_INFO=$("$PY" "$LB/space_api.py" space.workspace.node-info --node-id "$NID" 2>/dev/null) || OLD_INFO=""
  if printf '%s' "$OLD_INFO" | grep -qi "unknown api"; then
    echo "WARN: node-info 接口名不被识别（unknown api），version 对比不可用" >&2
    OLD_INFO=""
  fi
  if [ -n "$OLD_INFO" ]; then
    OLD_VER=$(printf '%s\n' "$(parse_node_info "$OLD_INFO")" | sed -n '2p')
    [ -n "$OLD_VER" ] || OLD_VER="?"
  else
    echo "WARN: 查询既有节点旧 version 失败（node-id: ${NID}），继续覆盖上传" >&2
  fi
fi

# === 第 6 步：用 make_cred_file.sh 生成凭证文件到 mktemp 临时路径（600 权限），不要生成到 config/ 留下常驻明文 ===
CRED_TMPD=$(mktemp -d) || fail "无法创建临时目录"
chmod 700 "$CRED_TMPD"
# 临时文件清理——trap 确保任何失败路径也会删除
trap 'rm -rf "$CRED_TMPD"' EXIT
if ! bash "$DIR/scripts/make_cred_file.sh" "$CRED_TMPD/$CREDS_FILE_NAME"; then
  fail "make_cred_file.sh 生成凭证文件失败（详见其输出）"
fi

# === 第 7 步：上传。节点已存在 → 带 --node-id 覆盖（手册 §2.2：不带 --node-id 会创建同名新节点、
# 产生重复且旧链接仍指向旧内容；个人空间同名不自动重命名会并存，且没有删除节点的 API）；
# 节点不存在 → 新建上传（默认进个人空间） ===
if [ -n "$NID" ]; then
  UPLOAD_OUT=$("$PY" "$LB/drive/upload_drive_file.py" "$CRED_TMPD/$CREDS_FILE_NAME" --node-id "$NID" --file-name "$CREDS_FILE_NAME" 2>/dev/null) \
    || fail "覆盖上传失败（node-id: ${NID}）"
else
  UPLOAD_OUT=$("$PY" "$LB/drive/upload_drive_file.py" "$CRED_TMPD/$CREDS_FILE_NAME" --file-name "$CREDS_FILE_NAME" 2>/dev/null) \
    || fail "新建上传失败（默认进个人空间，请确认资料库可写）"
  NID_NEW=$(printf '%s' "$UPLOAD_OUT" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get("data") or {}
    if not isinstance(data, dict):
        data = {}
    print(data.get("node_block_id") or data.get("nodeId") or data.get("node_id") or "")
except Exception:
    print("")
' 2>/dev/null) || NID_NEW=""
  if [ -z "$NID_NEW" ]; then
    fail "上传成功但无法从返回中解析 node_block_id，请人工到资料库核对节点"
  fi
  NID="$NID_NEW"
  CREATED=1
fi

# === 第 8 步：上传后只读复查（手册 §2.2：nodeId 不变、version 递增，不确定先查询不要盲目重试） ===
NEW_INFO=$("$PY" "$LB/space_api.py" space.workspace.node-info --node-id "$NID" 2>/dev/null) \
  || fail "上传后 node-info 复查失败（node-id: ${NID}）"
if printf '%s' "$NEW_INFO" | grep -qi "unknown api"; then
  fail "node-info 接口名不被识别（unknown api）——请核对资料库技能实际接口名后更新脚本"
fi
PARSE_INFO=$(parse_node_info "$NEW_INFO")
NID2=$(printf '%s\n' "$PARSE_INFO" | sed -n '1p')
VER2=$(printf '%s\n' "$PARSE_INFO" | sed -n '2p')
if [ -z "$NID2" ]; then
  echo "WARN: 无法从 node-info 输出解析 nodeId，跳过节点一致性确认（version 仍输出）" >&2
else
  if [ "$NID2" != "$NID" ]; then
    fail "上传后节点 nodeId 从 ${NID} 变为 ${NID2}，与预期不符，请人工检查资料库是否出现重复节点"
  fi
fi
VER2="${VER2:-?}"

# === 成功收尾：更新 .rt_snapshot ===
# 软失败模式下调用方（sandbox_run.sh）无法靠退出码分辨成败，.rt_snapshot 是否已与 refresh_token 对齐
# 是判定的权威依据，因此只在"上传 + 复查通过"后更新。快照本身含凭证明文，必须 600 权限
if [ -s "$CONFIG_DIR/refresh_token" ]; then
  printf '%s\n' "$(cat "$CONFIG_DIR/refresh_token")" > "$CONFIG_DIR/.rt_snapshot"
  chmod 600 "$CONFIG_DIR/.rt_snapshot"
fi

if [ "${CREATED:-0}" = "1" ]; then
  echo "==> 凭证已写入资料库（新建节点 ${NID}，version ${VER2}）"
else
  echo "==> 凭证已回写资料库（节点 ${NID}，version ${OLD_VER} → ${VER2}）"
fi
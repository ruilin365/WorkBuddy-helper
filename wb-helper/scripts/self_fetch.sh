#!/bin/bash
# 零介入凭证自取 · 编排器（macOS；加密存储环境的默认凭证获取路径）
# 流程：重启 WorkBuddy(带 --inspect) → CDP 取 atRestSecretKey → 内存解密 → 写 config/ → 恢复应用
# 安全约定：密钥与明文凭证只在内存；本脚本与 node 子进程不输出任何凭证值
# 用法：
#   bash scripts/self_fetch.sh                 # 立即执行自取（终端一行命令的落地形态）
#   bash scripts/self_fetch.sh --install-launchd   # 写 launchd 任务（RunAtLoad 即跑）并输出一行加载命令
#   bash scripts/self_fetch.sh --from-launchd      # launchd 触发模式：跑完自卸载自删除
set -u

SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
SKILL_DIR="$(cd "$(dirname "$SELF")/.." && pwd)" || { echo "无法定位 skill 根目录" >&2; exit 1; }
PLIST="$HOME/Library/LaunchAgents/com.user.wb-selffetch.plist"
LABEL="com.user.wb-selffetch"
IS_MAC=0
[ "$(uname -s)" = "Darwin" ] && IS_MAC=1

# 读取本地运行策略（config/policy.env），使开关与其它脚本一致
. "$SKILL_DIR/scripts/_policy.sh"

# ==== 本地安全策略：凭证自取默认禁用 ====
# 该链路会强制关闭并重启 WorkBuddy（未保存内容会丢），并短暂开放 127.0.0.1:9229
# 调试端口（期间同机任意进程可在主进程执行代码），因此改为“用户明确同意后才跑”。
if [ "${WB_ALLOW_SELF_FETCH:-0}" != "1" ]; then
  echo "==> 凭证自取已被策略禁用（config/policy.env: WB_ALLOW_SELF_FETCH=0）" >&2
  echo "==> 如确需使用，请用户明确同意后手动执行：WB_ALLOW_SELF_FETCH=1 bash $0" >&2
  echo "==> 更低风险的手动方式：从浏览器复制 token，用 echo '<JSON>' | bash scripts/import_manual.sh 导入" >&2
  exit 1
fi

# Windows 下无 launchd：阶梯 1 直接就是"给用户一行 Git Bash 命令"
if [ "$IS_MAC" != "1" ] && [ "${1:-}" = "--install-launchd" ]; then
  echo "Windows 环境无 launchd，请直接把下面这一行交给用户（在 Git Bash 终端执行）："
  echo "  bash \"$SKILL_DIR/scripts/self_fetch.sh\""
  exit 0
fi

# node 定位：优先 WorkBuddy 自带托管 node（用户机器必有），其次 PATH
NODE=""
for c in "$HOME"/.workbuddy/binaries/node/versions/*/bin/node \
         "$HOME"/.workbuddy/binaries/node/versions/*/node.exe; do
  [ -x "$c" ] && NODE="$c" && break
done
[ -n "$NODE" ] || NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "==> 找不到 node（WorkBuddy 托管 node 与 PATH 都没有）" >&2; exit 1; }

run_fetch() {
  echo ">> 开始凭证自取（应用将重启一次，约 10 秒）"
  "$NODE" "$SKILL_DIR/scripts/self_fetch_key.mjs" || { echo "==> 自取失败（详见上方输出）" >&2; return 1; }
  echo ">> 完成。凭证已写入 $SKILL_DIR/config（600 权限）"
  echo ">> 验证摘要已写入 $SKILL_DIR/logs/self_fetch_result.json（无凭证值）"
  echo ">> 回到 WorkBuddy 继续对话即可；若已开新会话，Agent 会读取该结果文件接续"
}

# --dry-run：只做前置体检（不杀进程、不读凭证），用于确认路径/端口/文件是否就绪
if [ "${1:-}" = "--dry-run" ]; then
  "$NODE" "$SKILL_DIR/scripts/self_fetch_key.mjs" --dry-run
  exit $?
fi

if [ "${1:-}" = "--install-launchd" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SKILL_DIR/scripts/self_fetch.sh</string><string>--from-launchd</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  echo "已写入 $PLIST"
  echo "在终端执行这一行即可（应用会重启一次）："
  echo "  launchctl load $PLIST"
  exit 0
fi

if [ "${1:-}" = "--from-launchd" ]; then
  run_fetch
  RC=$?
  # 自清理：卸载并删除本启动脚本（launchd 任务一次性）
  launchctl unload "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  exit $RC
fi

run_fetch

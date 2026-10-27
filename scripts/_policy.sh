#!/bin/bash
# 运行策略 · 统一读取 config/policy.env（本地安全加固层，非上游文件）
# 目的：把「危险 / 消耗性动作」从默认开启改为默认关闭，需要用户显式放开才执行。
# 设计：policy.env 是纯文本 key=value，只用 sed 解析，**绝不 source / eval**，避免被当成代码执行。
# 优先级：进程环境变量 > config/policy.env > 内置默认值（便于一次性临时放开）。
# 用法：在脚本已定义 DIR 之后加一行  . "$DIR/scripts/_policy.sh"

# 定位 config 目录：不依赖调用方用了哪个变量名（DIR / SKILL_DIR / 都没有都能用）
_WB_CFG="${WB_CONFIG_DIR:-}"
if [ -z "$_WB_CFG" ]; then
  if [ -n "${DIR:-}" ]; then
    _WB_CFG="$DIR/config"
  elif [ -n "${SKILL_DIR:-}" ]; then
    _WB_CFG="$SKILL_DIR/config"
  else
    _WB_CFG="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/config"
  fi
fi
WB_POLICY_FILE="$_WB_CFG/policy.env"

# 沙盒 / 首次安装没有 config/policy.env（config 目录不进包，里面有凭证）：
# 回退到随包发布的 scripts/default-policy.env，保证云端回写资料库等开关取到正确默认值。
if [ ! -f "$WB_POLICY_FILE" ]; then
  _WB_POLICY_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -n "$_WB_POLICY_SELF_DIR" ] && [ -f "$_WB_POLICY_SELF_DIR/default-policy.env" ] \
    && WB_POLICY_FILE="$_WB_POLICY_SELF_DIR/default-policy.env"
fi

_polget() {
  [ -f "$WB_POLICY_FILE" ] || return 1
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$WB_POLICY_FILE" 2>/dev/null \
    | tail -n1 | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# 已从代码中永久删除、不再有任何开关的能力：
#   · 连续天数奖励自动兑换（checkin_rewards.sh 已无 redeem 请求与 payload 构造）
#   · skill 本体自动更新 / 自动重装（全项目无联网安装代码）
# 因此下面不再读取 WB_ALLOW_REDEEM / WB_ALLOW_SKILL_AUTOUPDATE。

# 1) 凭证在线续期（纯接口调用，不碰客户端进程）——日签必需，默认开启
WB_ALLOW_AUTO_REFRESH="${WB_ALLOW_AUTO_REFRESH:-$(_polget WB_ALLOW_AUTO_REFRESH)}"
WB_ALLOW_AUTO_REFRESH="${WB_ALLOW_AUTO_REFRESH:-1}"

# 2) 凭证自取（强制重启 WorkBuddy + 开放本机 9229 调试口）——默认关闭
WB_ALLOW_SELF_FETCH="${WB_ALLOW_SELF_FETCH:-$(_polget WB_ALLOW_SELF_FETCH)}"
WB_ALLOW_SELF_FETCH="${WB_ALLOW_SELF_FETCH:-0}"

# 3) 凭证上传资料库（凭证离开本机）——默认关闭
WB_ALLOW_UPLOAD_CREDS="${WB_ALLOW_UPLOAD_CREDS:-$(_polget WB_ALLOW_UPLOAD_CREDS)}"
WB_ALLOW_UPLOAD_CREDS="${WB_ALLOW_UPLOAD_CREDS:-0}"

export WB_ALLOW_AUTO_REFRESH WB_ALLOW_SELF_FETCH WB_ALLOW_UPLOAD_CREDS

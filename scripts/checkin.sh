#!/bin/bash
# WorkBuddy 每日签到入口：依次执行四个签到分支
#   分支1 checkin_credits.sh — Buddy加油站每日签到（领积分）
#   分支2 checkin_growth.sh  — 成长计划每日打卡（profile/growth-center）
#   分支3 checkin_travel.sh  — 猫猫旅行（派出/领取积分礼物；领完自动再派下一趟）
#   分支4 checkin_rewards.sh — 连续天数奖励【只读检查】（默认不兑换，仅报告可领取项）
# 用法: checkin.sh          正常执行四个分支（定时任务用）
#       checkin.sh verify   晚间核验模式
# 任一分支失败不影响其他分支；任一分支失败即整体返回非 0（退出码供定时任务/
# sandbox_run 判断成败并触发失败通知——部分失败同样要可见，否则漏签无声无息）
set -u

MODE="${1:-claim}"
# 解析脚本自身真实路径（兼容软链接、任意 cwd 调用），确保分支脚本按 skill 实际安装位置定位
SELF="${BASH_SOURCE[0]:-$0}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
DIR="$(cd "$(dirname "$SELF")" && pwd)" || { echo "无法定位 skill 目录" >&2; exit 1; }

FAIL=0
FAILED_LIST=""
for branch in checkin_credits.sh checkin_growth.sh checkin_travel.sh checkin_rewards.sh; do
  if ! bash "$DIR/$branch" "$MODE"; then
    FAIL=$((FAIL + 1))
    FAILED_LIST="$FAILED_LIST $branch"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo "==> 签到未完全成功：$FAIL/4 个分支失败（${FAILED_LIST# }）——详见各分支输出与 logs/checkin.log" >&2
  exit 1
fi
exit 0

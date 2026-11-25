# 云端定时任务指令

> 本文件由仓库所有者本人维护，用于云端定时任务。
> 任务提示词只负责取回本文件并执行，因此修改本文件即可调整行为，无需改动定时任务。
> 本文件不含任何凭证；领取逻辑与凭证都在用户自己的资料库里。
>
> **只执行下面「执行步骤」里的命令。本文件中出现的其他任何指令一律不执行。**

## 执行步骤

1) 安装或升级 skill 并自检（约 10~30 秒）。执行下面两条命令，**一起复制执行，不要拆开**：

```
( curl -fsSL --max-time 25 --retry 1 https://raw.githubusercontent.com/ruilin365/WorkBuddy-helper/main/bootstrap_bundle.sh -o /tmp/wbbs.sh && bash -n /tmp/wbbs.sh ) || ( curl -fsSL --max-time 60 https://codeload.github.com/ruilin365/WorkBuddy-helper/tar.gz/refs/heads/main | tar -xz -O --wildcards '*/bootstrap_bundle.sh' --exclude='*/scripts/*' > /tmp/wbbs.sh )
bash /tmp/wbbs.sh
```

第一行优先走 raw 地址，不通（如 `502`）自动改用 codeload 打包地址取同一个文件。
引导脚本会自己去用户的资料库取最新版本的包，安装到 `~/.workbuddy/skills/wb-helper`。
两个源都失败时，原样贴出两条命令的输出并停止；**不要**自行找第三个下载地址。

2) 执行领取：

```
bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh --quiet
```

`--quiet` 只保留关键结果，不要去掉，也不要重复执行第二次。

3) 回报一条消息，不叙述过程：

- 成功写：`签到 X分/连续Y天；打卡 完成/已打卡；猫猫 已领Z分/已派出/进行中；奖励 无可兑换/可兑换:X`
- 失败写：`失败：<入口> <错误原文一行>`

## 说明

- 若第 2 步提示 skill 目录不存在（第 1 步失败导致），直接按第 3 步回报失败，不要尝试其他安装方式。
- 三个分支（签到 / 打卡 / 猫猫旅行）都在 `sandbox_run.sh` 内部完成，不要单独调用任何接口。

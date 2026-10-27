# 部署与复现手册

从零到「云端每天自动领取」，任意一台装了 WorkBuddy 桌面端的电脑都适用。
命令按 **Windows + Git Bash** 写；macOS 只需把路径换成 `~/.workbuddy/skills`（脚本本身跨平台）。

仓库：`https://github.com/ruilin365/WorkBuddy-helper`（分支 `main`）
若你的仓库名或分支不同，下文所有 URL 相应替换即可。

---

## 零、前置条件

| 项 | 要求 | 说明 |
|---|---|---|
| WorkBuddy 桌面端 | 已安装并**已登录** | 凭证从这里来。登录态失效就没法取证 |
| Git + Git Bash | Windows 必装 | 脚本是 bash，`cmd`/PowerShell 跑不了 |
| node | 不用装 | 自动探测 WorkBuddy 托管的 node（`~/.workbuddy/binaries/node/`），找不到才用 PATH |
| 资料库 | 同账号的「我的资料」可用 | 凭证与 skill 包的跨实例中转站 |
| 云端工作 | 可用 | 定时任务跑在这里 |

---

## 一、把仓库装到本机 skill 目录

```bash
git clone https://github.com/ruilin365/WorkBuddy-helper.git
mkdir -p ~/.workbuddy/skills
cp -r WorkBuddy-helper ~/.workbuddy/skills/wb-helper
bash ~/.workbuddy/skills/wb-helper/scripts/check_integrity.sh
```

`check_integrity.sh` 逐行输出 `<脚本名>: OK`，末尾「汇总: ...」。**全部 OK 才继续**，有 `MISSING` 说明复制不全，重做本步。

> 目标目录已存在旧版本时，先 `rm -rf ~/.workbuddy/skills/wb-helper` 再复制。
> 注意别顺手删掉里面的 `config/`——里面有凭证和运行策略。

---

## 二、本机取凭证

### 2.1 先查能不能直接复用

```bash
cd ~/.workbuddy/skills/wb-helper
bash scripts/check_local_creds.sh
```

- **exit 0** → 已有可用凭证（临期会自动续期），**跳到第三章**
- **exit 1** → 继续 2.2

### 2.2 自动取证（推荐）

```bash
bash scripts/self_fetch.sh --dry-run      # 体检：应用在跑？主程序可定位？9229 端口空闲？
WB_ALLOW_SELF_FETCH=1 bash scripts/self_fetch.sh
```

**执行前先保存所有未保存的编辑**——它会关闭并自动重开 WorkBuddy，约 10~20 秒。
原理是通过 `--inspect` 调试口向应用自身要加密密钥，解开本机已登录的凭证；密钥只在内存，不落盘、不发网。

跑完看结果：

```bash
cat logs/self_fetch_result.json     # 只含 ok/stage/time/token_exp，无凭证值
bash scripts/check_local_creds.sh    # 应 exit 0
```

### 2.3 手动取证（兜底，不重启应用）

浏览器登录 `www.workbuddy.cn` → F12 → Network → 找登录/刷新响应 → 复制整段 JSON：

```bash
echo '<粘贴整段JSON>' | bash scripts/import_manual.sh
```

脚本会递归搜 `accessToken`/`refreshToken`/`uid`，兼容三种响应形态，自动推导缺失的 uid。

---

## 三、打包并上传到资料库

```bash
bash scripts/make_cred_file.sh     # 生成凭证文件（权限 600）
bash scripts/pack_bundle.sh        # 打出 skill 包
ls -l dist/
```

`dist/` 下会得到（`<版本>` 自动取自 `_meta.json`）：

| 文件 | 用途 |
|---|---|
| `wb-helper-local-bundle-v<版本>.txt` | **skill 本体**，云端解包安装 |
| `wb-helper-local-bundle-v<版本>.txt.sha256` | 人工核对用 |
| `wb-helper-local-bootstrap-v<版本>.txt` | 引导脚本副本，云端 skill 已存在时可自升级 |

把下面 **3 个文件**上传到资料库「我的资料」**个人空间根目录**：

1. `config/重要凭证，切勿分享和发给别人！！！sandbox-creds-WB2.txt`
2. `dist/wb-helper-local-bundle-v<版本>.txt`
3. `dist/wb-helper-local-bootstrap-v<版本>.txt`

上传硬约束：

- **必须当文件原样上传**（`.txt`）。传成在线文档/页面形式的，云端下载不回来。
- **文件名必须保留原样**，尤其版本号。云端按「基础标识匹配 + 版本号最大者优先」挑文件：
  标识分别是 `wb-helper-local-bundle`、`wb-helper-local-bootstrap`、`sandbox-creds-WB2`。
- **资料库不支持覆盖，同名上传会新建节点**，且没有删除 API。所以每次更新都换更大的版本号，
  历史节点留着不理它，不影响取新版。

---

## 四、云端创建定时任务

在「云端工作」里把下面整段发给云端 Agent（**不要新建多个任务，两个时间用同一份提示词**）：

```
请创建两个定时任务，时间分别是每天 05:00 和 13:00，两个任务的提示词相同，均为：
为我本人这一个账号执行 WorkBuddy 每日领取，只领不兑换。严格按下面三步做，做完回报一次，
不要自行探索接口、不要通读任何文档、不要重复执行。

1) 执行这一条（安装或升级 skill 并自检，约 10~20 秒）：
   curl -fsSL https://raw.githubusercontent.com/ruilin365/WorkBuddy-helper/main/bootstrap_bundle.sh -o /tmp/wbbs.sh && bash /tmp/wbbs.sh
   它自己去我的资料库里取最新版本的包安装到 ~/.workbuddy/skills/wb-helper。
   若报错（包括 curl 拿不到文件），原样贴出错误并停止；不要自行找替代下载路径、不要从其他地址安装。

2) 执行 bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh --quiet
   （--quiet 只保留关键结果；不要去掉它，也不要跑第二次。）

3) 回报一条消息，不叙述过程：
   成功写「签到 X分/连续Y天；打卡 完成/已打卡；猫猫 已领Z分/已派出/进行中；奖励 无可兑换/可兑换:X」
   失败写「失败：<入口> <错误原文一行>」

硬约束：禁止调用任何兑换、抽奖、补签接口，不消耗积分与能量；即使检测到连续 7/14/28 天奖励可兑换，
也只输出「可兑换：X」交我手动领取。
```

**为什么两个时间**：猫猫旅行是「派出 → 1~4 小时回家 → 领取」两段动作。05:00 派出，13:00 早到家可领完再派；
13:00 派的这趟次日 05:00 领。间隔 8 小时远大于单趟 4 小时上限。想多跑几趟就加触发点，间隔 ≥4 小时。

**首次验证**：建完任务别等 05:00，直接在云端会话里发一句
「执行 bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh --quiet」，看回报是否正常。

---

## 五、日常维护

**什么都不用做。** 凭证的 refresh token 约 60 天窗口，云端续期后会自动回写资料库（`push_creds_to_library.sh`），
滚动续期。只有下面情况才需要回本机重新取证上传：

- 回报里出现 `401` / `invalid_grant` / `Session doesn't have required client`
- 云端日志提示「会话已被服务端销毁，须回本机重取」

处置：回本机 → 第二章重新取证 → 第三章重传凭证文件（`sandbox-creds-WB2` 文件名不用带版本号，
上传后云端取最新节点）。

---

## 六、版本升级

```bash
# 1. 改脚本，并同时抬两处版本号，保持一致
#    _meta.json 的 version  与  SKILL.md frontmatter 的 version
#    约定抬 x.y（1.8.4 → 1.9.0），不要只加 -local.N 后段

# 2. 同步根目录引导脚本（云端 curl 的就是它）
cp scripts/bootstrap_bundle.sh ./bootstrap_bundle.sh

# 3. 打包
bash scripts/pack_bundle.sh

# 4. 上传 dist/ 下新的 bundle 与 bootstrap（文件名带新版本号）
# 5. 提交仓库 + 更新本机 skill 目录
git commit -am "bump to <新版本>"
git push
cp -r . ~/.workbuddy/skills/wb-helper/     # 或反向：以仓库为准覆盖本机
```

云端**不需要改提示词**：bootstrap 每次运行都按版本号取资料库里最大的那份。
旧版本节点留在资料库里不会被选中（文件名里的版本号参与排序）。

---

## 七、故障排查

| 现象 | 位置 | 原因与处置 |
|---|---|---|
| `curl: (22) 404` | 云端第 1 步 | 仓库是私有的，或分支不是 `main`，或文件不在根目录。raw 只能读公开仓库 |
| `==> 资料库中未找到标题含「wb-helper-local-bundle」的文件` | 云端 bootstrap | 包没上传到**个人空间根目录**，或文件名被改掉了标识 |
| `==> 资料库技能缺少 space_api.py` | 云端 bootstrap | 报错里会打印 `library/` 目录内容，说明平台预置的资料库技能布局变了，把清单发给维护者 |
| `401` / 网关 HTML 拦截页 | 云端运行 | 凭证失效（会话被服务端销毁）。回本机重新取证上传 |
| `invalid_grant: Session doesn't have required client` | 云端续期 | 同上，refresh_token 也废了，只能重新取证 |
| `Invalid count value: -2` | 云端运行 | 已修复（base64 补位负数取模），出现说明装到了旧包，检查资料库版本号 |
| 只领了积分没接着派猫 | 云端运行 | 已修复（状态机循环推进到 traveling），同上 |
| 回报只有 `Exit code 0` 没内容 | 云端运行 | 已修复（多余括号导致 main 未执行），同上 |
| `library search failed` | 云端 | MCP 检索工具故障。本方案**不用 search**（走 `list-nodes`），不影响 |

排查时去掉 `--quiet` 跑一次，能看全流程；日志固定在 `~/.workbuddy/skills/wb-helper/logs/sandbox_run.log`。

---

## 八、仓库的敏感边界

**入库的**：脚本、文档、包清单、版本信息。全部可公开。
**不入库的**（`.gitignore` 已挡）：`config/`（token / refresh_token / user_id / 凭证文件）、`logs/`、`dist/`。

上传前自检：

```bash
git status --ignored --short | head
git ls-files | grep -iE "config|token|cred|log" || echo "clean"
```

`config/` 若曾被误提交，必须视为凭证泄露：回本机重新取证（旧 refresh_token 视作作废），并清理 git 历史。

---

## 九、卸载

```bash
# 本机
rm -rf ~/.workbuddy/skills/wb-helper
# 云端：在工作里删掉那两个定时任务
# 资料库：手动删除三个节点（凭证 / bundle / bootstrap）
```

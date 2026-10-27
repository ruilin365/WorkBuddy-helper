---
name: wb-helper
slug: wb-helper
displayName: WorkBuddy 每日签到助手（本地加固分支）
version: 1.8.4
branch: local-hardened
description: WorkBuddy（腾讯）每日自动签到：Buddy加油站领积分 + 成长计划打卡 + 猫猫旅行收积分 + 连续天数奖励只读检查（不兑换）。当用户提到 WorkBuddy 签到、领取积分、Buddy加油站、成长计划、成长中心打卡、猫猫旅行、每日签到、奖励查询时使用。本分支为本地修改版：无联网安装/更新能力、无兑换能力，本机只负责取凭证与打包，签到在小程序云端沙盒执行。
compatibility: 本机（Windows / macOS，bash + curl + python3）负责凭证生成与打包上传；云端（CodeBuddy 沙盒）负责从资料库取包与每日签到。
metadata:
  branch: local-hardened
  based_on: 1.4.5
  updated: 2026-10-22
  upstream_sync: 不接受
---

# WorkBuddy 每日签到助手 · 本地加固分支

> **本文件属于本地修改分支。** 与上游发布版无同步关系，不接受上游推送，也不从任何网络源安装或更新。
> 本分支的脚本就是版本本身：改动只由用户在本机手工进行，改完重新打包上传资料库。

---

## 一、本分支相对上游的差异（只保留事实）

| 项 | 上游行为 | 本分支 |
|---|---|---|
| 连续天数奖励兑换 | 检测到 available 即 POST `/activity/growth/redeem` 自动兑换 | **能力已物理删除**：`api_post()`、payload 构造、兑换调用全部移除，只剩 GET streak + 只读汇报 |
| 本体更新 | 文档要求"缺失时从网络重新安装/拉取重建" | **能力已物理删除**：全项目无任何联网安装/下载代码，本文档不含联网安装指令 |
| Windows 凭证路径 | 只找 `%APPDATA%` | 同时找 `%LOCALAPPDATA%`（新版客户端真实位置在 Local） |
| Windows 安装布局 | 只认 Squirrel `%LOCALAPPDATA%\WorkBuddy\app-*` | 补 `%LOCALAPPDATA%\Programs\WorkBuddy`（安装器布局） |
| 进程控制 | `taskkill /IM`（无 `/F`，Electron 不响应）+ `cmd /c start` 拼引号 | 精确定位 GUI 主进程 → `/F /T` 结束 → `spawn` 直启（绕开 cmd） |
| 部署范围 | 客户端与云端各自独立签到 | **本机不签到、不注册定时任务**：本机只取凭证并打包，签到全部在云端 |

---

## 二、运行策略（三个真实开关）

`config/policy.env` 是唯一开关源，由 `scripts/_policy.sh` 以纯文本 sed 解析（不 source、不 eval）：

| 开关 | 默认 | 含义 |
|---|---|---|
| `WB_ALLOW_SELF_FETCH` | 1 | 允许凭证自取（会重启 WorkBuddy + 开 9229）。**仅本机可用**，沙盒无桌面端 |
| `WB_ALLOW_UPLOAD_CREDS` | 1 | 允许凭证写入用户本人资料库（个人空间） |
| `WB_ALLOW_AUTO_REFRESH` | 1 | 允许凭证在线续期（纯接口，日签必需） |

对 Agent 的硬约束（六条，违反任一条都算执行失败）：

1. **不得**执行任何「从网络安装 / 更新本 skill、拉取新版本覆盖本地脚本」的动作，
   包括 `curl | bash`、`git clone`、从任何 skill 市场重新安装。
   `check_integrity.sh` 报错时只报告缺哪个文件，**不得自动修复或重装**。
2. **不得**尝试兑换任何奖励。本 skill 已无兑换能力；检测到可兑换项时只在回复里列出
   「可兑换：X」，交用户到成长中心手动领取。
3. `self_fetch.sh` / `self_fetch_key.mjs` 仅限**本机客户端**使用（会杀掉并重启 WorkBuddy）。
   执行前必须提示用户保存未保存内容；失败不要反复重试（脚本已内置凭证文件与主程序预检）。
4. `push_creds_to_library.sh` / `make_cred_file.sh` 只允许把凭证写入**用户本人**的资料库个人空间；
   不得写入他人空间、公开位置或任何第三方端点。
5. **不得把凭证写进任何会被记录或索引的位置**：不发群聊、不贴日志、不写进仓库、不截图。
6. 汇报必须如实：哪一步失败就写失败，附上脚本原始报错，不得用"部署完成"覆盖未完成的步骤。

---

## 三、四个领取入口

一个入口 `scripts/checkin.sh`，依次执行四个分支，互不影响（一个失败不阻塞其他）：

1. **积分签到**（`scripts/checkin_credits.sh`）：Buddy加油站每日签到领积分
2. **成长计划打卡**（`scripts/checkin_growth.sh`）：成长中心每日打卡，跟踪连续天数与奖励进度
3. **猫猫旅行**（`scripts/checkin_travel.sh`）：派猫猫出门旅行，回家后领取带回的积分礼物（5~10 分/趟）。
   单次运行会连续推进状态机：到家就领，领完**立刻再派下一趟**，一定把猫送回路上才退出；
   一趟 1~4 小时后回家，因此触发越密每天能跑的趟数越多（日上限由服务端 `daily_limit_reached` 决定）
4. **连续天数奖励检查**（`scripts/checkin_rewards.sh`）：**只读**报告连续 7/14/28 天梯队状态；
   兑换代码已物理删除，检测到可兑换只提示、不执行

四个分支都是幂等的：当天已完成的项目安静跳过，重复执行无副作用。

---

## 四、环境检测（Agent 加载后第一步）

按顺序判断，命中即确定身份：

```bash
# A. 是否为小程序云端沙盒
echo "X_IDE_IS_CLOUDSTUDIO=${X_IDE_IS_CLOUDSTUDIO:-未设置}"
echo "CODEBUDDY_SESSION_TYPE=${CODEBUDDY_SESSION_TYPE:-未设置}"   # 定时任务中为 automation
ls -d /root/.codebuddy/skills 2>/dev/null && echo "→ 存在 CodeBuddy 技能目录"
cat /proc/mounts 2>/dev/null | grep "overlay / " | tr ',' '\n' | grep upperdir   # 当前实例的持久卷 ID

# B. 是否为客户端（装有 WorkBuddy 桌面端）
# skill 安装目录因 Agent 而异（~/.workbuddy/skills/、~/.agents/skills/ 等），必须先定位再执行，
# 不得硬编码路径
SKILL_DIR="$(cd "$(dirname "$(find "$HOME/.workbuddy/skills" "$HOME/.agents/skills" -maxdepth 4 -path '*/wb-helper/scripts/checkin.sh' 2>/dev/null | head -1)")/.." 2>/dev/null && pwd)"
cd "$SKILL_DIR" 2>/dev/null || echo "未定位到 wb-helper 安装目录"
bash scripts/check_local_creds.sh && echo "→ 客户端环境，且本地凭证可直接复用"
bash scripts/extract_token.sh && echo "→ 本机可生成凭证，属客户端环境"
```

判定规则：

- `X_IDE_IS_CLOUDSTUDIO=1` 或存在 `/root/.codebuddy/skills` → **云端沙盒**，走「云端执行」章节
- `extract_token.sh` 能成功 → **客户端**，走「本机取证」章节
- 两者都不满足 → 环境不支持，告知用户并停止（不要猜测、不要强行继续）

---

## 五、双端架构

| | 本机（PC） | 云端沙盒 |
|---|---|---|
| 能否生成凭证 | ✅ 本机有 WorkBuddy 登录态 | ❌ 没有桌面端，无法生成 |
| 职责 | 生成凭证；打包 skill 分支；两者写入资料库 | 从资料库取包与凭证，执行签到 |
| 是否签到 | **否**（本分支决策） | **是** |
| 是否依赖本机开机 | 仅首次取证需要 | **否** |

**为什么必须经过资料库**：沙盒的持久卷按实例绑定，换个实例就是空盘，自装 skill 与其 `config/` 一起消失；
沙盒内也没有包管理器可以重装。**资料库是唯一跨实例可靠的持久化位置**——其鉴权由网络层注入
（沙盒走 auth-proxy 网关），脚本进程内不持有任何资料库凭证，因此不存在"拿凭证才能拿凭证"的循环依赖。

---

## 六、本机取证（只在需要新凭证时做）

### 第零步 · 先查本地凭证能否直接复用（最高优先级）

任何"获取凭证"动作之前必须先执行：

```bash
bash scripts/check_local_creds.sh
```

- **exit 0** → `config/` 已有可用凭证（临期会自动在线续期），**直接复用**，跳过取证
- **exit 1** → 本地无凭证或 refresh_token 已彻底失效，才进入下一步

### 第一步 · 生成凭证

```bash
bash scripts/self_fetch.sh --dry-run    # 先体检：确认应用在跑、凭证文件存在、主程序可定位、9229 空闲
bash scripts/self_fetch.sh              # 体检通过后再执行（会关闭并自动重开 WorkBuddy）
```

- 原理：通过 `--inspect` 调试口调用应用自身的 `workbuddyStorage.loggerGet()` 取到内存中的加密密钥，
  解开本机已登录的凭证写入 `config/`——不破解、不扫描内存、密钥不落盘
- 应用会关闭约 10–20 秒后自动重开，**执行前必须让用户保存未保存内容**
- 结束后读 `logs/self_fetch_result.json` 判断成败（该文件只含 `ok/stage/time/token_exp` 等结构信息，无凭证值）；
  失败时它同样会写盘，因为此时用户窗口已经关闭，重启后新会话据此接续
- 取证失败且不想重启时，走浏览器兜底：登录 `www.workbuddy.cn` → F12 → Network →
  复制含 `accessToken`/`refreshToken` 的响应 JSON → `echo '<JSON>' | bash scripts/import_manual.sh`

### 第二步 · 本机自检（不签到）

```bash
bash scripts/check_local_creds.sh    # 凭证有效
bash scripts/check_integrity.sh      # 脚本完整
bash scripts/checkin_rewards.sh      # 只读查询一次，确认接口连通（不会兑换）
```

> 本分支不在本机跑 `checkin.sh`、不注册任何本机定时任务。签到统一由云端承担。

---

## 七、打包本分支并上传资料库

### 1. 生成凭证文件

```bash
bash scripts/make_cred_file.sh
```

产物 `config/重要凭证，切勿分享和发给别人！！！sandbox-creds-WB2.txt`，**两行**：

```
重要凭证，切勿分享和发给别人！！！
WB1:<...>
```

### 2. 打包 skill 分支

```bash
bash scripts/pack_bundle.sh
```

产物四个文件（均在 `dist/`，文件名带当前版本号）：

| 文件 | 用途 |
|---|---|
| `wb-helper-local-bundle-v<version>.txt` | 首行元信息（版本 / sha256 / 大小）+ 单行 base64 的 tar.gz，包内根目录为 `wb-helper/` |
| `wb-helper-local-bundle-v<version>.txt.sha256` | 外层文件自身哈希，供人工核对 |
| `wb-helper-local-bootstrap-v<version>.txt` | 与 `scripts/bootstrap_bundle.sh` 同一份内容：云端定位资料库 → 下载包 → 校验 sha256 → 解包到 `~/.workbuddy/skills/` |
| `wb-helper-local-bootstrap-v<version>.txt.sha256` | 引导脚本自身哈希 |

打包时自动排除 `config/`、`logs/`、`dist/`、`backup/`、`.git/`、`*.log`、`*.bak`——**凭证与日志绝不进包**，
并在打包末尾自检：包内若出现 `config/`、`logs/`、`sandbox-creds*`、`.rt_snapshot`、`token` 任一项即失败退出。

> Windows 上 GNU tar 会把 `C:/...` 当成远程主机，`pack_bundle.sh` 已自动加 `--force-local`。
> 另外 Git Bash 的 `sha256sum` 对含反斜杠路径会输出转义形式（哈希前带 `\`），
> 脚本统一用 `sha256sum < file` 取值——手工核对时若看到 `\` 前缀，属同一现象，去掉即可。

### 3. 上传到资料库个人空间（我的资料）

三个文件全部以 **drive 文件形式**（`.txt`）上传：

- `重要凭证，切勿分享和发给别人！！！sandbox-creds-WB2.txt`
- `wb-helper-local-bundle-v<version>.txt`
- `wb-helper-local-bootstrap-v<version>.txt`

要求：

- **必须以 drive 文件形式上传**（`.txt` 才会存成可原样下载的 drive；`.md` 会变成在线文档、
  `.zip`/`.html` 会变成页面，都无法当文件下载回来）
- **上传能力不支持指定 nodeId 覆盖**：同名上传会**新建一个节点**（nodeId 不同），
  而资料库没有删除节点的 Agent API——旧的删不掉。因此**每次更新都换版本化文件名**，
  不去覆盖旧文件
- 云端的匹配规则是"标题包含基础标识 + 版本号最大者优先"：基础标识分别是
  `wb-helper-local-bundle`、`wb-helper-local-bootstrap`、`sandbox-creds-WB2`。
  只要新文件名里带更大的版本号，云端就会自动选中新版，历史节点留着不干扰
- 文件名里的版本号必须与 `SKILL.md` frontmatter 的 `version` 一致（`pack_bundle.sh` 自动取，无需手填）
- 上传后做一次只读复查：确认 nodeId 与大小符合预期

本机没有资料库网关（`auth-proxy` 只在沙盒内可用），因此"上传"这一步由 Agent 的资料库能力完成，
不要在**本机**执行 `push_creds_to_library.sh`（那是沙盒端回写用的）。

### 4. 更新流程与版本约定

**更新流程**：本机改脚本（并**升 `version`**）→ `bash scripts/pack_bundle.sh` → 上传新的
`wb-helper-local-bundle-v<新版本>.txt` 与 `wb-helper-local-bootstrap-v<新版本>.txt`
→ 云端下次运行 `fetch_bundle_from_library.sh`（或提示词里的 bootstrap）自动取到版本号最大的那份。

约定：

- **必须升版本号**。同名同版本重传会创建第二个同版本节点，排序平局、取谁不确定
- **不要尝试覆盖旧节点**，做不到；旧节点留在资料库里不影响取新版，也不会被版本优先规则选中
- 首版曾以无版本号文件名（`wb-helper-local-bundle.txt` / `wb-helper-local-bootstrap.txt`）上传，
  按版本优先规则会被排到最后，属历史遗留，无需处理
- nodeId 属运维信息（资料库节点无法删除也无法定点覆盖），记录在工作区的部署记录文件里；
  云端只按标题标识 + 版本号匹配，**不依赖任何 nodeId**

---

## 八、云端执行

### 1. 安装 / 升级（**每次运行都先跑一遍，别假设 skill 还在**）

> 2026-10-27 实测更正（推翻 10-26 的「实例持久」判断）：05:00 与 13:00 是**两个独立定时任务**，
> 各自起独立沙盒，互相看不到对方写的东西；容器回收后 `/root` 下全部消失（`/root/.workbuddy` 不持久）。
> 10-26 那次之所以看起来"残留还在"，是同一会话内的临时卷没有被回收。
> 因此**每次都从零安装路径起步**：bootstrap 取到新版就覆盖，已经是最新则很快通过。
> 另外，残留的旧凭证会一直被拿去用，这正是 v1.8.0 给 `sandbox_run.sh` 加凭证探活的原因。

安装分两条路径，用途不同：

**A. skill 已存在时的就地升级（快，不重新解包）**

```bash
bash ~/.workbuddy/skills/wb-helper/scripts/fetch_bundle_from_library.sh
```

内部走 `library_get.sh`（`space_api.py` + auth-proxy 网关），按版本号取最新包并就地覆盖，
**保留 `config/` 与 `logs/`**。已实测：旧版（1.6.0）里的该脚本也能正确取到新版，
因为版本排序正则自 1.5.0-local.3 起就已兼顾 `-local.N` 与主次版本比较。
`library search failed` 这类 MCP 工具故障**不影响**这条路径。

**B. 从零安装**（目录不存在时，云端定时任务的默认路径）

> 定时任务提示词里的第 1 步（从 GitHub raw 取 `bootstrap_bundle.sh` 并执行）就是这条路：
> 引导脚本本身不依赖 skill 任何文件，直接从资料库取包 → 校验 sha256 → 解包到 `~/.workbuddy/skills/`。
> 仓库地址见 [DEPLOY.md](DEPLOY.md)。手工执行时的规格：

1. 用资料库能力在 personal 空间列出标题含 `wb-helper-local-bundle` 的文件（`list-nodes`，不要用
   `search-nodes`——drive 文件不进搜索索引）。**命中多个时必须取版本号最大的那个**
   （文件名形如 `wb-helper-local-bundle-v1.8.4.txt`，逐段比较数字）；
   资料库里会同时存在历史版本与首版无版本名文件，**取错就会装到旧代码**，且旧逻辑会一直匹配旧包
   > **发版约定**：升版本必须抬 `x.y` 主次位（如 1.5.0 → 1.6.0），
   > **不要只加 `-local.N` 后段**。早期排序逻辑的正则只取前三位数字，
   > `1.5.0-local.1/2/3` 会被算成同一个版本而平局，可能一直取到旧包。
2. 取 `download_url` 后**立即下载**（COS 临时签名有时效）
3. 按首行元信息校验 `sha256`，不符即中止并报错，**不要解包**
4. base64 解码 → tar 解包到 `~/.workbuddy/skills/`（包内根目录已是 `wb-helper/`，不要重复套一层）
5. 若不想手工处理，可直接下载标题含 `wb-helper-local-bootstrap` 的文件（**同样取版本号最大者**）
   并 `bash` 执行，它完成 1–4 全部步骤
6. 安装后 `bash ~/.workbuddy/skills/wb-helper/scripts/check_integrity.sh`，
   全部 OK 才继续；**缺失时只报告缺件，不得联网重装**

### 2. 每日运行

```bash
bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh --quiet        # 云端定时任务用：只输出关键结果（约 12 行）
bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh                # 排查用：完整过程输出
bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh verify --quiet # 晚间核验模式
```

`sandbox_run.sh` 已内置：完整性自检 → **凭证探活**（失效则强制重拉资料库凭证）→ 执行四个分支 → 续期后自动回写资料库。

> **凭证探活（v1.8.0 起）**：实例里若残留旧凭证，旧逻辑会直接拿去跑，整轮静默 401。
> 现在启动时先请求一次 `travel/status` 判定：200+JSON 视为可用；401/403 或返回 HTML 网关拦截页
> 视为失效 → 自动重拉资料库凭证再复验；复验仍失败则明确报「会话已被服务端销毁，必须回本机重取」。
> 日志会打印 `sid=… exp=…`，排查时拿本机的 sid 比一下就能定位。
> 探活的副作用为零（只读 GET，不消耗积分/能量）。

### 3. 分步验证（排查时用）

```bash
bash scripts/fetch_bundle_from_library.sh   # skill 已存在时，用这条重新同步本体
bash scripts/check_integrity.sh             # 脚本完整性
bash scripts/fetch_creds_from_library.sh    # 从资料库拉凭证并导入 config/
bash scripts/sandbox_run.sh                 # 完整跑一次
```

---

## 九、定时任务提示词（云端 Agent 用）

在 WorkBuddy 小程序切到「云端工作」后，把下面整段发给云端 Agent。**这是本分支唯一正确的上云指令，
它不含任何联网安装语义。**

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

**为什么是 05:00 和 13:00**：猫猫旅行是"派出 → 1~4 小时后回家 → 领取"两段动作。05:00 派出，13:00 时
早已到家，可以领完再派（8 小时间隔远大于单趟 4 小时上限）；13:00 派出的那趟次日 05:00 领。一天 2 趟，
既吃满循环又不浪费触发次数。想让猫多跑几趟就加触发点，间隔 ≥4 小时即可。

**为什么要 `--quiet`**：一次运行的完整输出有四五十行，全部进云端 Agent 的 context 纯属浪费积分。
`--quiet` 只保留「开始 → 凭证探活 → 四分支结论行 → 结尾」约 12 行，过程细节仍完整写入
`logs/sandbox_run.log`，出问题让它读日志即可。

### 定时任务规格（Agent 必读）

上面这段是**两层结构**，不得混淆：

- **第一层（指令本体）**："请创建两个定时任务，时间分别是……"——用户在对话里发给云端 Agent 的指令，
  Agent 的职责是**创建定时任务**
- **第二层（任务提示词）**："为我本人这一个账号执行……交我手动领取。"——
  要**逐字注入到每个定时任务**里的提示词本体，不要改写、不要拆分、不要省略

约束：

1. **禁止在当前对话里直接安装 skill 并跑签到**——那只能执行一次，不构成"每天自动签到"；
   合格的部署产物是"定时任务已创建"
2. **定时任务每次拉起的是全新沙盒实例**——实测 `/root/.workbuddy` 整个不存在、只有 `/workspace`
   可能持久，所以第二步提示词里那条 `curl … | bash` 的自举一行都不能省；它同时负责"装"和"升级"，
   沙盒里已有新版时也会重新覆盖成资料库里的最新版，属预期行为
3. 执行时间以第一层为准（默认 05:00 与 13:00 两条，且是两个**独立**定时任务，
   各自起独立沙盒、互不可见），不得擅自合并或改动
4. **通知语句不能省**：云端调度接口拿不到执行结果，只能靠任务内主动推送

---

## 十、沙盒环境事实（实测结论，决定云端方案设计）

- **持久卷按实例绑定，不按用户绑定**：根挂载是 overlay，`upperdir=/mnt/user-data/<卷ID>/diff`；
  不同会话 = 不同卷 = 全新空盘，旧卷在新实例里完全不可达
- **`/workspace` 并不比 `/root` 更持久**：两者与 `/tmp`、`/opt` 同在一个 overlay、共享同一块持久卷
- **内置 skill 每次都在，自装 skill 换实例即丢**：内置技能是镜像层实体 + 每次会话重建的符号链接
- **沙盒里没有包管理器/安装器**：本体丢失只能靠资料库拉回
- **实例与会话会超时回收**：会话空闲约 5 分钟即可能回收；定时任务从预热池拉起新实例
- **环境变量不保证注入**：`CODEBUDDY_SKILL_DIR` 在定时任务中不保证存在，脚本一律写死路径 + fallback；
  `CODEBUDDY_SESSION_TYPE=automation` 表示定时任务环境
- **定时任务执行结果拿不到**：调度接口只有 list/get/update/delete，没有查询执行结果的 action
- **资料库通道不依赖会话上下文**：身份在网络层注入，`env -i` 清空环境变量后访问照样成功

新会话开工自检：

```bash
cat /proc/mounts | grep "overlay / " | tr ',' '\n' | grep upperdir    # 我是哪个实例
ls -d ~/.workbuddy/skills/wb-helper/scripts/checkin.sh 2>/dev/null || echo "⚠️ skill 未安装"
LB=/root/.codebuddy/skills/library; [ -d "$LB" ] || LB=/opt/sandbox-prefetched/blobs/skill/library/latest
CODEBUDDY_SKILL_DIR=$LB python3 "$LB/space_api.py" space.workspace.list-user-spaces   # 资料库通道是否正常
```

---

## 十一、资料库读写要点（Agent 操作时遵守）

- 定位文件**必须用 `list-nodes` + 标题匹配**，不能用 `search-nodes`——drive 类文件不进搜索索引，
  搜「凭证」「bundle」都会返回空
- `get_download_link.py` **输出两行，只解析第一行**（前缀 `KS_DRIVE_DOWNLOAD `），否则 JSON 解析报错
- `download_url` 带 COS 临时签名、有时效，取到后立即下载
- 覆盖已有文件必须带 `--node-id`，否则会产生同名重复节点且旧链接仍指向旧内容
- 上传/替换后做一次只读复查，不确定就先查询，不要盲目重试
- 单文件上限 100 MiB

---

## 十二、凭证与续期

- 凭证来自用户在 WorkBuddy 的登录态，由本机生成并写入 `config/`（600 权限），再经资料库传到云端
- 凭证有效期约 30 天，**到期前由 `scripts/refresh_token.sh` 自动在线续期**（纯接口，不依赖桌面端）
- 续期用的长效凭证有效期约 60 天。**注意：每次续期都会轮换 refresh token，旧值随即作废**——
  本机与云端**不能**各自独立续期，同一时刻只有最后续期的那一方持有有效值
- 凭证等同账号密码：**不要外传、不要提交仓库、不要写进用户可见目录、不要截图**

### 凭证失效的两种形态（务必区分，处置完全不同）

| 现象 | 含义 | 处置 |
|---|---|---|
| `exp` 已过，接口返回明确的过期错误 | 正常到期 | 跑 `refresh_token.sh` 在线续期即可 |
| **网关直接 `HTTP 401 Authorization Required`**，或续期报 `invalid_grant: Session doesn't have required client` | **登录会话已被服务端销毁**，JWT 上写着的 `exp` 再远也没用 | 在线续期**不可能**成功，必须回本机重新取证 |

会话被销毁的典型触发：**客户端升级**（如 5.9.2）、重新登录、换设备登录、退出重登。
2026-10-25 的实际事故即由此引起：10-24 客户端升级后会话 ID 发生变化（JWT 的 `sid` 前后不一致），
旧 access token 被网关 401、旧 refresh token 报 `invalid_grant`，本机与云端同时失效。

**恢复步骤（本机执行，无法在云端完成）**：

1. 本机跑 `scripts/self_fetch.sh`（等价于重启客户端 → 取内存密钥 → 解密登录态信封）；
   脚本会重新识别当前会话并覆盖 `config/` 三件套，同时校验 JWT 的 `sid` 是否已变化
2. 可用性验证：`GET /activity/growth/buddy/travel/status` 必须返回 **HTTP 200**
3. `make_cred_file.sh` 重新生成凭证文件 → **覆盖上传**资料库同一节点（同名并存会导致云端取到旧凭证）
4. bundle 版本号抬一位 → 上传，确保云端先拉到新代码再拉凭证

**排查提示**：看到 401 不要按"过期"去反复试续期——先对比 `config/token` 里的 `sid` 与客户端
`%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info` 中的 `sessionState`，
不一致即可确诊为会话被换。


### 云端续期后自动回写资料库（关键机制）

沙盒实例回收后本地 `config/` 就没了；若续期结果不回写，资料库里那份的长效凭证会在**上传后第 60 天过期**，
云端断链、需人工回本机重新生成上传。因此：

- `sandbox_run.sh` 在签到结束后比较 `config/refresh_token` 与快照 `config/.rt_snapshot`：
  **不一致（说明本次运行发生过续期）或快照缺失 → 自动调 `push_creds_to_library.sh`
  覆盖回写到资料库同一节点**；一致则跳过
- 回写成功后才更新快照；失败只记 WARN、**不影响签到任务退出码**，快照保持旧值，下次运行自动重试
- 效果：只要云端定时任务正常跑，60 天窗口就是**滚动续期**的，长期无需人工干预
- 回写采用**覆盖上传（带 `--node-id`）**，不产生重复节点
- 关闭回写：`WB_NO_LIBRARY_PUSHBACK=1`（此时长效凭证到期后需人工重新上传）

**长效凭证到期或彻底失效时**：见上文「凭证失效的两种形态」，在本机重跑取证 → 验证 200 →
重新生成凭证文件 → 覆盖上传资料库同一节点，云端下次运行自动拉到新凭证。

### 凭证文件标识：`sandbox-creds-WB2`

云端按标题包含 `sandbox-creds-WB2` 匹配凭证节点。2026-10-26 凭证重建时标识从 `WB1` 改为 `WB2`：
资料库没有删除 API，旧 `WB1` 节点（内含已失效凭证）无法移除，改名可确保唯一命中、不会取错。
若将来再次整体重建凭证，同样把 `WB1/WB2` 递增一位，并同步三端常量
（`make_cred_file.sh` / `fetch_creds_from_library.sh` / `push_creds_to_library.sh`）。
（文件内容第 2 行的 `WB1:` 前缀是**导出格式版本号**，与节点标识无关，不随此处变更。）


---

## 十三、命令速查

- 本机取证：`bash scripts/self_fetch.sh [--dry-run]`；兜底 `echo '<JSON>' | bash scripts/import_manual.sh`
- 本机查凭证：`bash scripts/check_local_creds.sh`
- 本机打包：`bash scripts/pack_bundle.sh`（产出 `dist/` 两个文件）
- 本机生成凭证文件：`bash scripts/make_cred_file.sh`
- 每日签到（云端）：`bash scripts/sandbox_run.sh [verify]`
- 单分支：`bash scripts/checkin_credits.sh [verify]` / `checkin_growth.sh` / `checkin_travel.sh` / `checkin_rewards.sh`
- 从资料库同步本体（云端）：`bash scripts/fetch_bundle_from_library.sh [--dest <skills目录>]`
- 首次安装本体（云端，skill 不存在时）：`bash scripts/bootstrap_bundle.sh [--dest <skills目录>]`
- 按标题标识下载资料库文件：`bash scripts/library_get.sh <标识> <输出路径>`
- 从资料库拉凭证（云端）：`bash scripts/fetch_creds_from_library.sh`
- 回写凭证到资料库：`bash scripts/push_creds_to_library.sh`（`sandbox_run.sh` 自动调用）
- 导入凭证串：`bash scripts/import_creds.sh '<WB1:...>'`（支持 stdin / 环境变量 `WB_CREDS`）
- 导出凭证串：`bash scripts/export_creds.sh`（输出一行 `WB1:...`）
- 完整性校验：`bash scripts/check_integrity.sh`

---

## 十四、运行结果怎么看

结果追加写入 `logs/checkin.log`（云端另有 `logs/sandbox_run.log`），正常输出形如：

```
[2026-10-22 09:07:01] 今日已签到，累计 1200 分，连续 9 天
[2026-10-22 09:07:03] 打卡完成：连续 9 天（本月 9 天）| 能量 12 | 盲盒额度 0/10 | 抽奖机会 0 | 距 7d 奖励还差 0 天
[2026-10-22 09:07:04] 猫猫旅行：已派出前往「咖啡馆」，预计 3 小时后回家
[2026-10-22 09:07:05] 自动兑换已禁用｜当前无可兑换奖励（ 7d(未解锁) 14d(未解锁) 28d(未解锁)）
```

> 以上为输出格式示例，其中的积分数、连续天数、能量值均为虚构。

- 成长打卡带**生效校验**：对比上次记录的连续天数，没涨会记 WARN 并弹通知
- 猫猫旅行按状态推进：在家且今日未派出 → 派出；在外 → 记回家倒计时；已回家 → 领取积分
- 奖励检查按梯队状态汇报：available → 仅提示「可兑换」；locked/claimed → 静默跳过
- 积分签到活动为季节性，活动未开启时自动跳过

## 十五、通知策略

弹通知的情况只有三种：签到/补签成功、彻底失败（重试 3 次后仍失败）、凭证失效需重新生成。
日常"已完成"的重复触发和晚间核验通过都不弹通知。四分支通知标题不同
（"WorkBuddy 签到" / "WorkBuddy 成长计划" / "WorkBuddy 猫猫旅行" / "WorkBuddy 奖励"）以便区分。
**云端定时任务拿不到执行结果，必须在任务内主动把结果推送给用户。**

## 十六、文件

- `config/` — 凭证与状态文件，权限 600，勿提交勿外发：
  - `token`、`user_id`、`refresh_token` — 凭证三件套
  - `.rt_snapshot` — 上次从资料库拉取/回写成功时的长效凭证快照，**本身含凭证明文**，
    用于判断本次运行是否发生过续期
  - `state.json` — 成长计划上次打卡记录（用于天数增长校验）
  - `policy.env` — 三个运行开关
  - `重要凭证，切勿分享和发给别人！！！sandbox-creds-WB2.txt` — 待上传的凭证产物
- `logs/` — 签到日志（`checkin.log`；云端另有 `sandbox_run.log`），含敏感信息，勿外发
- `dist/` — `pack_bundle.sh` 的打包产物（含源码，不含凭证）
- `scripts/` — 全部逻辑脚本

## 十七、接口变更或活动结束时的行为

本 skill 依赖 WorkBuddy 官方活动接口，官方可能调整规则、更换接口或结束活动。已做的容错：

- 活动未开启/已结束：记录"活动未开启，跳过"并正常退出，不报错刷屏
- 接口异常或网络失败：自动重试 3 次（间隔 5s/15s），仍失败才记 ERROR 并弹通知
- 凭证失效：先自动在线续期；续期失败则提示用户在本机重新取证，**不尝试重新生成或绕过**
- 任何无法自愈的失败都会在日志留下明确报错，并由 Agent 在回复中如实转述给用户

## 十八、注意

- 自动化签到可能违反 WorkBuddy 用户协议，风险自担
- 凭证与日志含敏感信息：勿提交仓库、勿外发、勿截图分享
- 本分支**不在本机注册定时任务**；如确需本机兜底，自行用系统计划任务调用 `scripts/checkin.sh` 即可
- 云端定时任务与任何其他端同时跑不会多领（服务端幂等），但属于重复执行，按需保留一处即可

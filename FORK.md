# Fork 到自己的仓库

> 适用场景：希望代码来源、更新时机完全掌握在自己手里。例如团队要求依赖必须放在自己名下的仓库，
> 或不希望自己的部署受上游仓库后续改动影响。
>
> 下面三种方式按省事程度排序，任选一种。前两种需要改两处地址：**定时任务里取 `PROMPT.md` 的那一行**，
> 以及 **`PROMPT.md` 内部取 `bootstrap_bundle.sh` 的那两行**（只改前者等于没换来源）。

---

## 一、为什么有的团队会介意

| 现状 | 说明 |
|---|---|
| 每天 05:00 / 13:00 先取一次 `PROMPT.md`（执行步骤），再取一次 `bootstrap_bundle.sh`（引导脚本） | 确实每次联网取这两个文件，都来自 `raw.githubusercontent.com/ruilin365/...` |
| 用 `main` 分支地址时，仓库作者后续提交会带到自己的机器上 | 属实。换成固定 commit 即可让内容恒定 |
| 这两个文件会不会把凭证发出去 | 不会。`PROMPT.md` 是纯文字步骤，没有任何外发动作；`bootstrap_bundle.sh` 本身**不访问 GitHub**，全文只有两个网络动作：① 探活平台内部网关 `http://spaceengine.agent-gateway.auth-proxy.local`；② 从**你自己的**资料库下载包并校验 `sha256`。两者都不向任何外部地址发送数据 |

对应办法只有一条：**把「从上游仓库拉」换成「从自己仓库拉」或「锁定到某个固定版本」**。

---

## 二、真正在跑的是哪份代码（重要，别搞错）

```
⓪ 仓库 PROMPT.md                 ← 执行步骤（可取可改，改这里不用动定时任务）
        ↓ 任务按里面的步骤执行
① 仓库 bootstrap_bundle.sh      ← 每天 curl 的引导脚本，只负责「取包 + 校验 + 解包」
        ↓ 从你自己的资料库下载
② 资料库里的 wb-helper-local-bundle-v<版本>.txt   ← 真正执行的 skill 代码，你本机打包上传的
        ↓ 解包到
③ 云端沙盒 ~/.workbuddy/skills/wb-helper/        ← 每天实际跑的就是这里
```

推论两条，务必记住：

- **改仓库里的 `scripts/` 不会自动影响云端**。云端跑的是第 ② 步那个 bundle 包，必须重新打包上传才会生效。
- 反过来说，这也意味着：**真正执行的代码是你自己机器上打出来、传到你私人资料库的**，仓库里那份 `scripts/` 只是源码备份，供你审计。这条对自己复核来源也很有帮助。

---

## 三、选一条路

| 方案 | 要不要 fork | 内容会变吗 | 适合谁 |
|---|---|---|---|
| **A. 锁定上游某个 commit** | 不用 | 永不变 | 想最快解决，不想管理仓库 |
| **B. fork 到自己仓库** | 要 | 你不点 Sync 就不变 | 推荐。仓库在自己名下，来源最清楚 |
| **C. fork + 自己打包上传** | 要 | 完全自己定 | 想改脚本、想彻底自主 |

三条都做过的验证方式一样：**定时任务提示词里那一行 URL 变成你自己的 / 带 commit 号的**，上游仓库的后续改动就影响不到你了。

---

## 四、方案 A：锁定上游某个 commit（最省事，不 fork）

把地址里的 `main` 换成 40 位的 commit SHA。这样**即使作者改了 `main`，你拉到的永远是那一版**。

### A-1 取当前 commit SHA

浏览器打开：

```
https://github.com/ruilin365/WorkBuddy-helper/commits/main
```

最新那条提交右侧有一个 **复制按钮**（图标是两张纸），点是，SHA 就进剪贴板了。

或者用命令（把 `<用户名>` 换掉）：

```bash
curl -s https://api.github.com/repos/ruilin365/WorkBuddy-helper/commits/main | grep -m1 '"sha"' | cut -d'"' -f4
```

输出形如 `112dfe9c8e5a658b9a6822b031abd7e00d9dfe73`。

### A-2 换成固定地址

```
https://raw.githubusercontent.com/ruilin365/WorkBuddy-helper/112dfe9c8e5a658b9a6822b031abd7e00d9dfe73/bootstrap_bundle.sh
```

> 把 `112dfe9...` 换成你刚复制的 SHA。

### A-3 改定时任务提示词

任务提示词里只有一行地址（用来取 `PROMPT.md`）。把 `main` 换成你刚复制的 SHA：

```
( curl -fsSL --max-time 25 --retry 1 https://raw.githubusercontent.com/ruilin365/WorkBuddy-helper/<你的SHA>/PROMPT.md -o /tmp/wb_prompt.md && [ -s /tmp/wb_prompt.md ] ) || ( curl -fsSL --max-time 60 https://codeload.github.com/ruilin365/WorkBuddy-helper/tar.gz/<你的SHA> | tar -xz -O --wildcards '*/PROMPT.md' > /tmp/wb_prompt.md )
```

**还有一处必须同步改**：仓库里的 `PROMPT.md` 第 1 步含 bootstrap 地址，把那里的 `main` 也换成
同一个 SHA（raw 段末、codeload 的 `tar.gz/<你的SHA>` 两处）。只改任务里的地址而不管 `PROMPT.md`，
脚本仍然按 `main` 去取，等于没锁。

**优点**：两分钟搞定，内容立刻固定下来。
**缺点**：仓库还在别人名下，虽然内容锁死了；以后想顶到新版本，任务和 `PROMPT.md` 两处都要改。

---

## 五、方案 B：fork 到自己仓库（推荐）

### B-1 点 Fork

1. 浏览器登录 GitHub，打开 `https://github.com/ruilin365/WorkBuddy-helper`
2. 右上角点 **Fork** → 下一页点 **Create fork**
3. 等几秒，页面跳转到你自己的仓库：`https://github.com/<你的用户名>/WorkBuddy-helper`

### B-2 确认是公开仓库

页面标题下方应该显示 **Public**。

- Fork 一个公开仓库，默认就是 Public，一般不用改。
- 如果是 **Private**，点 `Settings` → 页面最下方 `Danger Zone` → `Change visibility` → 改成 Public。
  **私有仓库云端取不到**（沙盒里是裸 `curl`，没有任何 GitHub 认证），必须 Public。

### B-3 拿到你自己的地址

```
https://github.com/<你的用户名>/WorkBuddy-helper
```

例如用户名是 `zhangsan`，就是 `https://github.com/zhangsan/WorkBuddy-helper`。

**注意 fork 之后 `main` 是冻结的**：GitHub 不会自动把上游的改动同步到你的 fork，只有你自己点 `Sync fork` 才会更新。这正是我们要的「内容不会偷偷变」。

### B-4 改定时任务提示词

打开 05:00 和 13:00 两个**现有**任务（不要新建），把第 1 步那两行换成（`<你的用户名>` 两处都换）：

```
( curl -fsSL --max-time 25 --retry 1 https://raw.githubusercontent.com/<你的用户名>/WorkBuddy-helper/main/PROMPT.md -o /tmp/wb_prompt.md && [ -s /tmp/wb_prompt.md ] ) || ( curl -fsSL --max-time 60 https://codeload.github.com/<你的用户名>/WorkBuddy-helper/tar.gz/refs/heads/main | tar -xz -O --wildcards '*/PROMPT.md' > /tmp/wb_prompt.md )
```

**还要改一处，否则等于没 fork**：打开你 fork 里的 `PROMPT.md`，把第 1 步两处 bootstrap 地址里的
`ruilin365` 也换成 `<你的用户名>`（raw 那段和 codeload 那段各一处），提交到你的 `main`。
不改的话，指令虽然从你仓库读，脚本还是从作者仓库取。

**优点**：仓库在自己名下，来源最清楚；以后改领取步骤只改你 fork 里的 `PROMPT.md`，任务不用动。
**缺点**：需要多改一处。

### B-5（可选但推荐）再锁一层 commit

想再稳一层，在 B-4 基础上把你写的 `main` 换成你自己 fork 的 commit SHA（取法见「A-1」，
取你 fork 的最新提交）。一共四处：任务提示词里取 `PROMPT.md` 的 raw 段末与 `tar.gz/<你的SHA>`，
`PROMPT.md` 里取 bootstrap 的 raw 段末与 `tar.gz/<你的SHA>`。

这样连你自己误操作改坏仓库都不影响云端。

---

## 六、方案 C：fork 之后自己改脚本（完全自主）

fork 只是把源码放到了自己名下。**要让改动在云端生效，必须走资料库**，因为云端跑的是资料库里的 bundle。

### C-1 在 fork 里改脚本

直接在 GitHub 网页上改，或 `git clone` 到本地改：

```bash
git clone https://github.com/<你的用户名>/WorkBuddy-helper.git
cd WorkBuddy-helper
# 改 scripts/ 下你要改的文件
```

### C-2 改完必须抬版本号（否则云端不认新包）

同时改**两处**，保持一致：

| 文件 | 字段 |
|---|---|
| `_meta.json` | `"version": "1.8.4"` → `"1.9.0"` |
| `SKILL.md` | 开头 frontmatter 里的 `version:` |

约定抬 `x.y`（`1.8.4 → 1.9.0`），**不要**只加 `-local.N` 后段，否则版本比较会出问题。

### C-3 在本机打包并上传

在已装好的机器上（`~/.workbuddy/skills/wb-helper`）：

```bash
bash scripts/pack_bundle.sh
ls -l dist/
```

拿到 `dist/wb-helper-local-bundle-v1.9.0.txt`，上传到你自己资料库「我的资料」个人空间**根目录**。

硬约束三条（照做，否则云端取不到）：

1. 必须当**文件**原样上传，扩展名 `.txt`。传成在线文档/页面形式，云端下载不回来。
2. **文件名一个字都不能改**，尤其版本号。
3. 资料库不支持覆盖，同名上传会新建节点，**每次更新都换更大的版本号**。

### C-4 同步根目录引导脚本（如果改过它）

根目录 `bootstrap_bundle.sh` 和 `scripts/bootstrap_bundle.sh` 是同一份的两份拷贝，云端 `curl` 的是**根目录**那份：

```bash
cp scripts/bootstrap_bundle.sh ./bootstrap_bundle.sh
git add -A && git commit -m "sync bootstrap" && git push
```

### C-5 云端下次运行自动用新版

不用改提示词。bootstrap 会按「版本号最大者优先」从你资料库挑包。

---

## 七、以后怎么升级

| 你选的路 | 升级方式 |
|---|---|
| A（锁上游 commit） | 重新取一次 SHA，改提示词里的 URL。**升级变成显式动作**，升级就成了一个明确的动作 |
| B（fork，用 main） | 打开你的仓库 → 点 `Sync fork` → `Update branch`，云端下次运行即用新版 |
| C（fork + 自己打包） | 抬高版本号 → `pack_bundle.sh` → 上传资料库。仓库和资料库可以各自更新 |

升级完想验证：在云端会话里手动发一句 `bash ~/.workbuddy/skills/wb-helper/scripts/sandbox_run.sh --quiet`，看回报是否正常，不用等到触发时间。

---

## 八、怎么核查「仓库里有没有被人塞东西」

### 看这个仓库相对上游改了什么

把 `<你的用户名>` 换掉，浏览器打开：

```
https://github.com/ruilin365/WorkBuddy-helper/compare/main...<你的用户名>:main
```

- 显示 **"There isn't anything to compare"** → 和上游完全一致，没人动过。
- 有差异 → 逐条看，只有你自己改的那几个文件才对。

### 本地用命令对照

```bash
git remote add upstream https://github.com/ruilin365/WorkBuddy-helper.git
git fetch upstream
git log --oneline main..upstream/main      # 上游比你多了哪些提交
git diff main upstream/main --stat         # 具体改了哪些文件
```

### 只看那个会被执行的脚本

云端唯一会「下载并 bash 执行」的，就是根目录这**一个文件**。复核它一个就够了：

```
https://github.com/<你的用户名>/WorkBuddy-helper/blob/main/bootstrap_bundle.sh
```

它应该只做四件事：探活内部网关 → 从你的资料库列出候选节点 → 下载并校验 `sha256` → 解包到 `~/.workbuddy/skills/wb-helper`。**不该出现任何第三方域名。**

---

## 九、常见问题

**Q：fork 要改仓库名吗？**
不用。保持 `WorkBuddy-helper`，只是所有者变成你。

**Q：能不能用私有仓库？**
不能。云端沙盒里是裸 `curl`，不带任何 GitHub 认证，私有仓库一律 404。

**Q：改完提示词要删掉旧任务重建吗？**
不用。直接编辑现有那两个任务的提示词即可，时间设置不用动。

**Q：我在公司电脑部署了，家里电脑还要再来一遍吗？**
是的。取凭证必须在本机进行（凭证从本机登录态来），每台机器各自跑一次 DEPLOY.md 第二、三章。但**定时任务只需要建一次**，云端跑的是账号级的。

**Q：fork 之后作者更新了版本，我会自动拿到吗？**
不会。fork 的 `main` 是冻结的，必须你自己点 `Sync fork`。这正是「内容不会偷偷变」的保证。

**Q：团队仍然要求代码必须在自己仓库里，怎么办？**
把这几点讲清楚：真正执行的 skill 代码（第 ② 步）是你**自己机器上打包、传到你私人资料库**的，仓库那份只是源码备份。仓库里唯一被执行的只有一个引导脚本，且现在已经指向你自己的仓库 / 固定 commit，内容永久可复现。

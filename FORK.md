# Fork 到自己的仓库

> 解决的问题：安全审查看到「每次定时任务都从别人的 GitHub 仓库 `curl` 一段脚本并执行」，判定为供应链风险，拒绝安装。
>
> 这份文档给你三条路，按「省事程度」排序。**做完任意一条，审查点就消失了。**

---

## 一、先搞清楚：审查方到底在担心什么

| 审查方看到的 | 实际情况 |
|---|---|
| 每天 05:00 / 13:00 都从 `raw.githubusercontent.com/ruilin365/...` 拉一个 `.sh` 并 `bash` 执行 | 是真的。这一步确实每次联网取代码 |
| 仓库作者随时可以改内容，使用者无感知 | 是真的。用 `main` 分支地址就永远是「最新版」，内容会变 |
| 拉下来的脚本会不会偷凭证 | 脚本本身**不联网**：全文只有 2 个网络动作——① 探活平台内部网关 `http://spaceengine.agent-gateway.auth-proxy.local`；② 从**你自己的**资料库下载包并校验 `sha256`。不访问 GitHub，不往任何外部地址发数据 |

所以能立刻消除的只有第一条：**把「从别人仓库拉」换成「从自己仓库拉」或「锁定到某个固定版本」**。

---

## 二、真正在跑的是哪份代码（重要，别搞错）

```
① 仓库 bootstrap_bundle.sh      ← 每天 curl 的就是它，只负责「取包 + 校验 + 解包」
        ↓ 从你自己的资料库下载
② 资料库里的 wb-helper-local-bundle-v<版本>.txt   ← 真正执行的 skill 代码，你本机打包上传的
        ↓ 解包到
③ 云端沙盒 ~/.workbuddy/skills/wb-helper/        ← 每天实际跑的就是这里
```

推论两条，务必记住：

- **改仓库里的 `scripts/` 不会自动影响云端**。云端跑的是第 ② 步那个 bundle 包，必须重新打包上传才会生效。
- 反过来说，这也意味着：**真正执行的代码是你自己机器上打出来、传到你私人资料库的**，仓库里那份 `scripts/` 只是源码备份，供你审计。这条对审查方是很有力的说明。

---

## 三、选一条路

| 方案 | 要不要 fork | 内容会变吗 | 适合谁 |
|---|---|---|---|
| **A. 锁定上游某个 commit** | 不用 | 永不变 | 想最快解决，不想管理仓库 |
| **B. fork 到自己仓库** | 要 | 你不点 Sync 就不变 | 推荐。仓库在自己名下，审查方更认 |
| **C. fork + 自己打包上传** | 要 | 完全自己定 | 想改脚本、想彻底自主 |

三条都做过的验证方式一样：**定时任务提示词里那一行 URL 变成你自己的/带 commit 号的**，审查点即消失。

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

打开 05:00 和 13:00 两个**现有**任务，把第 1 步那行换成：

```
   curl -fsSL https://raw.githubusercontent.com/ruilin365/WorkBuddy-helper/<你的SHA>/bootstrap_bundle.sh -o /tmp/wbbs.sh && bash /tmp/wbbs.sh
```

**优点**：两分钟搞定，审查点消失。
**缺点**：仓库还在别人名下，虽然内容锁死了。

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

打开 05:00 和 13:00 两个**现有**任务（不要新建），把第 1 步那行换成：

```
   curl -fsSL https://raw.githubusercontent.com/<你的用户名>/WorkBuddy-helper/main/bootstrap_bundle.sh -o /tmp/wbbs.sh && bash /tmp/wbbs.sh
```

只改 `<你的用户名>` 这一段，其余一字不动。

### B-5（可选但推荐）再锁一层 commit

想让审查方彻底无话可说，在 B-4 基础上把 `main` 再换成你自己的 commit SHA，取法见「A-1」，地址换成：

```
https://raw.githubusercontent.com/<你的用户名>/WorkBuddy-helper/<你的SHA>/bootstrap_bundle.sh
```

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
| A（锁上游 commit） | 重新取一次 SHA，改提示词里的 URL。**升级变成显式动作**，这正是审查方想看到的 |
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

云端唯一会「下载并 bash 执行」的，就是根目录这**一个文件**。审查它一个就够了：

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

**Q：审查方还是不通过怎么办？**
把它引到第二节那张图：真正执行的 skill 代码（第 ② 步）是你**自己机器上打包、传到你私人资料库**的，仓库那份只是源码备份。仓库里唯一被执行的只有一个引导脚本，且现在已经指向你自己的仓库 / 固定 commit，内容永久可复现。

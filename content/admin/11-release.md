# 从源码到新机器：一条龙发布

这一页只解决一件事：**你在开发机上改完代码，怎么让另一台机器跑上这一版。**

目标机器侧的安装细节见 [② 包干到底部署](/admin/deploy)；
构建提速、增量编译见 [⑩ 开发与构建](/admin/dev-build)。

> **为什么需要单独一页**：2026-11-03 在一台新机器上部署翻车，查下来是
> 「开发机上是新的、交付出去的是旧的」—— 四个环节各copy一份，没有任何一处强制同步。
> 这页把四个环节串成一条命令链，每一步都有判据。

---

## 0. 先选路（选错白干一小时）

| 你要做的事 | 走哪条 | 会动你的 `~/energy-app` 吗 |
| --- | --- | --- |
| 发布到一台**新机器** | [路径 A](#路径-a发布到一台新机器) | **不动**（在临时目录组装） |
| 给**已经装好**的那台更新版本 | [路径 B](#路径-b就地升级已有的那台) | 会改，但只改物料与 jar，不碰 `.env` |
| 只在本机改代码看效果 | 不是发布，看 [⑩](/admin/dev-build) | — |

**两条路的区别必须清楚**：

- **路径 A** 用 `--pack`，在 `mktemp -d` 里组装，**完全不碰 `~/energy-app`**。
- **路径 B** 改的是 `~/energy-app` 本身。`32-check-deploy-sync.sh --fix`
  会先备份再同步，且**不碰 `.env`**（`.env` 里是数据库密码，一换旧库就连不上）。

---

## 1. 开工前自检（两条路都要，约 10 秒）

```bash
cd <你的仓库目录>

java -version 2>&1 | head -1
node -v
docker ps --format '{{.Names}}' | grep -c energy || true

# 确认没有构建在跑（有就等它结束，否则两个构建抢同一个输出目录）
ps aux | grep -cE "[n]g serve|[n]g build"
```

**判据**（四条全对才能往下走）：

| 项 | 必须是什么 | 不对怎么办 |
| --- | --- | --- |
| `java -version` | **25** 或更高 | `pack.sh` 会直接拒绝。macOS：`brew install --cask temurin@25` |
| `node -v` | v18 以上（实测 v22 可用） | 装 Node |
| 容器数 | 0 也行（说明本机没在跑） | — |
| 构建进程数 | **0** | `ng build` 与 `pack.sh` 同时跑会让产物互相覆盖，表现为「index.html 引用的 chunk 404」 |

---

## 路径 A：发布到一台新机器

七步，全程可复制粘贴。**任何一步判据不符就停下，不要跳。**

### A1　同步物料并校验（必做）

部署侧读的是 `~/energy-app/data`，**不是源码目录**。两者会漂移。

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
```

**判据**：最后一屏必须是

```
✓ 部署物料与源码一致，可以 install / 打包
```

**如果报 ✗**，先看是哪一类：

| 报什么 | 含义 | 怎么办 |
| --- | --- | --- |
| `部署脚本过期 N 个：docker-00/01/02/97` | 新机器部署**第一步**要跑的脚本是旧的 | 见下方「为什么这最致命」 |
| `scripts/ 与源码不一致` | 运维脚本漂移 | 同上 |
| `json/ 有差异` | 部件或看板模板漂移 | 同上 |

自动修（**会先备份**，可回滚）：

```bash
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app   # 复跑必须全绿
```

备份在 `~/energy-app/data/json.bak.<月日-时分>` 与 `~/energy-app/scripts.bak.<月日-时分>`。

> **为什么这一条最致命（2026-11-03 实测）**
>
> 旧版 `docker-02-start.sh` 里是
> `CODE=$(curl ...)`，而脚本开头有 `set -euo pipefail`。
> 新机器上服务刚起来、curl 连不上时**赋值语句整体非零 → 脚本静默退出**，
> 用户只看到「服务已就绪」然后什么都没了 —— 管理员没建成，后面全崩。
> 新版写成 `CODE=$(curl ...) || CODE="000"`，任何失败都走分支给明确错误。
>
> **开发机上永远撞不到**（容器早已预热），只在新机器上炸。
> 同一轮还发现 `docker-01-install.sh` 的时序后端默认值写反（`cassandra` vs `sql`）。

> **路径 A 其实也不依赖这一步** —— A3 的 `--pack` 会从源码重新拷一份。
> 但**强烈建议跑**：它能在你花 10 分钟打包之前，先告诉你「源码里有东西没被装配进去」。

### A2　打 jar（含前端）

```bash
cd <你的仓库目录>
bash guard-server/pack.sh
```

**它做什么**（一条命令串起三件容易漏的事）：

1. `ng build --configuration production` → 前端产物
2. `mvn package -DskipTests` → 把前端打进 jar 的 `public/`
3. 检查 jar 内容（内嵌 UI / tbel 依赖 / xss 资源 / 主类）

**耗时**：实测 2026-11-03 **增量 12 分 14 秒**（前端 production 构建 + Maven 增量）。
`--clean` 全量会更久（依赖重新下载）。**别反复跑**，一次改完一批再打。

> 手册不能写「大概几分钟」就完事 —— 本节所有数字都是实测。
> 你若发现明显更慢（比如 20 分钟以上），先查是不是有 `ng serve` 在同时跑。

**判据**：最后必须是（以下为 2026-11-03 实测原文）

```
✓ 打包成功  用时 12m14s

  JAR : .../guard-server/target/guard-server-4.4.0.jar
  大小: 576M
```

且前面这几行都是 ✓（实测内嵌 UI 为 10268 个文件）：

```
✓ 内嵌 UI：index.html 存在，public/ 下 N 个文件
✓ 依赖 tbel 1.2.10
✓ 资源 xss-policy.xml
✓ 资源 js/converter-helpers.js
✓ 主类 ThingsboardServerApplication
```

**如果「jar 内无 UI」**：前端产物没打进去 → 你的机器上会出现「菜单在、页面空白」。
去掉 `--skip-ui` 重跑。

**常用参数**：

| 参数 | 什么时候用 |
| --- | --- |
| `--skip-ui` | **只改了 Java**，前端没动。复用上次产物，省 4 分钟 |
| `--clean` | 怀疑产物脏了（奇怪报错、改了没生效）。全量重建 |
| `--keep-logs` | 要排查构建失败，保留 `target/build-logs/` |

> **只改了部件 JSON（`widget_types/*.json`）不需要打 jar** ——
> 部件是运行时从数据库读的，见 [⑩ 开发与构建](/admin/dev-build) 的部件发布一节。

### A3　组装发布包

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
```

**它做什么**：在 `mktemp -d` 建临时目录，把**源码**的这七样装进去，再压成 tar.gz：

```
guard-server-4.4.0.jar        ← 上一步的产物
data/json/                    ← 源码的部件与看板模板
data/sql/                     ← 源码的建表脚本（8 个）
data/cassandra/               ← 可选后端的建表脚本
docker-*.sh + docker-compose.yml
scripts/                      ← 全部运维脚本（数量和源码对不上会直接报错）
templates/ nginx/ allinone/
```

**关键**：它**从源码拷**，不是从 `~/energy-app` 拷。
所以 A1 即使跳过了，这里也不会带旧物料 —— 但 A1 能提前发现问题。

**耗时**：约 30–60 秒（拷 37MB data + 压 544MB jar）。

**判据**：

```
✓ 打包完成
  发布包  dist/energy-deploy-<日期>.tar.gz  （约 544M）
  数据库密码（已写进包内 .env）  <32 位随机串>
```

**⚠ `.env` 里的数据库密码是随机生成的，随包走。**
装完想连库，从目标机的 `energy-deploy/.env` 里读 `SPRING_DATASOURCE_PASSWORD`。
**现在就把密码记下来**，脚本也会打印一次。

**同步重跑不会重复建**：`--pack` 用临时目录，跑多少次都不会污染 `~/energy-app`。

### A4　验包（不验不上传）

```bash
cd <你的仓库目录>
TAR=dist/energy-deploy-$(date +%Y%m%d).tar.gz

# ① 七个关键文件必须在
for f in energy-deploy/guard-server-4.4.0.jar \
         energy-deploy/.env \
         energy-deploy/docker-01-install.sh \
         energy-deploy/docker-02-start.sh \
         energy-deploy/data/json/tenant/dashboards/device_ops.json \
         energy-deploy/data/sql/schema-entities.sql \
         energy-deploy/scripts/32-check-deploy-sync.sh; do
  tar -tzf "$TAR" | grep -qxF "$f" && echo "  ✓ $f" || echo "  ✗ $f 缺失"
done

# ② 脚本必须是修复版（这条曾让新机器静默退出）
tar -xzOf "$TAR" energy-deploy/docker-02-start.sh | grep -c 'CODE="000"'
tar -xzOf "$TAR" energy-deploy/docker-01-install.sh | grep 'TS_TYPE="${DATABASE_TS_TYPE'

# ③ jar 至少 300MB（太小说明前端没打进去）
#   注意：macOS/Linux 的 `tar -tv` 输出里，大小是第 5 列，不是第 3 列
#   （前四列是：权限 链接数 用户 组），写错会得到 0
 tar -tzvf "$TAR" | grep 'guard-server-4.4.0.jar' | awk '{printf "  %.0f MB\n", $5/1048576}'
```

**判据**：

| 检查 | 期望 |
| --- | --- |
| 七个文件 | 全部 `✓` |
| `grep -c 'CODE="000"'` | **≥1** |
| `TS_TYPE` | 显示 `:-sql}` 结尾 |
| jar 大小 | 500MB 以上 |

**任何一项不符 → 回 A2/A3 重做，不要上传。**

### A5　传到目标机并解压

```bash
# 在你的开发机上
scp dist/energy-deploy-$(date +%Y%m%d).tar.gz root@<目标机IP>:/opt/

# 登录目标机
ssh root@<目标机IP>
cd /opt && tar -xzf energy-deploy-$(date +%Y%m%d).tar.gz
cd /opt/energy-deploy && ls -la
```

**判据**：`ls` 能看到 `.env`、`guard-server-4.4.0.jar`、`data/`、`docker-01-install.sh`。

**目标机前置条件**：装好 Docker（见 [① 安装环境](/admin/install)）。
`.env` 里的 `APP_HOME` 会在解压后自动填成当前目录，**不用手改**。

### A6　建库

```bash
cd /opt/energy-deploy
bash docker-01-install.sh
```

**它做什么**：建 112 张表 + 装系统部件与 bundle。约 2–3 分钟。

**判据**：最后是

```
✓ 建库完成
```

**如果报 `库已有 N 张表`** → 这台机器装过了，别重来；
直接跳到 A7（`docker-02-start.sh`）。

### A7　启动 + 建系统管理员

```bash
cd /opt/energy-deploy
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'
```

**它做什么**：起容器 → 等健康 → 建管理员 → 打印登录地址。

**判据**：

```
✓ 服务已就绪
✓ 管理员已创建
```

**如果卡住或退出**：

| 现象 | 原因 | 怎么办 |
| --- | --- | --- |
| 提示 `连接不上` / `HTTP 000` | 后端还没就绪（首次 1–2 分钟） | 等 1 分钟重跑同一条命令 |
| 提示 `HTTP 502/503` | gateway 起来了但后端还没好 | 同上 |
| 容器反复重启 | 看日志 | `docker logs energy-server --tail 50` |

### A8　建租户

**为什么必须单独一步**：平台没有默认租户。系统管理员**不能直接建客户**（TB 返回 403），
必须先有租户管理员身份。

```bash
cd /opt/energy-deploy
bash scripts/02-onboard.sh \
  --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

**判据**：最后是 `✓ 全部验证通过`，且中间有这几行：

```
✓ 租户已创建
✓ 租户管理员已激活并取得会话
✓ 能源参数字典：1 个
✓ 系统部件：N 个
```

> 建租户会自动铺租户级主数据（字典 / 档案 / 费率 / 分时 / 菜单），不用另外初始化。

### A9　建第一个客户

```bash
cd /opt/energy-deploy
bash scripts/09-onboard-customer.sh \
  --email customer@example.com --password 'Cust@123456' \
  --name '某某厂区'
```

**判据**：最后是逐项 `✓`，并打印登录信息 + 交付文件
`ONBOARDED-<客户id>.txt`（权限 600，含账号与查询 SQL）。

**这一步会自动完成**：建客户 → 建客户管理员 → 铺演示数据 → 装客户菜单
→ 复制看板 → 逐项验证。

> **建客户会阻塞 60–120 秒**，属正常现象（要铺 33 天遥测）。

### A10　平台自检

浏览器打开 `http://<目标机IP>:8090`，用 A9 的客户账号登录，然后点左侧「平台自检」。

**判据**：自检页逐项通过；左侧菜单能看到完整业务菜单（不是 TB 原生菜单）。

再抽查这几个页面必须**有内容且有面包屑**：

- 设备管理 → 设备运维 / 设备分组 / 设备拓扑
- 告警事件
- 组织

面包屑显示为 `设备管理 > 设备运维` 这种两段式，**不是空白**。

### A11　收尾清理

```bash
# 开发机：删旧发布包，只留最近一个
cd <你的仓库目录>
ls -t dist/energy-deploy-*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -v

# 开发机：清物料同步产生的备份，只留最近一份
cd ~/energy-app/data && ls -dt json.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf
cd ~/energy-app && ls -dt scripts.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf

# 开发机：jar 备份只留一份
cd ~/energy-app && ls -t guard-server-4.4.0.jar.bak-* 2>/dev/null | tail -n +2 | xargs -r rm -v

# 开发机：确认没有自己起的构建进程残留
ps aux | grep -cE "[n]g serve|[n]g build"
```

**判据**：最后一条输出 `0`。

> 目标机上的 `energy-deploy/` 目录**留着**：以后升级、查日志、跑运维脚本都要用。

> **发布包绝不能进 git**（2026-11-03 实测）：
> `dist/energy-deploy-<日期>.tar.gz` 有 **549MB**，一旦被 `git add`
> 仓库立刻胀到不可用。`.gitignore` 里已有 `dist/`：
>
> ```bash
> grep -qx "dist/" .gitignore || printf '\ndist/\n' >> .gitignore
> git check-ignore -v dist/energy-deploy-*.tar.gz    # 必须命中，否则就是没忽略
> ```
>
> 如果已经误入了索引（`git status` 里是 `A` / `AM`）：
>
> ```bash
> git rm --cached -f dist/energy-deploy-*.tar.gz   # 只移出索引，不删文件
> ```

---

## 路径 B：就地升级已有的那台

适用于：已经有了 `~/energy-app` 且**数据库里有真实数据**，只想换版本。
**不重建库，不动 `.env`，不动数据。**

### B1　同步物料

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
# 有 ✗ 就加 --fix，然后复跑必须全绿
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
```

**判据**：`✓ 部署物料与源码一致，可以 install / 打包`

### B2　打 jar

```bash
cd <你的仓库目录>
bash guard-server/pack.sh --skip-ui    # 只改了 Java
# 或
bash guard-server/pack.sh              # 前端也改了
```

**判据**：`✓ 打包成功`。

> **只改了部件 JSON**：不用打 jar。改 `widget_types/*.json` 后重新发布部件即可，
> 见 [⑩ 开发与构建](/admin/dev-build)。

### B3　换 jar 并重启

```bash
cd <你的仓库目录>

# ① 停容器再换文件（避免「文件被占用」和半新半旧）
docker stop energy-server

# ② 备份旧 jar（只留一份）
cd ~/energy-app && mv guard-server-4.4.0.jar guard-server-4.4.0.jar.bak-$(date +%H%M)

# ③ 放入新 jar
cp <你的仓库目录>/guard-server/target/guard-server-4.4.0.jar ~/energy-app/

# ④ 启动
docker start energy-server

# ⑤ 等健康
for i in $(seq 1 50); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/ 2>/dev/null)
  [ "$code" = "200" ] && { echo "就绪（第 ${i} 次）"; break; }
  sleep 3
done
```

**判据**：打印 `就绪`，且 `docker ps` 里 `energy-server` 是 `healthy`。

### B4　验证

```bash
docker logs energy-server --since 3m 2>&1 | grep -iE "ERROR|Exception" | \
  grep -viE "totalFailed \[0\]" | head -5
```

**判据**：**无输出**（无异常）。

浏览器硬刷新（`Cmd+Shift+R` / `Ctrl+F5`）后抽查页面。

### B5　清理

同 [A11](#a11-收尾清理)。

---

## 三个会让你翻车的坑

都有 2026-11-03 的实测来源。**这三条是本页存在的理由。**

### 坑 1：只 `git pull` 不 build → 源码新的、界面旧的

`ui-ngx/target/` 在 `.gitignore` 里，**前端产物不进版本控制**。
clone 或 pull 之后不跑 `pack.sh`，浏览器里就是上一次构建的界面。

**症状**：代码明明改了，页面还是老样子；控制台无报错。
**判据**：`ls -la ui-ngx/target/generated-resources/public/index.html` 的修改时间
必须**晚于**你最后一次改 `ui-ngx/src` 的时间。
**修**：跑 `bash guard-server/pack.sh`（或 `--skip-ui` 若前端没动）。

### 坑 2：直接改 `~/energy-app`，忘了同步 → 物料旧

部署侧读 `~/energy-app/data`，源码改的是 `guard-server/src/main/data`。
**两个目录不会自动同步。**

**症状**：新加的看板/部件在新装机器上不存在；菜单少项。
**判据**：`32-check-deploy-sync.sh` 全绿。
**修**：`32-check-deploy-sync.sh --fix`，或走路径 A 的 `--pack`（从源码重新拷）。

### 坑 3：新机器用了旧脚本 → 静默退出

见 [A1 的说明](#a1同步物料并校验必做)。
旧 `docker-02-start.sh` 在 `set -euo pipefail` 下，curl 失败会让脚本**无声退出**。

**症状**：新机器上「服务已就绪」之后就没了，管理员建不成。
**判据**：`grep -c 'CODE="000"' ~/energy-app/docker-02-start.sh` ≥ 1。
**修**：`32-check-deploy-sync.sh --fix`，或重新 `--pack`。

### 附：并行开发的正确姿势

**两台电脑同时改同一个仓库**时，`git pull --rebase --autostash` 会把你的未提交改动
临时 stash 起来。**冲突时它会静默留在 `stash@{0}`**，工作区看起来「变回旧版」。

```bash
git stash list                                  # 有残留就看一眼
git stash show -p stash@{0} | head -40          # 看它装了什么
```

但**大多数「代码变旧了」不是这个原因**，先按下面顺序查：

1. 这一屏由谁渲染？菜单 `linkType` 是 `DASHBOARD`（部件）还是 `URL`（Angular 路由）
2. 前端产物时间 vs `ui-ngx/src` 时间（坑 1）
3. `32-check-deploy-sync.sh` 是否全绿（坑 2）
4. 最后才怀疑 git —— `git reflog` / `git stash list` / `git fsck --lost-found`

详见 [⑨ 排障 · 页面看起来还是旧版](/admin/troubleshoot)。

---

## 一页速查

```bash
# ── 发布到新机器 ──────────────────────────────
cd <仓库>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
bash guard-server/pack.sh
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
# 验包 → scp → 解压 → docker-01 → docker-02 → 02-onboard → 09-onboard-customer

# ── 就地升级 ─────────────────────────────────
cd <仓库>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash guard-server/pack.sh --skip-ui
docker stop energy-server && cp guard-server/target/guard-server-4.4.0.jar ~/energy-app/ && docker start energy-server

# ── 只改了部件 JSON（不用打 jar）──────────────
cd <仓库>/nenghaobao/widgets && node build-xxx.mjs

# ── 到处都是同一个判据 ────────────────────────
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
```

**唯一一个「一切正常」的信号**：

```
✓ 部署物料与源码一致，可以 install / 打包
```

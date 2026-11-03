# ② 系统部署：从源码到客户能登录

**这一页走完就够。** 不用在几页之间来回跳 —— 选路、步骤、判据、失败处理都在这。

只有两件事需要另外查：

- Docker 本身装不上 → [① 安装环境](/admin/install)
- 装完报错、页面空白 → [⑨ 排障](/admin/troubleshoot)

---

## 先选路（30 秒决定看哪段）

| 你的处境 | 走哪段 | 大概耗时 | 会动 `~/energy-app` 吗 |
| --- | --- | --- | --- |
| 一台**全新机器**，或刚跑过 `uninstall --purge` | 场景 A（11 步） | 25–40 分钟 | 会**重建**它 |
| 已经装好、只想**换版本** | 场景 B（5 步） | 15–20 分钟 | 只换 jar 与物料，**不动 `.env` 和数据** |
| 只改了**部件 JSON / 运维脚本** | 场景 C | 1–2 分钟 | 只改对应文件 |

**选错的代价**：把场景 B 当 A 做，`docker-00-prepare.sh` 会想重建目录；
把 A 当 B 做，jar 是旧的、物料没铺，装完就是「菜单在、页面空」。

---

## 阶段 0　开工前自检（三个场景都要，约 10 秒）


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

---


## 场景 A　发到一台新机器（11 步）

七步，全程可复制粘贴。**任何一步判据不符就停下，不要跳。**

### A1　同步物料并校验

部署侧读的是 `~/energy-app/data`，**不是源码目录**。两者会漂移。

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
```

**这条命令有三种正常结果，不是只有一种。**

**结果 1：部署目录不存在**（全新机器，或刚跑过 `uninstall --purge`）

```
! 部署目录不存在：/Users/xxx/energy-app

    这不是错误 —— 说明这台机器还没有部署（或刚跑过 uninstall --purge）。
    没有可同步的对象，本步直接跳过。
```

**这是正常的，直接去 A2。** 物料会在 A3 组装时从源码重新拷一份。

> 2026-11-03 实测：旧版本这里直接报 `✗ 部署目录不存在` 并以退出码 1 结束，
> 既没说这是正常的，也没说下一步干什么 —— 客户跑完 uninstall 后卡在第一步。
> 已修：现在报 `!` 并打印下一条命令，退出码 0。

**结果 2：全绿**

```
✓ 部署物料与源码一致，可以 install / 打包
```

→ 去 A2。

**结果 3：报 ✗ 有差异**

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

> **场景 A 其实不依赖这一步** —— A3 的 `--pack` 会从源码重新拷一份。
> 跑它只是为了在花 10 分钟打包之前，先知道「源码里有东西没被装配进去」。
> 全新机器上直接跳过也是对的。

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

---


## 场景 B　就地升级已有的那台（5 步）

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

---


## 场景 C　只改了部件 / 脚本（最轻）

**改了部件 JSON、看板模板、运维脚本 —— 不用打 jar，不用重启后端。**

这是最常遇到的情况，也是被误解最多的一种：改完部件就跑 `pack.sh`，
白等 12 分钟。实际上部件是**运行时从数据库读**的，跟 jar 无关。


现场已经在跑，只想把新脚本 / 新部件送上去。**两类东西走两条路**：

```bash
# ① 脚本 / sql / 部件 JSON 的**文件**送进部署目录
#    在仓库里跑（不能在部署目录里跑）
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --fix

# ② 部件 JSON 还要**写进数据库**（存量库的 widget_type 记录）
#    同样在仓库根目录跑，指定部件名或 --all
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all

# ③ 改了后端代码才需要：重打 jar + 重启（约 10 分钟）
cd guard-server && mvn package -o -DskipTests -Dmaven.test.skip=true -q
cp target/guard-server-4.4.0.jar ~/energy-app/ && docker restart energy-server
```

**只改脚本的话，②③ 都不用做** —— 脚本是 shell/python，拷过去就能跑。

两张路的分工列一下，别搞混：

| 脚本 | 干什么 | 写数据库 | 改完部件该跑哪个 |
| --- | --- | --- | --- |
| `32-check-deploy-sync.sh --fix` | 三类文件比对 + 同步 | ✗ | 新建库前必跑 |
| `31-deploy-widget.sh <名>` | 推库 + 同步挂载目录 | ✓ | 存量库改部件 |
| `docker-00-prepare.sh` | 全量组装（会 `rm -rf` 目标目录） | ✗ | 全新机器才用 |

> 两个脚本都**必须从仓库跑**。从 `~/energy-app/scripts` 跑时，
> `32` 会直接拒绝（拿自己比自己永远报一致），`31` 会因找不到仓库路径而报错。
> 它们自己知道自己被拷进了部署目录 —— 这就是预防。

### 升级时 .env 的端口项（2026-11-03）

`SERVER_DIRECT_PORT`（直连排查口）是后加的。**老部署的 .env 里没有这一项**，
compose 会自动用默认值 `8091`。多数情况无需处理，但两种场景要看一眼：

```bash
# ① 宿主机 8091 已被别的服务占用 → compose up 会报
#    Bind for 0.0.0.0:8091 failed: port is already allocated
lsof -nP -iTCP:8091 -sTCP:LISTEN

# ② 确实被占了：在 .env 里显式改一个空闲端口
#    注意不能与 HTTP_PORT 相同（两个容器抢一个宿主端口）
echo 'SERVER_DIRECT_PORT=8093' >> ~/energy-app/.env
docker compose up -d gateway energy-server
```

> 新部署（跑过新版 `docker-00-prepare.sh` 的）不用管 —— 它会自动找一个
> 既空闲、又不与 `HTTP_PORT` 相同的值写进 `.env`。

### 为什么需要这一节（真实故障）

`docker-00-prepare.sh` 只在**组装时**拷一次脚本。之后仓库里新增的脚本
（比如 `29-rtu-demo-up.sh`）不会自己跑进已经部署的目录。

现场表现：手册写得对、仓库里文件也在、容器跑得好好的，只有命令报

```
bash: scripts/29-rtu-demo-up.sh: No such file or directory
```

判据：

```bash
ls ~/energy-app/scripts/ | grep 29-           # 空的 = 没同步
ls shiyongshouce/downloads/scripts/ | grep 29-   # 这里应该有
```

实际踩到的场景：`~/energy-app/scripts/` 还停在 10-29 那一批（26 个），
而仓库已经有 30 个。差的 4 个恰好是本次新写的演示/初始化脚本 ——
**手册里最新、最想用的命令，恰好是最容易缺的那几个**。

以后手册里出现的每个脚本，**都必须先跑过一次 `--fix`**。

---

---


## 细节参考（按需跳，不是必须按顺序看）

### 组装后目录验收（3 个数字）

无论走 `docker-00-prepare.sh`（就地装）还是 `--pack`（打包带走），
组装完成后都该验这三个数：

```bash
ls ~/energy-app/guard-server-4.4.0.jar
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l     # 必须是 30
ls ~/energy-app/data/sql/*.sql | wc -l                   # 必须是 8
```

> `.env` 是隐藏文件，`ls` 看不到。看内容：`cat ~/energy-app/.env`。
> **要装到别的目录**：`bash docker-00-prepare.sh /data/energy-app`。
>
> **30 和 8 不是随便写的**：30 = 客户看板模板总数（含设备运维/分组/拓扑、
> 告警事件、组织与场站这 5 块）；8 = 建表 SQL。少一个就说明组装漏了东西。


### sql 与 Cassandra 脚本的来源（2026-11-02 已自包含）

| 物料 | 位置 | 消费方式 |
| --- | --- | --- |
| 建表 SQL（8 个） | `guard-server/src/main/data/sql/` | install 读 `install.data_dir/sql/` |
| Cassandra CQL（3 个） | `guard-server/src/main/data/cassandra/` | 切 Cassandra 时才用 |

两份都已从 `dao/` 模块**实体化**进 guard-server，不再依赖符号链接
（dao 模块清理后不会断链）。确认依赖已切断：

```bash
grep -n "dao/src" shiyongshouce/downloads/deploy/docker-00-prepare.sh   # 应该无输出
```

---


### 从别的机器访问需要放行防火墙

容器端口映射只管**宿主机本机**。客户用自己的电脑访问、或云服务器，还要放行：

```bash
# Ubuntu / Debian
sudo ufw allow 8090/tcp
sudo ufw allow 1883/tcp        # 设备上报
sudo ufw allow 11883/tcp       # 现场固件写死的端口

# CentOS / RHEL
sudo firewall-cmd --add-port=8090/tcp --permanent
sudo firewall-cmd --add-port=1883/tcp --permanent
sudo firewall-cmd --add-port=11883/tcp --permanent
sudo firewall-cmd --reload
```

云服务器（阿里云/腾讯云/AWS）还要在控制台**安全组**放行同样的 TCP 端口。
这是“容器起来了但外面访问不了”最常见的原因。

> **macOS 本机**不需要放行（系统防火墙默认不拦已签名的 Docker），但首次启动
> Docker Desktop 时系统会弹「是否允许接受传入网络连接」，**必须点允许**。
> 已经误点拒绝的：系统设置 → 网络 → 防火墙 → 选项，把 Docker 加回来。

---


### 内存紧张时：单容器模式

平台默认四个容器。**物理内存 < 10GB** 的机器，可以合并成单容器：

```bash
cd ~/energy-app
bash docker-02-start.sh --allinone --admin-email ... --admin-pass ...
```

单容器省一个容器、省 ~2GB 常驻。代价是「重启一个全部重启」。
**演示机、笔记本推荐单容器**；生产环境用默认四容器。

---


### 验收基线（实测数字）

| 检查项 | 应有值 |
| --- | --- |
| 库表 | 122 张 |
| 系统部件（install 后 DB 行数） | 743 个 |
| 交付的部件文件 | 584 个 |
| 能源参数字典 | 1 个资产，标准 key **137** 个（电能 122） |
| 演示客户 | 「平台演示中心」，10 台设备（8 台可模拟） |
| 归属关系 | 场站 10 条 `SiteContains`，区域/分项按拓扑挂好 |
| 客户看到的计量点 | 综合能耗页显示「当前 **8** 台计量点」 |

---


### 首次部署的两处等待（正常现象）

### ① 建客户会阻塞 60~120 秒

新建客户时，后端会在**同一个请求里同步**跑完整套演示数据初始化
（4 个维度根 / 2 个场站 / 12 个分项 / 21 台设备 / 一批遥测 + 费率）。

- `29` 已把这个请求的超时放宽到 600 秒
- 如果仍看到 `timed out`：**客户其实建好了**，等 1 分钟重跑 `29` 即可（幂等）

### ② 首次 `install` 约 2-3 分钟

建 122 张表 + 导入 743 个部件。机器慢的话会到 5 分钟，属正常。

---

---


## 卸载平台

```bash
cd ~/energy-app

# 只停服务，保留数据
bash docker-99-uninstall.sh

# 彻底删除（含数据卷，不可恢复）
bash docker-99-uninstall.sh --purge --yes
```

**三个参数分别管什么**：

| 参数 | 作用 |
| --- | --- |
| （无） | 停容器、删容器，保留下层数据卷 |
| `--purge` | 连数据卷一起删（库、日志全没） |
| `--yes` | 跳过交互确认（脚本化用） |

**只想重装、不想手工分两步**：

```bash
bash docker-99-uninstall.sh --purge --yes && \
bash docker-01-install.sh && \
bash docker-02-start.sh --admin-email ... --admin-pass ...
```

**镜像删不删**：`docker-99-uninstall.sh --purge` 不删镜像（下次装更快）。
要彻底清盘再加 `docker rmi energy/guard-server:4.4.0 eclipse-temurin:25-jre postgres:16`。

**验证删干净了**：

```bash
docker ps -a | grep energy          # 应该无输出
docker volume ls | grep energy      # 应该无输出
ls ~/energy-app                     # 只剩 data/ 和 .env（如果没 --purge）
```

---

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

---


## 附：并行开发的正确姿势

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

#### 推送被拒（`! [rejected] main -> main (fetch first)`）

2026-11-03 实测原文：

```
[main 95d8088] update manual
To https://github.com/<你>/guard_help.git
 ! [rejected]        main -> main (fetch first)
error: failed to push some refs to '...'
```

**不是权限问题，也不是网络问题。** 含义就一句：
**远端有你本地没有的提交，直接推会覆盖别人。** Git 拦住了。

最常见的来源就是本文开头那个场景 —— **另一台电脑推过**。

**三步处理**：

```bash
cd /Users/<你>/Documents/workspace/guard_help

# ① 先看远端到底多了什么（只读，不改工作区）
git fetch origin
git log --oneline HEAD..origin/main      # 远端有、你没有
git log --oneline origin/main..HEAD      # 你有、远端没有

# ② 拉平（保留你的提交，重放到远端之上）
git pull --rebase origin main

# ③ 推
git push origin main
```

**如果第 ② 步报冲突**（`UU` 标记）—— 两侧改了同一文件。
**不要直接 `git checkout --ours/--theirs`**，先判断能否丢内容：

```bash
git status                       # 看哪几个是 UU
git merge-base <远端提交> <你的提交>    # 取共同祖先

# 关键判据：你的版本是不是远端的严格超集？
git diff <远端提交> <你的提交> -- <冲突文件> | grep '^-'
#   ↑ 输出为空 = 远端独有行数 0 = 你的版本已包含远端全部内容，取你的版本安全

# 确认安全后，取你的版本（rebase 中 --theirs 指的是你正在重放的提交）
git show <你的提交>:<冲突文件> > <冲突文件>
grep -c '^<<<<<<<' <冲突文件>     # 必须是 0
git add <冲突文件>

git rebase --continue
```

**本次实测的冲突内容**（很典型）：

| 文件 | 两侧改了什么 | 正确取舍 |
| --- | --- | --- |
| `02-deploy.md` | 远端写「看板模板必须是 25」，本地写 30 | 取 **30**（新增 5 个模板后的实测值） |
| `07-device-access.md` | 远端新增 2 个小节，本地新增同样 2 个 + 另 2 个 | 取**本地**（远端独有行数 = 0） |

**⚠ rebase 过程中不要用 `git add -A`** —— 会把 IDE 配置等垃圾一起提交。
逐文件 `git add`，或者先 `cat .gitignore` 确认已忽略 `.openidea/`、`.idea/`、`.DS_Store`。

**预防**（比事后救火便宜得多）：
**开推之前先拉一次**，养成固定动作：

```bash
git pull --rebase origin main && git push origin main
```

---

---


## 附录：两个只在干净库才暴露的坑

### ① install 报 `No qualifying bean of type ...IdleEnergyService`

**不是数据库问题，是 install 程序的装配范围问题。**

install 用 `ThingsboardInstallApplication`，它的 `@ComponentScan` 只扫建库需要的包。
业务服务新加了对 `service.energy` 的注入却忘了同步扫描范围，Spring 在建库之前就起不来，
日志看起来像「建库失败」。

判据：install 报 bean 找不到 → 看那个 bean 的包在不在 `@ComponentScan` 里；
如果是「bean 在但依赖为 null」→ 把运行时依赖改成 `@Autowired(required = false)`。

### ② install 报 `NoSuchFileException: /opt/energy/data/sql/schema-entities.sql`

部署目录的 `data/sql` 被删了（比如 `rsync --delete` 同步过整个 `data/`）。

```bash
cp -R shiyongshouce/../../../guard-server/src/main/data/sql ~/energy-app/data/sql
ls ~/energy-app/data/sql/*.sql | wc -l    # 必须 8
```

**绝不要用 `rsync --delete` 同步整个 `data/`**：部署侧有源码没有的 `cassandra/`。
用 `scripts/32-check-deploy-sync.sh --fix`，它同步 `json/`、`sql/` 与 `scripts/`
三类，且不会删部署侧多余的文件。

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


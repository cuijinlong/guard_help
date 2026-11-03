# ② 系统部署

从一台空机器，到客户能登录看到数据。**照着走，不用改任何东西。**

只有一种情况需要停下来查别的页：Docker 本身装不上 → [① 安装环境](/admin/install)。

---

## 先看这两行

**这一页 8 步，顺序不能换。** 每步都有一句「看到这个才算成功」——对不上就别往下走。

| 第几步 | 做什么 | 大概多久 |
| --- | --- | --- |
| 第 1 步 | 检查电脑环境 | 10 秒 |
| 第 2 步 | 打 jar（含前端） | 12 分钟 |
| 第 3 步 | 组装部署目录 | 1 分钟 |
| 第 4 步 | 建库 | 2–3 分钟 |
| 第 5 步 | 启动 + 建系统管理员 | 1–2 分钟 |
| 第 6 步 | 建租户 | 1 分钟 |
| 第 7 步 | 建第一个客户 | 1–2 分钟 |
| 第 8 步 | 登录验收 | 2 分钟 |

**开始前记下三个密码，后面每一步都要用：**

| 什么时候设 | 是什么 | 记在哪 |
| --- | --- | --- |
| 第 3 步自动生成 | 数据库密码 | 第 3 步会打印，抄下来 |
| 第 5 步你自己定 | 系统管理员密码 | 自己想一个 |
| 第 6 步你自己定 | 租户管理员密码 | 自己想一个 |

---

## 第 1 步　检查电脑环境

```bash
java -version 2>&1 | head -1
node -v
docker ps > /dev/null 2>&1 && echo "docker 正常" || echo "docker 没起来"
```

**看到这个才算成功**：

```
java version "25..."        ← 必须是 25 或更高
v22.x.x                     ← 18 以上都行
docker 正常
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| java 版本低于 25 | `brew install --cask temurin@25`（macOS） |
| 没有 node | 装 Node 18+ |
| docker 没起来 | 打开 Docker Desktop，等鲸鱼图标不再转 |

---

## 第 2 步　打 jar（含前端）

**在哪执行：仓库根目录**（有 `guard-server/` 和 `shiyongshouce/` 的那一层）

```bash
cd <你的仓库目录>
bash guard-server/pack.sh
```

等 12 分钟左右。它会依次做：构建前端 → 打包后端 → 检查 jar 里有没有前端。

**看到这个才算成功**：

```
✓ 打包成功  用时 12m14s

  JAR : .../guard-server/target/guard-server-4.4.0.jar
  大小: 576M
```

再确认这两行也是 ✓：

```
✓ 内嵌 UI：index.html 存在，public/ 下 10268 个文件
✓ 主类 ThingsboardServerApplication
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `jar 内无 UI` | 前端没打进去。去掉 `--skip-ui` 重跑 |
| 报「需要 JDK 25」 | 回第 1 步 |
| 要连跑第二次 | 只改了 Java：`bash guard-server/pack.sh --skip-ui`（省 4 分钟） |

> 已经打过 jar、这次没改后端代码？**跳过这一步**，直接去第 3 步。

---

## 第 3 步　组装部署目录

**在哪执行：仓库根目录**

```bash
cd <你的仓库目录>
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
```

它把 jar、部件、看板模板、建表 SQL、运维脚本全部装进 `~/energy-app`，并生成数据库密码。

**看到这个才算成功**：

```
第 1 步完成：部署文件已准备好

  部署目录
    /Users/<你>/energy-app

  数据库密码
    ce604943640f7b6c287c992b    ← 抄下来！
```

**马上验证三个数字**：

```bash
ls ~/energy-app/guard-server-4.4.0.jar
ls ~/energy-app/data/json/tenant/dashboards/ | wc -l     # 必须是 30
ls ~/energy-app/data/sql/*.sql | wc -l                   # 必须是 8
```

30 和 8，对不上就是组装漏了东西，回第 2 步确认 jar 存在后重跑。

> **要装到「另一台机器」？** 这一步换成：
> ```bash
> bash shiyongshouce/downloads/deploy/docker-00-prepare.sh --pack
> ```
> 会把同样的东西打成一个 `dist/energy-deploy-<日期>.tar.gz`（约 549MB）。
> 然后传过去解压，再接着做第 4 步：
> ```bash
> scp dist/energy-deploy-*.tar.gz root@<目标机IP>:/opt/
> ssh root@<目标机IP>
> cd /opt && tar -xzf energy-deploy-*.tar.gz && cd energy-deploy
> ```
> 之后第 4–8 步一模一样，只是要把 `~/energy-app` 换成 `/opt/energy-deploy`。

---

## 第 4 步　建库

```bash
cd ~/energy-app
bash docker-01-install.sh
```

建表 + 导入系统部件。等 2–3 分钟。

**看到这个才算成功**（数字由脚本自己算，不是写死的）：

```
✓ install 完成：153 张表 / 744 个部件 / N 个 bundle / N 个用户
```

想确认真的建好了，再查一次：

```bash
docker exec energy-postgres psql -U postgres -d thingsboard -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

输出应该在 **150 上下**（会随版本增加）。**不是 0 就是对的**。

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `库已有 N 张表` | 这台装过了。**不要重来**，直接去第 5 步 |
| `NoSuchFileException: .../sql/schema-entities.sql` | 部署目录不完整，回第 3 步 |

---

## 第 5 步　启动服务 + 建系统管理员

`you@example.com` 和 `'你的密码'` 换成你自己的（密码自己想，先记下来）。

```bash
cd ~/energy-app
bash docker-02-start.sh --admin-email you@example.com --admin-pass '你的密码'
```

起容器 → 等健康 → 建管理员。

**看到这个才算成功**：

```
✓ 管理员已创建
...
✓ Web 入口 8090 正常（经 gateway）
```

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| 卡在「等待服务」超过 3 分钟 | `docker logs energy-server --tail 50` 看日志 |
| `HTTP 000` / 连不上 | 后端还没起来，等 1 分钟重跑同一条命令 |
| `HTTP 502/503` | 同上 |

> 内存小于 10GB 的机器（笔记本、演示机），加 `--allinone` 用单容器模式，省约 2GB。

---

## 第 6 步　建租户

**为什么单独一步**：平台没有默认租户，系统管理员不能直接建客户（会 403）。

`you@example.com` / `'你的密码'` 用**第 5 步刚设的**系统管理员。

```bash
cd ~/energy-app
bash scripts/02-onboard.sh \
  --admin you@example.com --admin-pass '你的密码' \
  --tenant '某某集团' \
  --tenant-email tenant@example.com --tenant-pass '租户密码'
```

租户邮箱和密码自己想（**必填**，少了脚本会拒绝）。

**这一步会自动记下凭据**，写到 `~/energy-app/DEPLOY-CREDENTIALS.txt`（权限 600）：

```
租户管理员     tenant@example.com / 租户密码
租户名称       某某集团
```

第 7 步建客户时，`09-onboard-customer.sh` 会**自动从这里读**，不用再手传。
所以你现在不用抄任何东西。

**看到这个才算成功**（最后一行）：

```
✓ 全部验证通过
```

前面还应该有这几行：

```
✓ 能源参数字典：1 个
✓ 系统部件：7xx 个
✓ 四个维度根齐全
```

中间还会看到：

```
凭据已写入 /Users/xxx/energy-app/scripts/../DEPLOY-CREDENTIALS.txt（权限 600）
建客户时不用再手传 --tenant-email / --tenant-pass
```

> **为什么需要这个文件（2026-11-04 实测）**
>
> `09-onboard-customer.sh` 建客户时必须用租户管理员身份（系统管理员直接建客户会被 TB 403）。
> 它默认去读 `../DEPLOY-CREDENTIALS.txt`，而原来**只有 `docker-98-rebuild.sh` 会写这个文件** ——
> 主线的 01/02 都不写。于是全新机器上跑到第 7 步直接失败：
> ```
> 读不到租户管理员凭据。要么在部署目录放 DEPLOY-CREDENTIALS.txt，
> 要么显式传：--tenant-email xxx@yyy.com --tenant-pass '密码'
> ```
> 客户必须手抄一遍密码才能往下走，抄错一个字符就建不出来。
> 已修：`02-onboard.sh` 建完租户后自动落盘。

---

## 第 7 步　建第一个客户

```bash
cd ~/energy-app
bash scripts/09-onboard-customer.sh \
  --email customer@example.com --password 'Cust@123456' \
  --name '某某厂区'
```

**不用传租户凭据** —— 第 6 步已经写进 `DEPLOY-CREDENTIALS.txt`，本脚本自动读。

它会：建客户 → 建客户管理员 → 铺演示数据 → 装菜单 → 复制看板 → 逐项验证。

**这一步会卡 60–120 秒**（要铺 33 天遥测），不是死了。

**看到这个才算成功**（最后一块）：

```
============================================================
  客户已开通
============================================================

 登录地址   http://127.0.0.1:8090
 账号       customer@example.com
 密码       Cust@123456
 客户名     某某厂区
 客户 ID    xxxxxxxx-xxxx-...
```

中间应该都是 `✓ 设备档案：N`、`✓ 落地页（菜单第一项是 home）` 这类逐项检查。
任何一行打 `✗`，脚本会停下来并报「有验证失败项」。

同时会在部署目录写 `ONBOARDED-<客户id>.txt`（权限 600）。

不对怎么办：

| 现象 | 怎么办 |
| --- | --- |
| `读不到租户管理员凭据` | 第 6 步没跑或没传 `--tenant-email`/`--tenant-pass`。回第 6 步，或手动补：`--tenant-email tenant@example.com --tenant-pass '租户密码'` |
| `timed out` | 客户其实建好了。等 1 分钟重跑同一条命令（幂等） |

---

## 第 8 步　登录验收

浏览器打开 `http://<这台机器的IP>:8090`，用**第 7 步的客户账号**登录。

**看到这个才算成功**：

1. 左侧是**业务菜单**（能耗概览 / 能耗查询 / 设备管理 / 电能质量…），不是 TB 原生那套（仪表板 / 告警 / 实体）
2. 点「设备管理 → 设备运维」：能看到设备卡片网格，顶部有 `设备管理 > 设备运维` 面包屑
3. 点「平台自检」：逐项通过

**只有本机能访问？** 云服务器或别的电脑打不开，是防火墙没放行：

```bash
# Ubuntu / Debian
sudo ufw allow 8090/tcp
# CentOS / RHEL
sudo firewall-cmd --add-port=8090/tcp --permanent && sudo firewall-cmd --reload
```

云服务器还要在控制台安全组放行 8090。放行方法见本页末尾「附录：出问题时查」的第一节。

---

## 装完了，收个尾

```bash
# 部署目录里的临时备份，留最近一份
cd ~/energy-app/data && ls -dt json.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf
cd ~/energy-app && ls -dt scripts.bak.* 2>/dev/null | tail -n +2 | xargs -r rm -rf

# 旧 jar 备份，留一份
cd ~/energy-app && ls -t guard-server-4.4.0.jar.bak-* 2>/dev/null | tail -n +2 | xargs -r rm -v

# 旧发布包，留一个
cd <你的仓库目录> && ls -t dist/energy-deploy-*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -v
```

**部署目录 `~/energy-app` 不要删** —— 以后升级、查日志、跑运维脚本都要用。

---

# 以下是维护场景，不是部署

上面 8 步做完就不用看了。下面三段是「以后要改东西」时用的。

## A　就地升级（已经装好，只想换版本）

不动数据、不动 `.env`，只换 jar 和物料。

```bash
# ① 在仓库里，把新物料同步进部署目录（会先备份）
cd <你的仓库目录>
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix

# ② 打 jar（只改了 Java 就加 --skip-ui）
bash guard-server/pack.sh --skip-ui

# ③ 换 jar 重启
docker stop energy-server
cd ~/energy-app && mv guard-server-4.4.0.jar guard-server-4.4.0.jar.bak-$(date +%H%M)
cp <你的仓库目录>/guard-server/target/guard-server-4.4.0.jar ~/energy-app/
docker start energy-server

# ④ 等健康
for i in $(seq 1 50); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8090/ 2>/dev/null)
  [ "$code" = "200" ] && { echo "就绪（第 ${i} 次）"; break; }
  sleep 3
done
```

**判据**：打印 `就绪`；`docker logs energy-server --since 3m | grep -iE "ERROR|Exception"` 无输出。

## B　只改了部件 / 脚本（最轻，不用重启）

改了 `widget_types/*.json`、看板模板、运维脚本 —— **不用打 jar，不用重启**。

部件是运行时从数据库读的，跟 jar 无关。很多人改完部件就跑 `pack.sh`，白等 12 分钟。

```bash
cd <你的仓库目录>

# ① 文件同步进部署目录
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix

# ② 部件 JSON 还要写进数据库（存量库的 widget_type 记录）
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all
```

浏览器硬刷新即可。

两者分工：

| 脚本 | 干什么 | 写数据库 | 什么时候用 |
| --- | --- | --- | --- |
| `32-check-deploy-sync.sh --fix` | 三类文件比对 + 同步 | ✗ | 改了 json / sql / 脚本 |
| `31-deploy-widget.sh <名>` | 推库 + 同步挂载目录 | ✓ | 存量库改部件 |

> 两个都**必须从仓库跑**。从 `~/energy-app/scripts` 跑时，`32` 会拒绝（拿自己比自己永远报一致）。

## C　彻底重来（数据全不要了）

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --dry-run   # 先看会删什么
bash docker-99-uninstall.sh --purge --yes       # 真删
```

删容器 + 卷 + 网络 + 整个 `~/energy-app` 目录。**不可恢复。**

删完从本页最上面的**第 1 步**重新走。

> **删完立刻跑物料校验会报「目录不存在」—— 这是正常的**，不是错误。
> 说明这台机器现在是空的，直接从第 2 步（或第 3 步，jar 还在的话）开始。

---

# 附录：出问题时查

## 放行防火墙

容器端口映射只管**宿主机本机**。别的电脑访问、或云服务器，还要放行：

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

> macOS 本机不需要放行。但首次启动 Docker Desktop 会弹「是否允许接受传入网络连接」，
> **必须点允许**。误点了拒绝：系统设置 → 网络 → 防火墙 → 选项，把 Docker 加回来。

## 内存紧张：单容器模式

物理内存 < 10GB，把四个容器合成一个，省约 2GB：

```bash
cd ~/energy-app
bash docker-02-start.sh --allinone --admin-email ... --admin-pass ...
```

代价是「重启一个全部重启」。演示机、笔记本推荐；生产用默认四容器。

## 验收基线（装对了应该是什么样）

| 检查项 | 应有值 |
| --- | --- |
| 库表 | 150 上下（`SELECT count(*) FROM information_schema.tables WHERE table_schema='public'`） |
| 系统部件（install 后 DB 行数） | 740 上下 |
| 交付的部件文件 | 584 个 |
| 客户看板模板 | 30 个 |
| 建表 SQL | 8 个 |
| 能源参数字典 | 1 个资产，标准 key **137** 个（电能 122） |
| 演示客户 | 10 台设备（8 台可模拟） |

## 两个「等很久」是正常的

**① 建客户阻塞 60–120 秒** —— 同步铺场站、分项、二十多台设备、约一个月的遥测。
`09` 已把超时放宽到 600 秒。看到 `timed out` 说明客户其实建好了，等 1 分钟重跑（幂等）。

**② 首次 `install` 2–3 分钟** —— 建 150 上下张表 + 导入 740 上下个部件。机器慢会到 5 分钟。

## 三个会让你翻车的坑

### 坑 1：只 `git pull` 不 build → 源码新的、界面旧的

`ui-ngx/target/` 在 `.gitignore` 里，**前端产物不进版本控制**。
pull 之后不跑 `pack.sh`，浏览器里就是上一次构建的界面。

**判据**：`ls -la ui-ngx/target/generated-resources/public/index.html` 的时间
必须**晚于**最后一次改 `ui-ngx/src` 的时间。

**修**：跑 `bash guard-server/pack.sh`。

### 坑 2：改了源码，忘了同步部署目录 → 物料旧

部署侧读 `~/energy-app/data`，源码改的是 `guard-server/src/main/data`。**不会自动同步。**

**判据**：`bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app` 全绿。

**修**：加 `--fix`，或重新跑第 3 步（`docker-00-prepare.sh --force`）。

### 坑 3：新机器用了旧脚本 → 静默退出

旧版 `docker-02-start.sh` 里是 `CODE=$(curl ...)`，而脚本有 `set -euo pipefail`。
新机器上服务刚起来、curl 连不上时**赋值语句整体非零 → 脚本静默退出**，
只看到「服务已就绪」然后就没了，管理员没建成。

**判据**：`grep -c 'CODE="000"' ~/energy-app/docker-02-start.sh` 必须 ≥ 1。

**修**：`32-check-deploy-sync.sh --fix`（把新脚本同步过去）。

## 两台电脑同时改同一个仓库

`git pull --rebase --autostash` 会把未提交改动临时 stash 起来，
**冲突时静默留在 `stash@{0}`**，工作区看起来「变回旧版」。

```bash
git stash list
git stash show -p stash@{0} | head -40
```

但**大多数「代码变旧了」不是这个原因**，按这个顺序查：

1. 这一屏由谁渲染？菜单 `linkType` 是 `DASHBOARD`（部件）还是 `URL`（Angular 路由）
2. 前端产物时间 vs `ui-ngx/src` 时间（坑 1）
3. `32-check-deploy-sync.sh` 是否全绿（坑 2）
4. 最后才怀疑 git：`git reflog` / `git stash list` / `git fsck --lost-found`

详见[⑨ 排障](/admin/troubleshoot)。

## 推送手册被拒（`! [rejected] main -> main (fetch first)`）

不是权限问题，不是网络问题。含义：**远端有你本地没有的提交。**

```bash
cd /Users/<你>/Documents/workspace/guard_help
git fetch origin
git log --oneline HEAD..origin/main      # 远端有、你没有

git pull --rebase origin main            # 拉平（保留你的提交）
git push origin main
```

冲突了（`UU` 标记）**不要直接 `--ours/--theirs`**，先判断能不能丢内容：

```bash
git merge-base <远端提交> <你的提交>
git diff <远端提交> <你的提交> -- <冲突文件> | grep '^-'
#   ↑ 输出为空 = 你的版本已包含远端全部内容，取你的版本安全

git show <你的提交>:<冲突文件> > <冲突文件>
git add <冲突文件> && git rebase --continue
```

**预防**：开推之前先拉一次 —— `git pull --rebase origin main && git push origin main`

## 附录：两个只在干净库才暴露的坑

### ① install 报 `No qualifying bean of type ...IdleEnergyService`

只在**全新空库**出现。原因是 `@PostConstruct` 早于 bean 就绪。

**修**：已在 2026-10-29 修（`EnergyBootstrapInstaller` 改为懒加载）。若仍遇到，说明用了旧 jar。

### ② install 报 `NoSuchFileException: /opt/energy/data/sql/schema-entities.sql`

`schema-entities.sql` 不在部署目录的 `data/sql/` 下。

**原因**：`docker-00-prepare.sh` 漏拷，或手工拼的部署目录。

**修**：重跑第 3 步。验：`ls ~/energy-app/data/sql/*.sql | wc -l` 必须是 8。

---

## 一页速查

```bash
# ── 部署（8 步）──────────────────────────────
cd <仓库>
bash guard-server/pack.sh                                       # 2. 打 jar（12 分钟）
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh        # 3. 组装（记下 DB 密码）
cd ~/energy-app
bash docker-01-install.sh                                       # 4. 建库
bash docker-02-start.sh --admin-email you@x.com --admin-pass '密码'   # 5. 启动
bash scripts/02-onboard.sh --admin you@x.com --admin-pass '密码' \
     --tenant '某某集团' --tenant-email t@x.com --tenant-pass '密码'  # 6. 建租户（必填，会写凭据文件）
bash scripts/09-onboard-customer.sh --email c@x.com --password '密码' \
     --name '某某厂区'                                              # 7. 建客户（凭据自动读）
# 8. 浏览器 http://<IP>:8090 用客户账号登录

# ── 装到另一台机器 ────────────────────────────
# 第 3 步改成 --pack，然后 scp 过去解压，其余相同

# ── 只改部件 / 脚本（不用打 jar）──────────────
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app --fix
bash shiyongshouce/downloads/scripts/31-deploy-widget.sh --all

# ── 唯一一个「一切正常」的信号（部署目录存在时）──
bash shiyongshouce/downloads/scripts/32-check-deploy-sync.sh --app ~/energy-app
# → ✓ 部署物料与源码一致，可以 install / 打包
```

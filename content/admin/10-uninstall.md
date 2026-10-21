# 卸载与重置

> 两种模式：**保留数据**（可随时再起）和**彻底删除**（不留痕）。脚本自检五项，全空才算干净。
>
> 本页只删**本平台**，Docker 本身保留给其他项目用。
> 要把 Docker 也卸掉，见[Docker 安装与运维](/admin/docker-ops) 第八节。
> 裸机部署的卸载见[裸机部署](/admin/baremetal) 最后一节。

## 先确认你的部署目录

卸载脚本必须**在部署目录里执行**（它要读同目录的 `.env` 和 `docker-compose.yml`）。

| 部署方式 | 部署目录 |
| --- | --- |
| 本机部署 | `~/energy-app` |
| 服务器部署 | `/opt/energy-deploy`（或你解压到的目录） |

不确定就先找：

```bash
ls ~/energy-app/docker-compose.yml 2>/dev/null && echo "本机：~/energy-app"
ls /opt/energy-deploy/docker-compose.yml 2>/dev/null && echo "服务器：/opt/energy-deploy"
```

## 一、只停服务（保留数据）

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app            # 服务器上改成 cd /opt/energy-deploy
bash docker-99-uninstall.sh
```

**预计输出**：

```
[16:06:12] 停止服务（保留数据卷，可随时再启动）
  ✓ 已停止。数据仍在卷 energy-pgdata 与 /Users/你/energy-app/data
   重新启动：bash docker-02-start.sh
   彻底删除：bash docker-99-uninstall.sh --purge
```

停了什么：容器 `energy-server`、`energy-postgres` 被删除。
保留什么：数据库卷 `energy-pgdata`、部署目录、jar、data、日志。

再启动（同一目录）：

```bash
cd ~/energy-app
bash docker-02-start.sh
```

数据和账号都在，直接可用。

## 二、彻底删除（不留痕）

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge
```

会要求输入大写 `YES` 确认：

```
  ! 即将彻底删除以下内容，不可恢复：
   · 容器 energy-server / energy-postgres
   · 数据卷 energy-pgdata（数据库全部数据）
   · 网络 energy_default
   · 目录 /Users/你/energy-app（jar、data、日志）

确认请输入大写 YES：
```

无人值守（CI 或确定不要了）：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes
```

**预计输出**：

```
[16:06:50] 删除容器、网络、卷
[16:07:02] 删除部署目录 /Users/你/energy-app

[16:07:04] 卸载自检
  ✓ 容器：无残留
  ✓ 卷：无残留
  ✓ 网络：无残留
  ✓ 端口 8090：无残留
  ✓ 目录：已删除

  ✓ 卸载完成，无残留
```

> 脚本执行到最后会把自己的目录删掉，所以提示符之后 `cd` 会失效，属正常。回到上级目录即可：`cd ~`。

## 三、镜像删不删（节省二次部署时间）

镜像清理是独立开关，**默认一个都不删**。

```bash
cd ~/energy-app

# 保留全部镜像（最快再部署：自建镜像重建要 5-20 分钟）
bash docker-99-uninstall.sh --purge --yes --images=none

# 只删自建镜像（energy/ngxai-backend、energy/allinone）
bash docker-99-uninstall.sh --purge --yes --images=app

# 连公共基础镜像一起删（postgres、nginx、temurin、python、node）
bash docker-99-uninstall.sh --purge --yes --images=all
```

三个选项怎么选：

| 场景 | 建议 |
| --- | --- |
| 马上要重装 / 只是改配置重来 | `--images=none` |
| 不再用这个项目，但机器上还有别的 Docker 项目 | `--images=app` |
| 完全清理这台机器 | `--images=all` |

**为什么默认保留**：

- `energy/ngxai-backend` 要 pip 装依赖 + 编译 Stan，重建 5–10 分钟
- `energy/allinone` 更大，重建 10–20 分钟
- `postgres:16-alpine` / `nginx` / `temurin` 常被其他项目复用，删了会影响别人

如果提示「仍被其他项目使用，已跳过」，说明确实有别的容器依赖它，跳过是正确行为。

## 四、自己再验一遍（可选）

**在哪执行：【部署机 · 任意目录】**（此时部署目录已删，不能再 cd 进去）

```bash
# 1. 容器（应无输出）
docker ps -a --format '{{.Names}}' | grep energy

# 2. 卷（应无输出）
docker volume ls --format '{{.Name}}' | grep energy

# 3. 网络（应无输出）
docker network ls --format '{{.Name}}' | grep energy

# 4. 目录（应提示不存在）
ls -d ~/energy-app

# 5. 端口（应提示已释放）
curl -s --noproxy '*' -m 3 http://127.0.0.1:8090/ >/dev/null && echo '仍在监听' || echo '已释放'
```

五条都为空或提示「不存在/已释放」，才算真正干净。

## 五、清理磁盘（构建缓存）

卸载后磁盘没释放多少，是因为 Docker 的**构建缓存**不会被 `down -v` 碰到，也不会自动回收。

```bash
docker system df          # 先看占用
docker builder prune -f   # 只清构建缓存（最安全）
docker image prune -f     # 再清悬空镜像
```

⚠️ `docker system prune -a --volumes -f` 会删除未使用的命名卷，数据库可能一并丢失，别顺手用。

完整的清理策略、容器日志轮转、`data-root` 迁移见[Docker 安装与运维](/admin/docker-ops) 第八节。

## 六、重置数据但不删目录

适合「库脏了，想从干净库重来」，但**不换版本**。

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

docker compose down -v          # 删容器和数据卷，保留目录与 jar
rm -f .env                      # 下一步会重新生成密码与端口

bash docker-01-install.sh       # 重新建库（.env 缺失时自动生成）
bash docker-02-start.sh --admin-email admin@your.com --admin-pass '新密码'
```

> ⚠️ **这一节不会让你升级到新版本。**
> 它保留目录里的 `guard-server-4.4.0.jar` 和 `data/` 原样 —— 如果它们是旧版，
> 重新建库后跑的还是旧功能：能源字典、厂商型号、新仪表板照样没有。
>
> 想换成新版本，走[部署手册的「更新到新版本」](02-deploy.md)，
> 那里的路 A 会先卸载、再从仓库重新生成部署目录。

**怎么判断自己需不需要换版本**：

```bash
cd ~/energy-app
ls data/json/tenant/dashboards/ | wc -l
```

- 输出 `22` → 目录已是新版，本节流程够用
- 输出 `6` 或更少 → 目录是旧版，必须先换文件，否则重置多少次都一样

## 七、脚本拒绝执行的情况

脚本拒绝删除这些目录，防止 `APP_HOME` 配错造成误删：

```
/   /opt   /usr   /etc   /var   /home   $HOME
```

如果 `APP_HOME` 填成了 `/opt`（只写了父目录），先修正 `.env` 再执行。

## 八、残留排查

极少数情况下 `down -v` 没删干净（比如容器曾被 `docker run` 手工创建）：

```bash
# 列出所有带 energy 前缀的资源
docker ps -a --filter name=energy
docker volume ls --filter name=energy
docker network ls --filter name=energy

# 逐个删
docker rm -f $(docker ps -aq --filter name=energy)
docker volume rm $(docker volume ls -q --filter name=energy)
docker network rm $(docker network ls -q --filter name=energy)
```

Linux 上如果提示卷「in use」，说明还有容器挂着它，先删容器再删卷。

---

## 还要卸载 Docker 本身？

本页的脚本只删本平台的项目资源（容器、卷、网络、镜像），Docker 引擎和其他项目不受影响。

如果这台机器不再需要 Docker：

```bash
# Ubuntu / Debian
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd

# CentOS / Rocky
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
```

⚠️ 这会删掉**所有**项目的镜像与卷。完整步骤（含卸载前检查、验证、重装）见
[Docker 安装与运维](/admin/docker-ops) 第八节。

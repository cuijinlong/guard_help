# 卸载与重置

> 两种模式：**保留数据**（可随时再起）和**彻底删除**（不留痕）。脚本自检五项，全空才算干净。
>
> 本页针对 Docker 部署。裸机部署的卸载见[方案 C](/admin/baremetal) 最后一节。

## 先确认你的部署目录

卸载脚本必须**在部署目录里执行**（它要读同目录的 `.env` 和 `docker-compose.yml`）。

| 部署方式 | 部署目录 |
| --- | --- |
| 方案 A · 本机 | `~/energy-app` |
| 方案 B · 服务器 | `/opt/energy-deploy`（或你解压到的目录） |

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

## 三、连镜像一起删

默认**不删** `postgres:16-alpine` 和 `eclipse-temurin:25-jre` —— 可能被别的项目在用。确实要清理时：

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes --purge-images
```

如果提示「仍被其他容器使用，已跳过」，说明有别的项目依赖它，跳过是正确行为。

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

## 五、重置而不卸载（想清空数据重来）

不删目录，只把数据库清空：

**在哪执行：【部署机 · 部署目录】**

```bash
cd ~/energy-app

docker compose down -v          # 删容器和数据卷，保留目录与 jar
rm -f .env                      # 让下一步重新生成密码与端口

bash docker-01-install.sh       # 重新建库（会自动生成新 .env）
bash docker-02-start.sh --admin-email admin@example.com --admin-pass '新密码'
```

这比完整卸载快，适合反复验证初始化流程。

## 六、脚本拒绝执行的情况

脚本拒绝删除这些目录，防止 `APP_HOME` 配错造成误删：

```
/   /opt   /usr   /etc   /var   /home   $HOME
```

如果 `APP_HOME` 填成了 `/opt`（只写了父目录），先修正 `.env` 再执行。

## 七、残留排查

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

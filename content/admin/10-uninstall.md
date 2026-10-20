# 卸载与重置

> 两种模式：**保留数据**（可随时再起）和**彻底删除**（不留痕）。卸载脚本会自检六项，全部为空才算干净。

## 一、只停服务（保留数据）

```bash
cd /opt/energy-app
bash docker-99-uninstall.sh
```

**预计输出**：

```
[16:06:12] 停止服务（保留数据卷，可随时再启动）
  ✓ 已停止。数据仍在卷 energy-pgdata 与 /opt/energy-app/data
   重新启动：bash docker-02-start.sh
   彻底删除：bash docker-99-uninstall.sh --purge
```

停了什么：容器 `energy-server`、`energy-postgres` 被删除。
保留什么：数据库卷 `energy-pgdata`、部署目录、jar、data、日志。

再启动：

```bash
bash docker-02-start.sh
```

数据和账号都在，直接可用。

## 二、彻底删除（不留痕）

```bash
bash docker-99-uninstall.sh --purge
```

会要求输入大写 `YES` 确认：

```
  ! 即将彻底删除以下内容，不可恢复：
   · 容器 energy-server / energy-postgres
   · 数据卷 energy-pgdata（数据库全部数据）
   · 网络 energy_default
   · 目录 /opt/energy-app（jar、data、日志）

确认请输入大写 YES：
```

脚本化执行（不再询问）：

```bash
bash docker-99-uninstall.sh --purge --yes
```

**预计输出**：

```
[16:06:50] 删除容器、网络、卷
[16:07:02] 删除部署目录 /opt/energy-app

[16:07:04] 卸载自检
  ✓ 容器：无残留
  ✓ 卷：无残留
  ✓ 网络：无残留
  ✓ 端口 8090：无残留
  ✓ 目录：已删除

  ✓ 卸载完成，无残留
```

## 三、连镜像一起删

默认**不删** `postgres:16-alpine` 和 `eclipse-temurin:25-jre` —— 它们可能被别的项目在用。确实要一起清理时：

```bash
bash docker-99-uninstall.sh --purge --yes --purge-images
```

如果提示「仍被其他容器使用，已跳过」，说明有别的项目依赖它，跳过是正确行为。

## 四、自己再验一遍（可选）

不依赖脚本，手工确认没有任何残留：

```bash
# 1. 容器
docker ps -a --format '{{.Names}}' | grep energy

# 2. 卷
docker volume ls --format '{{.Name}}' | grep energy

# 3. 网络
docker network ls --format '{{.Name}}' | grep energy

# 4. 镜像（只有加过 --purge-images 才会为空）
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'postgres:16-alpine|eclipse-temurin:25-jre'

# 5. 目录
ls -d /opt/energy-app

# 6. 端口
curl -s --noproxy '*' -m 3 http://127.0.0.1:8090/ >/dev/null && echo '仍在监听' || echo '已释放'
```

六条命令输出都为空（或提示"不存在/已释放"），才算真正干净。

## 五、重置而不卸载（想换个密码重来）

不想删目录，只想把数据库清空重来：

```bash
docker compose down -v          # 删容器和数据卷，保留目录与 jar
bash docker-01-install.sh       # 重新建库
bash docker-02-start.sh --admin-email admin@example.com --admin-pass '...'
```

这比完整卸载快，适合反复验证初始化流程。

## 六、卸载脚本拒绝执行的情况

脚本会拒绝删除这些目录，防止 `APP_HOME` 配错造成误删：

```
/  /opt  /usr  /etc  /var  /home  $HOME
```

如果 `APP_HOME` 填成了 `/opt`（只写了父目录），先修正 `.env` 再执行。

## 七、残留排查

极少数情况下 `down -v` 没删干净（比如容器被 `docker run` 手工创建过）：

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

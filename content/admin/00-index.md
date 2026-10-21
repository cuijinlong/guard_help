# 运维手册

> 六页，按顺序看就行。第一次部署只需要看前三页。

## 部署上线（第一次做）

| 页 | 内容 | 什么时候看 |
| --- | --- | --- |
| [① Docker](/admin/docker) | 安装、调优、日常清理、卸载 Docker | 机器上还没有 Docker |
| [② 平台部署](/admin/deploy) | 4 条命令装完平台；卸载也在这页 | 部署平台、升级、重装 |
| [③ 数据初始化](/admin/init) | 用户、字典、字段、菜单、演示数据；验和补 | 装完要确认数据齐不齐 |

## 接入现场（客户要连设备）

| 页 | 内容 |
| --- | --- |
| [④ 设备接入](/admin/device-access) | RTU/网关怎么上报；HTTP 与 MQTT；字段格式；三条铁律 |

## 出问题时

| 页 | 内容 |
| --- | --- |
| [⑤ 常见问题](/admin/troubleshoot) | 登录失败、报表空白、上报不通、磁盘满、密码重置 |

---

## 三条最短路径

### 全新部署（约 15 分钟）

```bash
# 1. 装 Docker（已装可跳过）
#    见 ① Docker 第一节

# 2. 部署平台
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-00-prepare.sh
cd ~/energy-app
bash docker-01-install.sh
bash docker-02-start.sh --admin-email langmen@126.com --admin-pass 'CJLqh@163'

# 3. 初始化数据（用户/字典/菜单/演示数据一次到位）
bash scripts/02-onboard.sh \
  --base http://127.0.0.1:8090 \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant "环宇能源集团" \
  --tenant-email tenant@126.com --tenant-pass '12345678' \
  --customer "星河工业园" \
  --customer-email customer@126.com --customer-pass '12345678'
```

### 改了代码要更新（约 6 分钟）

```bash
cd /你的路径/iot-rule-engine
bash shiyongshouce/downloads/deploy/docker-98-rebuild.sh \
  --admin langmen@126.com --admin-pass 'CJLqh@163' \
  --tenant tenant@126.com --tenant-pass '12345678' --tenant-title '环宇能源集团' \
  --customer customer@126.com --customer-pass '12345678' --customer-title '星河工业园' \
  --yes
```

### 彻底卸载

```bash
cd ~/energy-app
bash docker-99-uninstall.sh --purge --yes --images=none
docker builder prune -f        # 再清构建缓存
```

---

## 账号

装完后有三个账号，权限从高到低：

| 账号 | 密码 | 能做什么 |
| --- | --- | --- |
| `langmen@126.com` | `CJLqh@163` | 系统管理员：建租户、改平台设置 |
| `tenant@126.com` | `12345678` | 租户管理员：能源服务商，管全部客户 |
| `customer@126.com` | `12345678` | 客户用户：只看自己场站的设备与报表 |

> 正式上线前换成自己的邮箱和强密码。改密码后要同步改脚本参数。

---

## 客户怎么用

面向客户的说明在[客户使用手册](/user/index)：怎么登录、怎么看报表、
怎么换成自己的数据。给客户交付时发那个，不用发这一份。

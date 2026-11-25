<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设置 / 邮件服务器

> 菜单位置：运维管理 / 租户 / 运营配置 / 设置 / 邮件服务器

> 页面路径：`/settings/outgoing-mail`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `mail_server` |
| 路径 | `/settings/outgoing-mail` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 邮件服务器配置

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT key AS 配置项, left(json_value, 200) AS 值
FROM admin_settings WHERE key = 'mail';
SQL
```

**本机实测结果**（前 1 行）：

| 配置项 | 值 |
| --- | --- |
| mail | {"mailFrom":"ThingsBoard <sysadmin@localhost.localdomain>","smtpProtoc |

**判据**：通知发不出去时先看这里（密码是加密存储的，看不到明文）。

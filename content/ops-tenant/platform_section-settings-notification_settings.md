<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设置 / 通知

> 菜单位置：运维管理 / 租户 / 运营配置 / 设置 / 通知

> 页面路径：`/settings/notifications`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_settings` |
| 路径 | `/settings/notifications` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 通知相关配置项

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT key AS 配置项, left(json_value, 120) AS 值
FROM admin_settings
WHERE key ILIKE '%notification%' OR key ILIKE '%mail%';
SQL
```

**本机实测结果**（前 1 行）：

| 配置项 | 值 |
| --- | --- |
| mail | {"mailFrom":"ThingsBoard <sysadmin@localhost.localdomain>","smtpProtoc |

**判据**：0 行 = 全用默认值。通知发不出先查邮件服务器。

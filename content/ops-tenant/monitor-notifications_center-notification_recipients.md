<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 收件人

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 收件人

> 页面路径：`/notification/recipients`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_recipients` |
| 路径 | `/notification/recipients` |
| 数据表 | `notification_target`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 收件人组

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 收件人组, left(configuration::text, 100) AS 配置
FROM notification_target
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY name;
SQL
```

**本机实测结果**（前 4 行）：

| 收件人组 | 配置 |
| --- | --- |
| Affected user | {"type":"PLATFORM_USERS","description":"If rule trigger is an action t |
| All users | {"type":"PLATFORM_USERS","description":"All users in scope of the tena |
| Tenant administrators | {"type":"PLATFORM_USERS","description":"Tenant administrators","usersF |
| Users of the entity owner | {"type":"PLATFORM_USERS","description":"In case trigger entity (e.g. c |

**判据**：规则里引用的收件人组必须在这里存在，否则通知发不出去。

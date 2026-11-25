<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 规则

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 规则

> 页面路径：`/notification/rules`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_rules` |
| 路径 | `/notification/rules` |
| 数据表 | `notification_rule`、`notification_template`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 通知规则与启用状态

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT r.name AS 规则, r.enabled AS 启用, r.trigger_type AS 触发类型,
       t.name AS 模板, left(r.recipients_config::text, 80) AS 收件配置
FROM notification_rule r
LEFT JOIN notification_template t ON t.id = r.template_id
WHERE r.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY r.enabled DESC, r.name;
SQL
```

**本机实测结果**（前 8 行）：

| 规则 | 启用 | 触发类型 | 模板 | 收件配置 |
| --- | --- | --- | --- | --- |
| Alarm assignment | t | ALARM_ASSIGNMENT | Alarm assigned notification | {"targets":["75743d00-d2bd-11f1-b794-31725d9e3862"],"triggerType":"ALA |
| Alarm update | t | ALARM | Alarm update notification | {"escalationTable":{"0":["75706c70-d2bd-11f1-b794-31725d9e3862"]},"tri |
| Comment on active alarm | t | ALARM_COMMENT | Alarm comment notification | {"targets":["75706c70-d2bd-11f1-b794-31725d9e3862"],"triggerType":"ALA |
| Device created | t | ENTITY_ACTION | Entity action notification | {"targets":["75706c70-d2bd-11f1-b794-31725d9e3862"],"triggerType":"ENT |
| Edge communication failure | t | EDGE_COMMUNICATION_FAILURE | Edge communication failure notification | {"targets":["75706c70-d2bd-11f1-b794-31725d9e3862"],"triggerType":"EDG |
| Edge connection status change | t | EDGE_CONNECTION | Edge connection notification | {"targets":["75706c70-d2bd-11f1-b794-31725d9e3862"],"triggerType":"EDG |
| Integration start failure | t | INTEGRATION_LIFECYCLE_EVENT | Integration start failure notification | {"targets":["75706c70-d2bd-11f1-b794-31725d9e3862"],"triggerType":"INT |
| New alarm | t | ALARM | New alarm notification | {"escalationTable":{"0":["75706c70-d2bd-11f1-b794-31725d9e3862"]},"tri |

**判据**：只有 `enabled=true` 的规则会发通知；模板为空则规则不生效。

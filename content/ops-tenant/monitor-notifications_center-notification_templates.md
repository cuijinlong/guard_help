<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 模板

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 模板

> 页面路径：`/notification/templates`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_templates` |
| 路径 | `/notification/templates` |
| 数据表 | `notification_template`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 通知模板

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 模板, notification_type AS 类型, external_id
FROM notification_template
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY name;
SQL
```

**本机实测结果**（前 8 行）：

| 模板 | 类型 | external_id |
| --- | --- | --- |
| Alarm assigned notification | ALARM_ASSIGNMENT |  |
| Alarm comment notification | ALARM_COMMENT |  |
| Alarm update notification | ALARM |  |
| Device activity notification | DEVICE_ACTIVITY |  |
| Edge communication failure notification | EDGE_COMMUNICATION_FAILURE |  |
| Edge connection notification | EDGE_CONNECTION |  |
| Entity action notification | ENTITY_ACTION |  |
| Integration start failure notification | INTEGRATION_LIFECYCLE_EVENT |  |

**判据**：模板被打断（变量写错）时通知内容会是空白，但发送记录仍然成功。

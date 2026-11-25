<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 仪表板 / 全部

> 菜单位置：运维管理 / 租户 / 监控 / 仪表板 / 全部

> 页面路径：`/dashboards/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `dashboard_all` |
| 路径 | `/dashboards/all` |
| 数据表 | `customer`、`dashboard`、`jsonb_object_keys`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 全部看板（含共享给客户的）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT d.title AS 看板,
       coalesce(c.title, '—') AS 所属客户,
       d.assigned_customers AS 共享客户,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d
LEFT JOIN customer c ON c.id = d.customer_id
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
ORDER BY d.created_time DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 看板 | 所属客户 | 共享客户 | 部件数 |
| --- | --- | --- | --- |
| 电能质量 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |
| 某市热力 · 二号换热站组态 | 平台演示中心 | [] | 24 |
| 客户诊断报告 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 3 |
| 用能质量 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |
| 用能建议 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |
| 告警事件 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |
| 设备拓扑 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |
| 设备分组 | — | [{"title": "平台演示中心", "public": false, "customerId": {"id": "7ce48900-d | 1 |

**判据**：列表里的看板数与「仪表板 → 全部」页一致；部件数 0 的看板打开是空的。

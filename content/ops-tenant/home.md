<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 租户 / 首页

> 菜单位置：运维管理 / 租户 / 首页

> 页面路径：`/home`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `home` |
| 路径 | `/home` |
| 数据表 | `dashboard`、`jsonb_object_keys`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 租户下的看板（首页就是其中指定的一块）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT d.title AS 看板, d.created_time,
       (SELECT count(*) FROM jsonb_object_keys(d.configuration::jsonb->'widgets')) AS 部件数
FROM dashboard d
WHERE d.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
ORDER BY d.created_time DESC LIMIT 10;
SQL
```

**本机实测结果**（前 8 行）：

| 看板 | created_time | 部件数 |
| --- | --- | --- |
| 电能质量 | 1794460525793 | 1 |
| 某市热力 · 二号换热站组态 | 1794405062496 | 24 |
| 客户诊断报告 | 1794246353540 | 3 |
| 用能质量 | 1794030619465 | 1 |
| 用能建议 | 1794030618663 | 1 |
| 告警事件 | 1793303578555 | 1 |
| 设备拓扑 | 1793302274246 | 1 |
| 设备分组 | 1793301131296 | 1 |

**判据**：首页指向的看板必须在列表里；打开首页空白 = 首页那块看板被删或没有部件。

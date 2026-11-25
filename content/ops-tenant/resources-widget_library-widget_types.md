<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 部件 / 部件

> 菜单位置：运维管理 / 租户 / 资源 / 部件 / 部件

> 页面路径：`/resources/widgets-library/widget-types`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `widget_types` |
| 路径 | `/resources/widgets-library/widget-types` |
| 数据表 | `widget_type` |

## 核对 SQL（可直接复制运行）

### 1. 部件类型（自研与平台）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT count(*) FILTER (WHERE fqn LIKE 'energy%' OR fqn LIKE 'idle%'
                          OR fqn LIKE 'hvac%' OR fqn LIKE 'comprehensive%') AS 自研,
       count(*) FILTER (WHERE tenant_id IS NOT NULL) AS 租户私有,
       count(*) AS 总数
FROM widget_type;
SQL
```

**本机实测结果**（前 1 行）：

| 自研 | 租户私有 | 总数 |
| --- | --- | --- |
| 57 | 750 | 750 |

**判据**：部件改了没生效 → 看库里的 `descriptor` 是否已更新（走 31-deploy-widget.sh，不要重启服务）。

<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 报告 / 模板

> 菜单位置：运维管理 / 租户 / 监控 / 报告 / 模板

> 页面路径：`/reporting/templates`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `report_templates` |
| 路径 | `/reporting/templates` |
| 数据表 | `report_template`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 报表模板

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 模板, type AS 类型, format AS 输出格式,
       left(coalesce(configuration, ''), 80) AS 配置开头
FROM report_template
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY name;
SQL
```

**本机实测结果：0 行**（模板、类型、输出格式、配置开头）

**判据**：0 行 = 还没配报表模板（报告相关功能都依赖它）。

> ⚠ 0 行的：1. 报表模板 —— 先确认是不是「本来就没启用/没数据」。

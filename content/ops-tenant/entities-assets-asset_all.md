<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资产 / 全部

> 菜单位置：运维管理 / 租户 / 实体 / 资产 / 全部

> 页面路径：`/entities/assets/all`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `asset_all` |
| 路径 | `/entities/assets/all` |
| 数据表 | `asset`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 资产清单（按类型分组）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT a.type AS 资产类型, count(*) AS 数量,
       count(*) FILTER (WHERE a.customer_id IS NULL) AS 租户级
FROM asset a
WHERE a.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 资产类型 | 数量 | 租户级 |
| --- | --- | --- |
| 厂商 | 21 | 0 |
| 设备型号 | 14 | 0 |
| 分项 | 13 | 0 |
| 运行模式 | 12 | 0 |
| 场站分组 | 9 | 0 |
| 楼栋 | 9 | 0 |
| default | 8 | 0 |
| topology | 7 | 0 |

**判据**：「租户级」= 不归属任何客户、所有客户共用（字典、模板这类应在这里）。

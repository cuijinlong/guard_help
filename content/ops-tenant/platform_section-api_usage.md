<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / API 使用量

> 菜单位置：运维管理 / 租户 / 运营配置 / API 使用量

> 页面路径：`/usage`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `api_usage` |
| 路径 | `/usage` |
| 数据表 | `api_usage_state` |

## 核对 SQL（可直接复制运行）

### 1. API 使用量

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT * FROM api_usage_state LIMIT 5;
SQL
```

**本机实测结果**（前 2 行）：

| id | created_time | tenant_id | entity_type | entity_id | transport |
| --- | --- | --- | --- | --- | --- |
| 64bff670-d2bd-11f1-b794-31725d9e3862 | 1793184630539 | 13814000-1dd2-11b2-8080-808080808080 | TENANT | 13814000-1dd2-11b2-8080-808080808080 | ENABLED |
| 7554f530-d2bd-11f1-b794-31725d9e3862 | 1793184658435 | 709215f0-d2bd-11f1-b794-31725d9e3862 | TENANT | 709215f0-d2bd-11f1-b794-31725d9e3862 | ENABLED |

> 另 10 列未显示；只 SELECT 你要的列即可。

**判据**：用量异常增长时看这张表；它按租户/按接口累计。

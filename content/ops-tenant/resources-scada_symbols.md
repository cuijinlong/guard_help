<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资源 / SCADA 符号

> 菜单位置：运维管理 / 租户 / 资源 / SCADA 符号

> 页面路径：`/resources/scada-symbols`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `scada_symbols` |
| 路径 | `/resources/scada-symbols` |
| 数据表 | `resource` |

## 核对 SQL（可直接复制运行）

### 1. SCADA 符号

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT count(*) AS 数量 FROM resource WHERE resource_type = 'SCADA_SYMBOL';
SQL
```

**本机实测结果**（前 1 行）：

| 数量 |
| --- |
| 0 |

**判据**：0 行 = 还没导入 SCADA 符号库。

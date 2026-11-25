<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 白标 / 自定义菜单

> 菜单位置：运维管理 / 租户 / 白标 / 自定义菜单

> 页面路径：`/white-labeling/customMenu`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `custom_menu` |
| 路径 | `/white-labeling/customMenu` |
| 数据表 | `custom_menu`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 自定义菜单（谁在用哪一份）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 菜单, scope AS 作用域,
       count(*) OVER () AS 总数,
       length(config) AS 配置长度
FROM custom_menu
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) OR tenant_id IS NULL
ORDER BY scope, name;
SQL
```

**本机实测结果**（前 2 行）：

| 菜单 | 作用域 | 总数 | 配置长度 |
| --- | --- | --- | --- |
| 业务导航（能源管理） | CUSTOMER | 2 | 8069 |
| 默认导航（能源管理） | TENANT | 2 | 1159 |

**判据**：客户看到的菜单与租户看到的**是两份**（scope=CUSTOMER / TENANT）；只改代码不改库时存量客户看不到变化。

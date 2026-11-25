<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 资源 / JS 库

> 菜单位置：运维管理 / 租户 / 资源 / JS 库

> 页面路径：`/resources/javascript-library`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `javascript_library` |
| 路径 | `/resources/javascript-library` |
| 数据表 | `resource` |

## 核对 SQL（可直接复制运行）

### 1. JavaScript 资源

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT title AS 名称, resource_key AS 键, length(data) AS 字节数
FROM resource WHERE resource_type = 'JS_MODULE'
ORDER BY title;
SQL
```

**本机实测结果**（前 3 行）：

| 名称 | 键 | 字节数 |
| --- | --- | --- |
| 3D Viewer Extension | tb-3d-viewer-extension.js | 38203 |
| cytoscape | cytoscape.min.js | 435649 |
| gateway-management-extension.js | gateway-management-extension.js | 2079085 |

**判据**：部件里 `require()` 的模块必须在这里存在，否则部件报错。

<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 白标 / 常规

> 菜单位置：运维管理 / 租户 / 白标 / 常规

> 页面路径：`/white-labeling/whiteLabel`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `white_labeling_general` |
| 路径 | `/white-labeling/whiteLabel` |
| 数据表 | `tenant`、`white_labeling` |

## 核对 SQL（可直接复制运行）

### 1. 白标配置项

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT coalesce(type::text, '(默认)') AS 类型, left(settings::text, 120) AS 配置
FROM white_labeling
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) OR tenant_id IS NULL
ORDER BY 1;
SQL
```

**本机实测结果：0 行**（类型、配置）

**判据**：改了 logo/标题但界面没变 → 浏览器缓存；同时确认这一行确实更新了。

> ⚠ 0 行的：1. 白标配置项 —— 先确认是不是「本来就没启用/没数据」。

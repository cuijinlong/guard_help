<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 白标 / 自定义翻译

> 菜单位置：运维管理 / 租户 / 白标 / 自定义翻译

> 页面路径：`/white-labeling/customTranslation`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `custom_translation` |
| 路径 | `/white-labeling/customTranslation` |
| 数据表 | `custom_translation`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 自定义翻译条目

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT locale_code AS 语言, count(*) AS 键数
FROM custom_translation
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团') OR tenant_id IS NULL
GROUP BY 1 ORDER BY 1;
SQL
```

**本机实测结果**（前 1 行）：

| 语言 | 键数 |
| --- | --- |
| zh_CN | 1 |

**判据**：改了翻译界面没变 → 必须走 `POST /api/translation/custom/{locale}`，直接 `INSERT` 会被缓存挡住（AGENTS.md A2b 记过）。

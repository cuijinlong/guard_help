<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设置 / AI 模型

> 菜单位置：运维管理 / 租户 / 运营配置 / 设置 / AI 模型

> 页面路径：`/settings/ai-models`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `ai_models` |
| 路径 | `/settings/ai-models` |
| 数据表 | `ai_model`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. AI 模型

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 名称, created_time
FROM ai_model WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY created_time DESC;
SQL
```

**本机实测结果：0 行**（名称、created_time）

**判据**：0 行 = 没接入 AI 模型（用能建议里的 AI 分析会不可用）。

> ⚠ 0 行的：1. AI 模型 —— 先确认是不是「本来就没启用/没数据」。

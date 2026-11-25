<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 版本控制

> 菜单位置：运维管理 / 租户 / 运营配置 / 版本控制

> 页面路径：`/features/vc`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `version_control` |
| 路径 | `/features/vc` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 版本控制配置

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT key AS 配置项, left(json_value, 160) AS 值
FROM admin_settings WHERE key = 'entitiesVersionControl';
SQL
```

**本机实测结果**（前 1 行）：

| 配置项 | 值 |
| --- | --- |
| entitiesVersionControl | {"repositoryUri":"https://gitee.com/alea_admin/tb-version.git","authMe |

**判据**：0 行 = 版本控制没启用。启用后改看板会自动提交到仓库。

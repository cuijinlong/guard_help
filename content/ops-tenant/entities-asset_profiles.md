<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 实体 / 资产配置

> 菜单位置：运维管理 / 租户 / 实体 / 资产配置

> 页面路径：`/profiles/assetProfiles`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `asset_profiles` |
| 路径 | `/profiles/assetProfiles` |
| 数据表 | `asset`、`asset_profile`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 资产配置

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT ap.name AS 配置, ap.is_default AS 默认, count(a.id) AS 资产数
FROM asset_profile ap
LEFT JOIN asset a ON a.asset_profile_id = ap.id
WHERE ap.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY ap.id, ap.name, ap.is_default ORDER BY 3 DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 配置 | 默认 | 资产数 |
| --- | --- | --- |
| 厂商 | f | 21 |
| 设备型号 | f | 13 |
| 运行模式 | f | 12 |
| 分项 | f | 12 |
| default | t | 10 |
| 楼栋 | f | 9 |
| 场站分组 | f | 9 |
| topology | f | 7 |

**判据**：`is_default=true` 的配置用于没指定配置时新建的资产。

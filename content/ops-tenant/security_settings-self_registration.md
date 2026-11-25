<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 安全 / 自助注册

> 菜单位置：运维管理 / 租户 / 安全 / 自助注册

> 页面路径：`/security-settings/selfRegistration`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `self_registration` |
| 路径 | `/security-settings/selfRegistration` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 自助注册配置

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT key AS 配置项, left(json_value, 160) AS 值
FROM admin_settings
WHERE key ILIKE '%self%registration%' OR key ILIKE '%signup%';
SQL
```

**本机实测结果：0 行**（配置项、值）

**判据**：0 行 = 未启用自助注册（默认关闭，只有管理员能建用户）。

> ⚠ 0 行的：1. 自助注册配置 —— 先确认是不是「本来就没启用/没数据」。

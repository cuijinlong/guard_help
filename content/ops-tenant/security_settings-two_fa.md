<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 安全 / 双因素认证

> 菜单位置：运维管理 / 租户 / 安全 / 双因素认证

> 页面路径：`/security-settings/2fa`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `two_fa` |
| 路径 | `/security-settings/2fa` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 双因素配置（存在 admin_settings 里）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT key AS 配置项, left(json_value, 120) AS 值
FROM admin_settings
WHERE key ILIKE '%twofa%' OR key ILIKE '%two_factor%';
SQL
```

**本机实测结果：0 行**（配置项、值）

**判据**：0 行 = 双因素没启用（默认关闭）。启用前先确认用户都配好了 TOTP。

> ⚠ 0 行的：1. 双因素配置（存在 admin_settings 里） —— 先确认是不是「本来就没启用/没数据」。

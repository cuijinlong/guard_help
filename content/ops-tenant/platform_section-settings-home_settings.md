<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 设置 / 首页

> 菜单位置：运维管理 / 租户 / 运营配置 / 设置 / 首页

> 页面路径：`/settings/home`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `home_settings` |
| 路径 | `/settings/home` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 平台通用设置

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT key AS 配置项, left(json_value, 160) AS 值
FROM admin_settings WHERE key = 'general';
SQL
```

**本机实测结果**（前 1 行）：

| 配置项 | 值 |
| --- | --- |
| general | {"baseUrl": "http://192.168.31.198:8090", "prohibitDifferentUrl": fals |

**判据**：`baseUrl` 写错会导致邮件里的链接、二维码指向错误地址。

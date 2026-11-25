<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 移动应用 / 二维码部件

> 菜单位置：运维管理 / 租户 / 移动应用 / 二维码部件

> 页面路径：`/mobile-center/qr-code-widget`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `mobile_qr_code_widget` |
| 路径 | `/mobile-center/qr-code-widget` |
| 数据表 | `qr_code_settings` |

## 核对 SQL（可直接复制运行）

### 1. 二维码配置

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT count(*) AS 配置数 FROM qr_code_settings;
SQL
```

**本机实测结果**（前 1 行）：

| 配置数 |
| --- |
| 0 |

**判据**：0 行 = 没配置二维码部件（用默认样式）。

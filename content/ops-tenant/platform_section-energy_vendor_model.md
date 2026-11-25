<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 厂商与型号

> 菜单位置：运维管理 / 租户 / 运营配置 / 厂商与型号

> 页面路径：`/vendor-model`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `energy_vendor_model` |
| 路径 | `/vendor-model` |
| 数据表 | `asset`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 厂商与设备型号

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT a.type AS 类型, count(*) AS 数量
FROM asset a
WHERE a.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) AND a.type IN ('厂商', '设备型号')
GROUP BY 1;
SQL
```

**本机实测结果**（前 2 行）：

| 类型 | 数量 |
| --- | --- |
| 设备型号 | 14 |
| 厂商 | 21 |

**判据**：型号必须挂在其厂商下（relation），否则设备档案里选不到。

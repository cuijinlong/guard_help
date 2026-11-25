<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 设备分组

> 菜单位置：运维管理 / 客户 / 设备管理 / 设备分组

> 看板：**设备分组**　`a4917020-d3cc-11f1-9ee9-c3a7be535a93`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 设备分组（1 个功能点）|
| 部件 | `energy_device.group_page` |
| 接口 | `/api/asset`、`/api/asset/`、`/api/asset/{id}`、`/api/assetProfileInfos`、`/api/assetProfiles`、`/api/auth/user`… |
| 数据表 | `device`、`device_profile` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 设备档案（device_profile）与设备数

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT dp.name AS 档案, dp.type AS 类型, count(d.id) AS 设备数
FROM device_profile dp
LEFT JOIN device d ON d.device_profile_id = dp.id
GROUP BY dp.id, dp.name, dp.type ORDER BY 3 DESC;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 档案 | 类型 | 设备数 |
| --- | --- | --- |
| 电能表 | DEFAULT | 15 |
| 风冷冷水机 | DEFAULT | 9 |
| 网关 | DEFAULT | 4 |
| 新风机组 | DEFAULT | 4 |
| 单相电能表 | DEFAULT | 4 |
| 室内环境变送器 | DEFAULT | 3 |
| 立式管道离心泵 | DEFAULT | 2 |
| 热水泵 | DEFAULT | 2 |

**判据**：设备数为 0 的档案是残留；设备档案决定「设备分组」页的树形结构。

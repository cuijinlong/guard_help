<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 设备运维

> 菜单位置：运维管理 / 客户 / 设备管理 / 设备运维

> 看板：**设备运维**　`a9061a40-d3ca-11f1-9ee9-c3a7be535a93`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 设备运维（2 个功能点）|
| 部件 | `energy_device.ops_page`、`energy_device.gateway_detail` |
| 接口 | `/api/alarms`、`/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{NULL_UUID}/deviceInfos`、`/api/customer/{cid}/deviceInfos`… |
| 数据表 | `customer`、`device`、`ts_kv_latest` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 每台设备最近上报时间（最上面的是掉线的）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT d.name AS 设备, d.type AS 类型,
       to_timestamp(max(k.ts) / 1000) AS 最近上报,
       count(*) AS 键数
FROM device d
LEFT JOIN ts_kv_latest k ON k.entity_id = d.id
WHERE d.customer_id = (SELECT id FROM c)
GROUP BY d.id, d.name, d.type
ORDER BY 3 NULLS FIRST;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 设备 | 类型 | 最近上报 | 键数 |
| --- | --- | --- | --- |
| Relay-8CH | default |  | 1 |
| ED1-Gateway | 网关 |  | 1 |
| VirtualMeter-3P-Power | 电能表 | 2026-11-01 00:00:00+08 | 1 |
| VirtualMeter-1P-Socket | 单相电能表 | 2026-11-01 00:00:00+08 | 1 |
| PowerMeter-DDSU666 | 单相电能表 | 2026-11-16 23:59:59+08 | 34 |
| Sensor-HZ8706 | 温湿度变送器 | 2026-11-25 10:48:49+08 | 2 |
| 演示进线-4 电机启动分析 | 电能表 | 2026-11-26 01:46:07+08 | 25 |
| 天骄-PLC网关·生产园区 | 网关 | 2026-11-26 01:46:07+08 | 8 |

**判据**：`最近上报` 为空 = 从没上报过；超过 24 小时 = 掉线。

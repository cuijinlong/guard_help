<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 手工填报

> 菜单位置：运维管理 / 客户 / 综合报表 / 手工填报

> 看板：**手工填报**　`7426ae60-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 手工填报（4 个功能点）|
| 部件 | `energy_management.manual_entry`、`energy_management.query_panel`、`energy_management.monthly_bar`、`energy_management.device_total` |
| 接口 | `/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/devices`、`/api/device/`、`/api/deviceProfileInfo/`… |
| 数据表 | `asset`、`attribute_kv`、`device`、`key_dictionary` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 填报属性挂在设备或分项资产上

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT coalesce(d.name, a.name) AS 实体,
       coalesce(d.type, a.type) AS 类型,
       kd.key AS 属性,
       left(coalesce(ak.json_v::text, ak.str_v), 160) AS 值
FROM attribute_kv ak
LEFT JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
LEFT JOIN device d ON d.id = ak.entity_id
LEFT JOIN asset  a ON a.id = ak.entity_id
WHERE kd.key IN ('manualEntryMonths', 'manualYearValueType', 'manualEntryItemId')
ORDER BY 1, 3;
SQL
```

**本机实测结果**（显示前 7 行，共可能更多）：

| 实体 | 类型 | 属性 | 值 |
| --- | --- | --- | --- |
| VirtualMeter-1P-Socket | 单相电能表 | manualEntryItemId | 7e6b9e30-d2bd-11f1-b794-31725d9e3862 |
| VirtualMeter-1P-Socket | 单相电能表 | manualEntryMonths | [202611] |
| VirtualMeter-3P-Power | 电能表 | manualEntryItemId | 86725dd0-d2bd-11f1-b794-31725d9e3862 |
| VirtualMeter-3P-Power | 电能表 | manualEntryMonths | [202611] |
| 动力分项·生产园区·平台演示中心 | 分项 | manualYearValueType |  |
| 插座分项·办公园区·平台演示中心 | 分项 | manualYearValueType |  |
| 给排水分项·生产园区·平台演示中心 | 分项 | manualYearValueType |  |

**判据**：每个填报对象都有 `manualEntryMonths`。数字大得离谱时看是不是把「正向有功总电度」当成了增量（那是累计表底，应该用末值−初值）。

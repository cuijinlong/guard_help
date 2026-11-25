<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 设备拓扑

> 菜单位置：运维管理 / 客户 / 设备管理 / 设备拓扑

> 看板：**设备拓扑**　`4dd17660-d3cf-11f1-9ee9-c3a7be535a93`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 设备拓扑（1 个功能点）|
| 部件 | `energy_device.topology_page` |
| 接口 | `/api/auth/user`、`/api/customers`、`/api/energy/topologies`、`/api/energy/topologies/`、`/api/resource/js_module/system/cytoscape.min.js` |
| 数据表 | `asset`、`attribute_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 拓扑图资产与它的属性数

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT a.name AS 拓扑图, a.label, count(ak.*) AS 属性数
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id
WHERE a.type = 'topology'
GROUP BY a.id, a.name, a.label ORDER BY 1;
SQL
```

**本机实测结果**（显示前 7 行，共可能更多）：

| 拓扑图 | label | 属性数 |
| --- | --- | --- |
| scn-7ce48900-权限复验 | 权限复验 | 0 |
| scn-7ce48900-模板趋势验证-请删 | 模板趋势验证-请删 | 0 |
| scn-7ce48900-测试 拓扑 | 测试 拓扑 | 2 |
| 天骄科技园 | 天骄科技园 | 2 |
| 物理结构·三相园区·平台演示中心 | 物理结构·生产园区 | 1 |
| 物理结构·单相园区·平台演示中心 | 物理结构·办公园区 | 1 |
| 物理结构·质量示范·平台演示中心 | 物理结构·质量示范站 | 0 |

**判据**：属性数为 0 的拓扑图打开是空的（没保存过布局或连线）。

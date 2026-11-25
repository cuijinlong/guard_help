<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 能源流向

> 菜单位置：运维管理 / 客户 / 能源流向

> 看板：**能源流向**　`744ef6e0-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 能源流向（2 个功能点）|
| 部件 | `energy_management.sankey_flow`、`energy_management.analysis_bar` |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/customer/`、`/api/device/`、`/api/device/{id}`… |
| 数据表 | `asset`、`customer`、`relation` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 流向的骨架：Contains 关系（谁包含谁）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT pa.name AS 上级, pa.type AS 上级类型,
       ca.name AS 下级, ca.type AS 下级类型
FROM relation r
JOIN asset pa ON pa.id = r.to_id
JOIN asset ca ON ca.id = r.from_id
WHERE r.relation_type = 'Contains'
  AND (pa.customer_id = (SELECT id FROM c) OR ca.customer_id = (SELECT id FROM c))
ORDER BY 1, 3
LIMIT 50;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 上级 | 上级类型 | 下级 | 下级类型 |
| --- | --- | --- | --- |
| A栋办公区区域·办公园区·平台演示中心 | 区域 | 单相园区·平台演示中心 | 场站 |
| A栋办公区区域·办公园区·平台演示中心 | 区域 | 用能区域·平台演示中心·单相园区·平台演示中心 | 场站分组 |
| A栋办公区区域·办公园区·平台演示中心 | 区域 | 电能 | default |
| scn-7ce48900-权限复验 | topology | 三相园区·平台演示中心 | 场站 |
| scn-7ce48900-模板趋势验证-请删 | topology | 三相园区·平台演示中心 | 场站 |
| scn-7ce48900-测试 拓扑 | topology | 三相园区·平台演示中心 | 场站 |
| 三相园区·平台演示中心 | 场站 | 总部·平台演示中心 | 组织 |
| 公共区域区域·办公园区·平台演示中心 | 区域 | 单相园区·平台演示中心 | 场站 |

**判据**：环节完整（组织→场站→分项→设备）。缺一层则流向图断在该处、数字为 0。

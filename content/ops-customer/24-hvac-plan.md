<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 运行计划与配置

> 菜单位置：运维管理 / 客户 / 空调管理 / 运行计划与配置

> 看板：**运行计划与配置**　`74001390-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 运行计划与配置（1 个功能点）|
| 部件 | `hvac_management.plan_config` |
| 接口 | `/api/energy/visible-sites`、`/api/hvac/modes`、`/api/hvac/modes/`、`/api/hvac/plan` |
| 数据表 | `asset`、`attribute_kv`、`customer`、`key_dictionary` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 运行模式资产：配置在单个 JSON 属性 hvacMode 里

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 模式, a.label AS 季节,
       ak.str_v::json->>'season'   AS 季节码,
       ak.str_v::json->>'dateType' AS 日期类型,
       ak.str_v::json->>'control'  AS 控制方式,
       ak.str_v::json->>'tempMin'  AS 温度下限
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = '运行模式' AND a.customer_id = (SELECT id FROM c)
  AND kd.key = 'hvacMode'
ORDER BY 1;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 模式 | 季节 | 季节码 | 日期类型 | 控制方式 | 温度下限 |
| --- | --- | --- | --- | --- | --- |
| 办公园区冬季工作日 | 冬季工作日 | winter | workday | auto | 20.0 |
| 办公园区冬季节假日 | 冬季节假日 | winter | holiday | manual | 18.0 |
| 办公园区夏季工作日 | 夏季工作日 | summer | workday | auto | 24.0 |
| 办公园区夏季节假日 | 夏季节假日 | summer | holiday | auto | 25.0 |
| 生产园区冬季工作日 | 冬季工作日 | winter | workday | auto | 20.0 |
| 生产园区冬季节假日 | 冬季节假日 | winter | holiday | manual | 18.0 |
| 生产园区夏季工作日 | 夏季工作日 | summer | workday | auto | 24.0 |
| 生产园区夏季节假日 | 夏季节假日 | summer | holiday | auto | 25.0 |

**判据**：每种季节（夏/冬）× 日期类型（工作日/节假日）都有模式。缺一档则该天计划回退到默认。

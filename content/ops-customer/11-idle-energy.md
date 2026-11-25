<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 闲时能耗

> 菜单位置：运维管理 / 客户 / 能耗优化 / 闲时能耗

> 看板：**闲时能耗**　`74091440-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 闲时能耗（6 个功能点）|
| 部件 | `idle_energy.kpi`、`idle_energy.share`、`idle_energy.trend`、`idle_energy.curve`、`idle_energy.table`、`energy_management.analysis_bar` |
| 接口 | `/api/asset/`、`/api/asset/{id}`、`/api/auth/user`、`/api/device/`、`/api/device/{id}`、`/api/energy/entity-briefs`… |
| 数据表 | `asset`、`attribute_kv`、`customer`、`key_dictionary`、`ts_kv` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 场站的闲时配置（JSON 属性 idleConfig）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT a.name AS 场站, left(ak.json_v::text, 200) AS 配置
FROM asset a
JOIN attribute_kv ak ON ak.entity_id = a.id
JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
WHERE a.type = '场站' AND a.customer_id = (SELECT id FROM c)
  AND kd.key = 'idleConfig';
SQL
```

**本机实测结果**（显示前 2 行，共可能更多）：

| 场站 | 配置 |
| --- | --- |
| 单相园区·平台演示中心 | {"calendar":{},"workStart":"08:00","workEnd":"17:00","baselineEnabled" |
| 三相园区·平台演示中心 | {"calendar":{},"workStart":"08:00","workEnd":"17:00","baselineEnabled" |

### 2. 闲时计算的产出键（规则链写的遥测）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT kd.key AS 键, count(*) AS 点数, round(sum(k.dbl_v)::numeric, 2) AS 合计
FROM ts_kv k
JOIN key_dictionary kd ON kd.key_id = k.key
WHERE kd.key LIKE 'idle\_%' ESCAPE '\' OR kd.key = 'work_energy'
GROUP BY 1 ORDER BY 2 DESC;
SQL
```

**本机实测结果：0 行**（键、点数、合计）

**判据**：场站有 `idleConfig` 就行。**产出键为空不一定是坏事**：`/api/energy/idle-analysis` 在找不到落库结果时会按原始遥测**实时计算**并在响应里给告警。两边都空、且页面也空 → 规则链没部署或设备没上报 `energy_reading` / `power_total`。

> ⚠ 上面返回 0 行的：2. 闲时计算的产出键（规则链写的遥测） —— 先确认是不是「本来就没有」，别直接当成故障。

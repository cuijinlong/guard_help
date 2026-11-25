<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 组织

> 菜单位置：运维管理 / 客户 / 组织

> 看板：**组织与场站**　`04e26da0-d3b7-11f1-8238-c3a7be535a93`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 组织（1 个功能点）|
| 部件 | `energy_org.sites_page` |
| 接口 | `/api/asset`、`/api/asset/`、`/api/auth/user`、`/api/customer/`、`/api/customer/{cid}/deviceInfos`、`/api/customer/{cid}/devices`… |
| 数据表 | `asset`、`attribute_kv`、`customer`、`key_dictionary`、`relation` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 场站清单（顶栏一级/二级下拉的来源）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT a.id AS 场站id, a.name AS 场站, a.label, c.title AS 客户,
       (SELECT count(*) FROM relation r
        WHERE r.to_id = a.id AND r.relation_type = 'Contains') AS 下级数
FROM asset a
LEFT JOIN customer c ON c.id = a.customer_id
WHERE a.type = '场站'
ORDER BY c.title, a.name;
SQL
```

**本机实测结果**（显示前 3 行，共可能更多）：

| 场站id | 场站 | label | 客户 | 下级数 |
| --- | --- | --- | --- | --- |
| 865ed5d0-d2bd-11f1-b794-31725d9e3862 | 三相园区·平台演示中心 | 生产园区 | 平台演示中心 | 3 |
| 7e5d6d60-d2bd-11f1-b794-31725d9e3862 | 单相园区·平台演示中心 | 办公园区 | 平台演示中心 | 3 |
| 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 质量示范·平台演示中心 | 质量示范站 | 平台演示中心 | 3 |

### 2. 场站绑定的电价方案（关系类型 uses，不是属性）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT s.name AS 场站, t.name AS 方案模板,
       (SELECT ak.str_v FROM attribute_kv ak JOIN key_dictionary kd ON kd.key_id = ak.attribute_key
        WHERE ak.entity_id = t.id AND kd.key = 'energy' LIMIT 1) AS 能源品种
FROM asset s
JOIN relation r ON r.from_id = s.id AND r.relation_type = 'uses'
JOIN asset t ON t.id = r.to_id AND t.type = 'rate_template'
WHERE s.type = '场站' AND s.customer_id = (SELECT id FROM c)
ORDER BY 1, 3;
SQL
```

**本机实测结果：0 行**（场站、方案模板、能源品种）

**判据**：每个客户至少一个场站；组织只做「客户→场站」两级，场站是后面所有功能的第一维度。绑定表为空 = 这些场站没单独绑电价，**继承客户默认方案**（不是故障）。

> ⚠ 上面返回 0 行的：2. 场站绑定的电价方案（关系类型 uses，不是属性） —— 先确认是不是「本来就没有」，别直接当成故障。

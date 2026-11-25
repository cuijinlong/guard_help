<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 盘查报告

> 菜单位置：运维管理 / 客户 / 盘查报告

> 看板：**盘查报告**　`73abb200-d2bd-11f1-b794-31725d9e3862`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 盘查报告（1 个功能点）|
| 部件 | `energy_management.audit_report` |
| 接口 | `/api/customer/`、`/api/device/`、`/api/energy/audit-report/precheck`、`/api/energy/audit-report/precheck}`、`/api/energy/audit-report/versions`、`/api/energy/audit-report/versions/`… |
| 数据表 | `asset`、`attribute_kv`、`customer` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 已保存的盘查版本

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心' LIMIT 1)
SELECT a.name AS 版本, a.label AS 范围, count(ak.*) AS 属性数,
       to_timestamp(a.created_time / 1000) AS 创建时间
FROM asset a
LEFT JOIN attribute_kv ak ON ak.entity_id = a.id
WHERE a.type = 'audit_report_version' AND a.customer_id = (SELECT id FROM c)
GROUP BY a.id, a.name, a.label, a.created_time
ORDER BY a.created_time DESC;
SQL
```

**本机实测结果：0 行**（版本、范围、属性数、创建时间）

**判据**：报告内容在资产属性里；没有版本 = 还没点过「保存版本」。

> ⚠ 上面返回 0 行的：1. 已保存的盘查版本 —— 先确认是不是「本来就没有」，别直接当成故障。

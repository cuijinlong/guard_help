<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 用能建议

> 菜单位置：运维管理 / 客户 / 能耗优化 / 用能建议

> 看板：**用能建议**　`1cebb370-da6f-11f1-aec2-1192e109281d`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 用能建议（1 个功能点）|
| 部件 | `energy_management.diagnosis_brief` |
| 接口 | `/api/energy/diagnosis/brief`、`/api/energy/diagnosis/forecast`、`/api/energy/diagnosis/sites`、`/api/plugins/telemetry/DEVICE/` |
| 数据表 | `customer`、`energy_analysis_finding` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 诊断结论（intent=energy_advice）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
-- 坑：这张表的 customer_id 目前**全为空**（历史回填没补上），
--     按客户过滤会一条都查不到，看起来像「没跑过诊断」。按租户查。
WITH t AS (SELECT tenant_id FROM customer WHERE title = '平台演示中心')
SELECT intent AS 类别, kind AS 类型, severity AS 级别,
       site_id AS 场站, count(*) AS 条数,
       max(run_at) AS 最近运行
FROM energy_analysis_finding
WHERE tenant_id = (SELECT tenant_id FROM t) AND intent = 'energy_advice'
GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC;
SQL
```

**本机实测结果**（显示前 2 行，共可能更多）：

| 类别 | 类型 | 级别 | 场站 | 条数 | 最近运行 |
| --- | --- | --- | --- | --- | --- |
| energy_advice | limit | crit | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 30 | 2026-11-08 20:14:01.520468 |
| energy_advice | limit | warn | 7f1f3160-d9fd-11f1-837e-e1c373a05dd9 | 30 | 2026-11-08 20:14:01.520468 |

**判据**：**只看 `最近运行` 这一列**：距今天超过 1 天就是诊断没重跑 —— 页面显示旧结论或为空都是这个原因，不是看板坏。`customer_id` 为空会让按客户过滤的接口少数据（AGENTS.md A2m 已记），所以上面按 `tenant_id` 查。

<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 客户

> 菜单位置：运维管理 / 客户

这一组**逐项对齐平台里客户用户看到的左侧菜单**：顺序、上下级关系都一样，
只是每一项后面附了「这个功能怎么用 SQL 查」。

菜单内容直接从数据库 `custom_menu`（`scope=CUSTOMER`）读出来，
改菜单后重跑生成脚本即可同步，不会手抄漏项。

## 先拿到两个 id（后面每页都要用）

所有页面的 SQL 都按客户名过滤。先确认你的客户叫什么：

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT id, title FROM customer ORDER BY created_time;
SQL
```

| id | title |
| --- | --- |
| 7ce48900-d2bd-11f1-b794-31725d9e3862 | 平台演示中心 |

## 菜单清单（点进去看该功能的 SQL）

| 一级 | 二级 | 页面 |
| --- | --- | --- |
| — | 能耗概览 | [能耗概览](#/menu-ops/customer/energy-overview) |
| 能耗查询 | 实时能耗 | [实时能耗](#/menu-ops/customer/query/realtime) |
| 能耗查询 | 历史能耗 | [历史能耗](#/menu-ops/customer/query/history) |
| 能耗查询 | 抄表功能 | [抄表功能](#/menu-ops/customer/query/meter-reading) |
| 能耗分析 | 峰谷分析 | [峰谷分析](#/menu-ops/customer/analysis/tou-analysis) |
| 能耗分析 | 分项能耗 | [分项能耗](#/menu-ops/customer/analysis/itemized) |
| 能耗分析 | 区域能耗 | [区域能耗](#/menu-ops/customer/analysis/region) |
| 能耗分析 | 用能账单 | [用能账单](#/menu-ops/customer/analysis/billing) |
| 综合报表 | 基础报表 | [基础报表](#/menu-ops/customer/reports/basic-report) |
| 综合报表 | 手工填报 | [手工填报](#/menu-ops/customer/reports/manual-entry) |
| 能耗优化 | 闲时能耗 | [闲时能耗](#/menu-ops/customer/optimize/idle-energy) |
| 能耗优化 | 负载预测 | [负载预测](#/menu-ops/customer/optimize/forecast) |
| 能耗优化 | 用能建议 | [用能建议](#/menu-ops/customer/optimize/advice) |
| 能耗优化 | 用能质量 | [用能质量](#/menu-ops/customer/optimize/quality) |
| — | 告警事件 | [告警事件](#/menu-ops/customer/alarm-events) |
| 设备管理 | 设备运维 | [设备运维](#/menu-ops/customer/device/device-ops) |
| 设备管理 | 设备分组 | [设备分组](#/menu-ops/customer/device/device-group) |
| 设备管理 | 设备拓扑 | [设备拓扑](#/menu-ops/customer/device/device-topology) |
| — | 综合能耗 | [综合能耗](#/menu-ops/customer/comprehensive) |
| — | 能源流向 | [能源流向](#/menu-ops/customer/sankey) |
| — | 盘查报告 | [盘查报告](#/menu-ops/customer/audit-report) |
| — | 节能记录 | [节能记录](#/menu-ops/customer/saving-records) |
| 空调管理 | 空调运行监控 | [空调运行监控](#/menu-ops/customer/hvac/hvac-monitor) |
| 空调管理 | 运行计划与配置 | [运行计划与配置](#/menu-ops/customer/hvac/hvac-plan) |
| 空调管理 | 每日复盘报告 | [每日复盘报告](#/menu-ops/customer/hvac/hvac-daily) |
| — | 组织 | [组织](#/menu-ops/customer/org) |

## 三条通用口径（对不上时先看这里）

| 现象 | 真实原因 |
| --- | --- |
| 去 `billing` 表查账单，永远是空 | 账单不在那张表，在 `asset(type='energy_bill')` 的属性里 |
| 按客户过滤查不到诊断结论 | `energy_analysis_finding.customer_id` 目前为空，要按 `tenant_id` 查 |
| 查 `tou_scheme` 按客户过滤返回 0 行 | 时段方案是**租户级**资产，不能按客户过滤 |

> 完整的“每个页面数字落在哪张表”对照表，见 [⑭ 菜单→SQL 核对卡](/admin/menu-sql-map)。

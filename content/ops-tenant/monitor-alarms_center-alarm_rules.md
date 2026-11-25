<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 告警 / 告警规则

> 菜单位置：运维管理 / 租户 / 监控 / 告警 / 告警规则

> 页面路径：`/alarms/alarm-rules`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `alarm_rules` |
| 路径 | `/alarms/alarm-rules` |
| 数据表 | `alarm_rule`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 告警规则（自研表，不是 TB 原生 alarm_rule）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 规则, enabled AS 启用, alarm_type AS 告警类型,
       ts_key AS 监控键, direction AS 方向, threshold AS 阈值, severity AS 级别
FROM alarm_rule
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
ORDER BY enabled DESC, name;
SQL
```

**本机实测结果**（前 6 行）：

| 规则 | 启用 | 告警类型 | 监控键 | 方向 | 阈值 |
| --- | --- | --- | --- | --- | --- |
| 演示·单相表功率因数偏低 | t | 演示·单相表功率因数偏低 | power_factor_total | LOW | 0.95 |
| 演示·单相表频率偏低 | t | 演示·单相表频率偏低 | frequency | LOW | 50.5 |
| 演示·换热站温度偏高 | t | 演示·换热站温度偏高 | temperature | HIGH | 60 |
| 演示·新风机组频率异常 | t | 演示·新风机组频率异常 | frequency | LOW | 45 |
| 演示·生产园区电压偏低 | t | 演示·生产园区电压偏低 | voltage_avg | LOW | 220 |
| 演示·变压器温度过高（已停用） | f | 演示·变压器温度过高（已停用） | temperature | HIGH | 30 |

> 另 1 列未显示；只 SELECT 你要的列即可。

**判据**：`enabled=false` 的规则不会产生告警。改完规则要确认这一列。

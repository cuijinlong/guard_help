<!-- 由 tools/gen-ops-customer-pages.py 生成，不要手改 -->

# 告警事件

> 菜单位置：运维管理 / 客户 / 告警事件

> 看板：**告警事件**　`573f38b0-d3d2-11f1-9ee9-c3a7be535a93`

## 这个功能是怎么取数的

| 环节 | 内容 |
| --- | --- |
| 界面 | 告警事件（1 个功能点）|
| 部件 | `energy_alarm.events_page` |
| 接口 | `/api/alarm/`、`/api/auth/user`、`/api/energy/alarm-events`、`/api/energy/alarm-events/ack`、`/api/energy/alarm-events/assign`、`/api/energy/alarm-events/assignees`… |
| 数据表 | `alarm`、`alarm_rule`、`customer` |

## 核对 SQL（可直接复制运行）

每段都是完整的 bash 命令：连库、执行、退出，复制到终端即可。

### 1. 按类型与级别统计（含未清除数）

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
WITH c AS (SELECT id FROM customer WHERE title = '平台演示中心')
SELECT type AS 类型, severity AS 级别, count(*) AS 条数,
       count(*) FILTER (WHERE clear_ts IS NULL) AS 未清除
FROM alarm
WHERE customer_id = (SELECT id FROM c)
GROUP BY 1, 2 ORDER BY 3 DESC;
SQL
```

**本机实测结果**（显示前 8 行，共可能更多）：

| 类型 | 级别 | 条数 | 未清除 |
| --- | --- | --- | --- |
| 功率因数偏低 | MINOR | 3189 | 0 |
| 演示·生产园区电压偏低 | WARNING | 531 | 0 |
| 演示·单相表功率因数偏低 | MINOR | 345 | 0 |
| 设备离线 | MAJOR | 52 | 0 |
| 演示·单相表频率偏低 | MAJOR | 2 | 0 |
| 设备遥测上报中断（超过 24 小时未收到数据） | MINOR | 1 | 0 |
| 演示·空开电流越限 | CRITICAL | 1 | 0 |
| 出水温度传感器失效 TH702 | CRITICAL | 1 | 0 |

### 2. 告警规则是否启用

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT name AS 规则, enabled AS 启用, count(*) OVER () AS 规则总数
FROM alarm_rule ORDER BY enabled DESC, name;
SQL
```

**本机实测结果**（显示前 6 行，共可能更多）：

| 规则 | 启用 | 规则总数 |
| --- | --- | --- |
| 演示·单相表功率因数偏低 | t | 6 |
| 演示·单相表频率偏低 | t | 6 |
| 演示·换热站温度偏高 | t | 6 |
| 演示·新风机组频率异常 | t | 6 |
| 演示·生产园区电压偏低 | t | 6 |
| 演示·变压器温度过高（已停用） | f | 6 |

**判据**：页面只列未清除的（`clear_ts IS NULL`）。条数为 0 但设备确实异常 → 规则没启用或没绑。

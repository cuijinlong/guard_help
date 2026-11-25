<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 告警 / 告警列表

> 菜单位置：运维管理 / 租户 / 监控 / 告警 / 告警列表

> 页面路径：`/alarms/alarms`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `alarms` |
| 路径 | `/alarms/alarms` |
| 数据表 | `alarm`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 告警按类型与级别统计

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT type AS 类型, severity AS 级别,
       count(*) AS 总数,
       count(*) FILTER (WHERE clear_ts IS NULL) AS 未清除,
       max(to_timestamp(created_time / 1000)) AS 最近一条
FROM alarm
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团')
GROUP BY 1, 2 ORDER BY 3 DESC;
SQL
```

**本机实测结果**（前 8 行）：

| 类型 | 级别 | 总数 | 未清除 | 最近一条 |
| --- | --- | --- | --- | --- |
| 功率因数偏低 | MINOR | 3178 | 0 | 2026-11-25 17:48:08+08 |
| 演示·生产园区电压偏低 | WARNING | 530 | 0 | 2026-11-25 17:45:08+08 |
| 演示·单相表功率因数偏低 | MINOR | 345 | 0 | 2026-11-25 17:48:38+08 |
| 设备离线 | MAJOR | 52 | 0 | 2026-11-25 15:14:26+08 |
| 演示·单相表频率偏低 | MAJOR | 2 | 0 | 2026-11-25 00:52:30+08 |
| 设备遥测上报中断（超过 24 小时未收到数据） | MINOR | 1 | 0 | 2026-11-25 01:02:04+08 |
| 演示·空开电流越限 | CRITICAL | 1 | 0 | 2026-11-12 10:00:01+08 |
| 出水温度传感器失效 TH702 | CRITICAL | 1 | 0 | 2026-11-25 00:12:04+08 |

**判据**：页面只列未清除的（`clear_ts IS NULL`）。总数为 0 而设备确实异常 → 告警规则没启用。

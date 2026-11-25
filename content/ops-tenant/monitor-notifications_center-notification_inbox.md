<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 收件箱

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 收件箱

> 页面路径：`/notification/inbox`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_inbox` |
| 路径 | `/notification/inbox` |
| 数据表 | `notification`、`tb_user` |

## 核对 SQL（可直接复制运行）

### 1. 收件箱（当前用户收到的通知）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT n.subject AS 标题, n.type AS 类型, n.status AS 状态,
       to_timestamp(n.created_time / 1000) AS 时间,
       u.email AS 收件人
FROM notification n
LEFT JOIN tb_user u ON u.id = n.recipient_id
ORDER BY n.created_time DESC LIMIT 20;
SQL
```

**本机实测结果**（前 8 行）：

| 标题 | 类型 | 状态 | 时间 | 收件人 |
| --- | --- | --- | --- | --- |
| Alarm '功率因数偏低' - cleared | ALARM | SENT | 2026-11-26 01:47:31+08 | tenant@126.com |
| New alarm '功率因数偏低' | ALARM | SENT | 2026-11-26 01:47:31+08 | tenant@126.com |
| Alarm '功率因数偏低' - cleared | ALARM | SENT | 2026-11-26 01:46:20+08 | tenant@126.com |
| Alarm '功率因数偏低' - cleared | ALARM | SENT | 2026-11-26 01:46:18+08 | tenant@126.com |
| New alarm '功率因数偏低' | ALARM | SENT | 2026-11-26 01:46:18+08 | tenant@126.com |
| Alarm '功率因数偏低' - cleared | ALARM | SENT | 2026-11-26 01:45:01+08 | tenant@126.com |
| Alarm '功率因数偏低' - cleared | ALARM | SENT | 2026-11-26 01:44:48+08 | tenant@126.com |
| New alarm '功率因数偏低' | ALARM | SENT | 2026-11-26 01:43:40+08 | tenant@126.com |

**判据**：收到的条数与页面列表一致。`status` 未读/已读决定是否加粗。

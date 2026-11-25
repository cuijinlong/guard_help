<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 已发送

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 已发送

> 页面路径：`/notification/sent`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_sent` |
| 路径 | `/notification/sent` |
| 数据表 | `notification`、`now` |

## 核对 SQL（可直接复制运行）

### 1. 已发送通知

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT subject AS 标题, delivery_method AS 方式, type AS 类型,
       count(*) AS 条数, max(to_timestamp(created_time / 1000)) AS 最近发送
FROM notification
WHERE created_time >= (extract(epoch FROM now() - interval '30 day') * 1000)::bigint
GROUP BY 1, 2, 3 ORDER BY 条数 DESC LIMIT 20;
SQL
```

**本机实测结果**（前 8 行）：

| 标题 | 方式 | 类型 | 条数 | 最近发送 |
| --- | --- | --- | --- | --- |
| New alarm '功率因数偏低' | WEB | ALARM | 13111 | 2026-11-26 01:47:31+08 |
| Alarm '功率因数偏低' - cleared | WEB | ALARM | 13106 | 2026-11-26 01:47:31+08 |
| Warning: CPU shortage for 4d6e5ba7f9e0 | WEB | RESOURCES_SHORTAGE | 215 | 2026-11-26 00:59:35+08 |
| New alarm '闲时能耗超标' | WEB | ALARM | 195 | 2026-11-24 02:17:22+08 |
| Device was added | WEB | ENTITY_ACTION | 169 | 2026-11-25 00:51:39+08 |
| Warning: CPU shortage for 6ae72e064a9e | WEB | RESOURCES_SHORTAGE | 127 | 2026-11-15 01:43:47+08 |
| New alarm '设备离线' | WEB | ALARM | 100 | 2026-11-26 01:42:05+08 |
| Alarm '设备离线' - cleared | WEB | ALARM | 100 | 2026-11-26 01:42:25+08 |

**判据**：发了但客户没收到 → 看 `delivery_method` 与邮件服务器配置（设置 → 邮件服务器）。

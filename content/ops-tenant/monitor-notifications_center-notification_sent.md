<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 通知 / 已发送

> 菜单位置：运维管理 / 租户 / 监控 / 通知 / 已发送

> 页面路径：`/notification/sent`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `notification_sent` |
| 路径 | `/notification/sent` |
| 数据表 | `notification` |

## 核对 SQL（可直接复制运行）

### 1. 已发送通知

```bash
docker exec -i energy-postgres psql -U postgres -d thingsboard <<'SQL'
SELECT subject AS 标题, delivery_method AS 方式, type AS 类型,
       count(*) AS 条数, max(to_timestamp(created_time / 1000)) AS 最近发送
FROM notification
GROUP BY 1, 2, 3 ORDER BY 条数 DESC LIMIT 20;
SQL
```

**本机实测结果**（前 8 行）：

| 标题 | 方式 | 类型 | 条数 | 最近发送 |
| --- | --- | --- | --- | --- |
| New alarm '功率因数偏低' | WEB | ALARM | 12071 | 2026-11-25 17:48:09+08 |
| Alarm '功率因数偏低' - cleared | WEB | ALARM | 12065 | 2026-11-25 17:48:24+08 |
| Warning: CPU shortage for 4d6e5ba7f9e0 | WEB | RESOURCES_SHORTAGE | 207 | 2026-11-25 17:46:49+08 |
| New alarm '闲时能耗超标' | WEB | ALARM | 195 | 2026-11-24 02:17:22+08 |
| Device was added | WEB | ENTITY_ACTION | 169 | 2026-11-25 00:51:39+08 |
| Warning: CPU shortage for 6ae72e064a9e | WEB | RESOURCES_SHORTAGE | 127 | 2026-11-15 01:43:47+08 |
| Warning: CPU shortage for 4b93da673b72 | WEB | RESOURCES_SHORTAGE | 70 | 2026-11-02 09:52:29+08 |
| Warning: CPU shortage for 06e123c249a1 | WEB | RESOURCES_SHORTAGE | 60 | 2026-11-07 00:17:36+08 |

**判据**：发了但客户没收到 → 看 `delivery_method` 与邮件服务器配置（设置 → 邮件服务器）。

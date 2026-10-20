# 配置项

> 出问题十次有八次是配置。

## 本页内容（大纲待确认）

- `admin_settings` 关键项
  - general.baseUrl：**必须改成实际域名**，否则邮件链接全错
  - mail：SMTP 主机、端口、TLS、发件人
  - jwt：token 有效期
- `thingsboard.yml` 关键项
  - 数据库连接
  - 队列类型（内存 / Kafka）
  - 传输端口
- ngx-ai 环境变量
  - TB_BASE_URL、PG_ENABLED、PG_DSN
  - 模型与调度相关
- 部件级配置（factorJson / thresholdJson / behaviorJson）

## 待补充

- [ ] 一份可用的最小配置样例
- [ ] 敏感项清单（哪些不能进仓库）

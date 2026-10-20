# 安全加固

> 对外提供服务前必须做完。

## 本页内容（大纲待确认）

- 默认账号必须改（tenant/tenant、customer/customer）
- JWT signing key 必须换，且不能进仓库
- HTTPS 与反向代理
- 数据库端口不对外
- 客户隔离验证（横向越权测试）
- 敏感信息清单：网关 token、数据库密码、API key
- 审计日志开启与留存

## 待补充

- [ ] 上线前安全检查清单
- [ ] 已知的弱配置现状（如 admin_settings 里仍有明文字段）

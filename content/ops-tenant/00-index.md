<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 租户

> 菜单位置：运维管理 / 租户

这一组**逐项对齐平台里租户用户看到的左侧菜单**：顺序、上下级都一样，只是每一项后面附了「这个功能怎么用 SQL 查」。

菜单结构由 `tools/gen-tenant-menu-snapshot.mjs` 合成（库里的 `custom_menu` 只有引用，真实名字与下级在前端 `menu.models.ts`），固化在 `tools/data/tenant-menu.json`；改了菜单要重跑该脚本。

## 先确认租户名

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT id, title FROM tenant ORDER BY created_time;
SQL
```

| id | title |
| --- | --- |
| 709215f0-d2bd-11f1-b794-31725d9e3862 | 星河能源集团 |

## 菜单清单（点进去看该功能的 SQL）

| 一级 | 二级 | 三级 | 页面 |
| --- | --- | --- | --- |
| 首页 | — | — | [首页](#/menu-ops/tenant/home) |
| 监控 | 仪表板 | — | [全部](#/menu-ops/tenant/monitor/dashboards/dashboard_all) |
| 监控 | 仪表板 | — | [分组](#/menu-ops/tenant/monitor/dashboards/dashboard_groups) |
| 监控 | 仪表板 | — | [共享](#/menu-ops/tenant/monitor/dashboards/dashboard_shared) |
| 监控 | 告警 | — | [告警列表](#/menu-ops/tenant/monitor/alarms_center/alarms) |
| 监控 | 告警 | — | [告警规则](#/menu-ops/tenant/monitor/alarms_center/alarm_rules) |
| 监控 | 通知 | — | [收件箱](#/menu-ops/tenant/monitor/notifications_center/notification_inbox) |
| 监控 | 通知 | — | [已发送](#/menu-ops/tenant/monitor/notifications_center/notification_sent) |
| 监控 | 通知 | — | [收件人](#/menu-ops/tenant/monitor/notifications_center/notification_recipients) |
| 监控 | 通知 | — | [模板](#/menu-ops/tenant/monitor/notifications_center/notification_templates) |
| 监控 | 通知 | — | [规则](#/menu-ops/tenant/monitor/notifications_center/notification_rules) |
| 监控 | 报告 | — | [模板](#/menu-ops/tenant/monitor/reporting/report_templates) |
| 监控 | 报告 | — | [调度](#/menu-ops/tenant/monitor/reporting/report_scheduling) |
| 监控 | 报告 | — | [报告](#/menu-ops/tenant/monitor/reporting/reports) |
| 实体 | 设备 | — | [全部](#/menu-ops/tenant/entities/devices/device_all) |
| 实体 | 设备 | — | [分组](#/menu-ops/tenant/entities/devices/device_groups) |
| 实体 | 设备 | — | [共享](#/menu-ops/tenant/entities/devices/device_shared) |
| 实体 | — | — | [网关](#/menu-ops/tenant/entities/gateways) |
| 实体 | 资产 | — | [全部](#/menu-ops/tenant/entities/assets/asset_all) |
| 实体 | 资产 | — | [组](#/menu-ops/tenant/entities/assets/asset_groups) |
| 实体 | 资产 | — | [共享](#/menu-ops/tenant/entities/assets/asset_shared) |
| 实体 | — | — | [设备配置](#/menu-ops/tenant/entities/device_profiles) |
| 实体 | — | — | [资产配置](#/menu-ops/tenant/entities/asset_profiles) |
| 实体 | 实体视图 | — | [全部](#/menu-ops/tenant/entities/entity_views/entity_view_all) |
| 实体 | 实体视图 | — | [分组](#/menu-ops/tenant/entities/entity_views/entity_view_groups) |
| 实体 | 实体视图 | — | [共享](#/menu-ops/tenant/entities/entity_views/entity_view_shared) |
| 实体 | — | — | [OTA 更新](#/menu-ops/tenant/entities/otaUpdates) |
| 客户与用户 | 客户 | — | [全部](#/menu-ops/tenant/customers_and_users/customers/customer_all) |
| 客户与用户 | 客户 | — | [分组](#/menu-ops/tenant/customers_and_users/customers/customer_groups) |
| 客户与用户 | 客户 | — | [共享](#/menu-ops/tenant/customers_and_users/customers/customer_shared) |
| 客户与用户 | 客户 | — | [层级](#/menu-ops/tenant/customers_and_users/customers/customers_hierarchy) |
| 客户与用户 | 用户 | — | [全部](#/menu-ops/tenant/customers_and_users/users/user_all) |
| 客户与用户 | 用户 | — | [分组](#/menu-ops/tenant/customers_and_users/users/user_groups) |
| 客户与用户 | — | — | [角色](#/menu-ops/tenant/customers_and_users/roles) |
| 数据处理 | — | — | [计算字段](#/menu-ops/tenant/data_processing/calculated_fields) |
| 数据处理 | — | — | [规则链](#/menu-ops/tenant/data_processing/rule_chains) |
| 白标 | — | — | [常规](#/menu-ops/tenant/white_labeling/white_labeling_general) |
| 白标 | — | — | [登录](#/menu-ops/tenant/white_labeling/login_white_labeling) |
| 白标 | — | — | [邮件模板](#/menu-ops/tenant/white_labeling/mail_templates) |
| 白标 | — | — | [自定义翻译](#/menu-ops/tenant/white_labeling/custom_translation) |
| 白标 | — | — | [自定义菜单](#/menu-ops/tenant/white_labeling/custom_menu) |
| 资源 | 部件 | — | [部件](#/menu-ops/tenant/resources/widget_library/widget_types) |
| 资源 | 部件 | — | [部件包](#/menu-ops/tenant/resources/widget_library/widgets_bundles) |
| 资源 | — | — | [图片](#/menu-ops/tenant/resources/images) |
| 资源 | — | — | [SCADA 符号](#/menu-ops/tenant/resources/scada_symbols) |
| 资源 | — | — | [JS 库](#/menu-ops/tenant/resources/javascript_library) |
| 资源 | — | — | [资源库](#/menu-ops/tenant/resources/resources_library) |
| 安全 | — | — | [双因素认证](#/menu-ops/tenant/security_settings/two_fa) |
| 安全 | OAuth 2.0 | — | [域名](#/menu-ops/tenant/security_settings/oauth2/domains) |
| 安全 | OAuth 2.0 | — | [OAuth 2.0 客户端](#/menu-ops/tenant/security_settings/oauth2/clients) |
| 安全 | — | — | [自助注册](#/menu-ops/tenant/security_settings/self_registration) |
| 安全 | — | — | [密钥存储](#/menu-ops/tenant/security_settings/secrets) |
| 安全 | — | — | [审计日志](#/menu-ops/tenant/security_settings/audit_log) |
| 运营配置 | — | — | [厂商与型号](#/menu-ops/tenant/platform_section/energy_vendor_model) |
| 运营配置 | — | — | [峰谷时段](#/menu-ops/tenant/platform_section/energy_base_config) |
| 运营配置 | — | — | [品种指标](#/menu-ops/tenant/platform_section/energy_dict) |
| 运营配置 | — | — | [设备类型](#/menu-ops/tenant/platform_section/energy_device_type) |
| 运营配置 | — | — | [版本控制](#/menu-ops/tenant/platform_section/version_control) |
| 运营配置 | — | — | [任务管理器](#/menu-ops/tenant/platform_section/task_manager) |
| 运营配置 | — | — | [调度器](#/menu-ops/tenant/platform_section/scheduler) |
| 运营配置 | 设置 | — | [首页](#/menu-ops/tenant/platform_section/settings/home_settings) |
| 运营配置 | 设置 | — | [邮件服务器](#/menu-ops/tenant/platform_section/settings/mail_server) |
| 运营配置 | 设置 | — | [通知](#/menu-ops/tenant/platform_section/settings/notification_settings) |
| 运营配置 | 设置 | — | [仓库](#/menu-ops/tenant/platform_section/settings/repository_settings) |
| 运营配置 | 设置 | — | [自动提交](#/menu-ops/tenant/platform_section/settings/auto_commit_settings) |
| 运营配置 | 设置 | — | [AI 模型](#/menu-ops/tenant/platform_section/settings/ai_models) |
| 运营配置 | — | — | [API 使用量](#/menu-ops/tenant/platform_section/api_usage) |
| Trend 分析 | — | — | [Trend 分析](#/menu-ops/tenant/custom-9) |
| 移动应用 | — | — | [包](#/menu-ops/tenant/mobile_center/mobile_bundles) |
| 移动应用 | — | — | [应用程序](#/menu-ops/tenant/mobile_center/mobile_apps) |
| 移动应用 | — | — | [二维码部件](#/menu-ops/tenant/mobile_center/mobile_qr_code_widget) |

## 三条通用口径

| 现象 | 真实原因 |
| --- | --- |
| 客户看不到某台设备/看板 | 它的 `customer_id` 为空，或没分配/共享给客户 |
| 客户看到的菜单与我改的不一样 | 客户菜单是 `scope=CUSTOMER` 那份，租户菜单是 `scope=TENANT` 那份，**两份独立** |
| 改了部件/翻译界面没变 | 走接口或部署脚本，不要重启服务（手册 ⑭ / ⑧ 有对应做法） |

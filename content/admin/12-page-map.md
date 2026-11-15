# 页面链路卡：页面 → 看板 → 部件 → 接口 → 类 → 表

> 26 个客户页面，每页一张卡。**先看下面的总览表找到你要查的页，再点左侧目录跳过去。**
> 想学「怎么自己挖出来」，看 [架构导航](/admin/architecture)。

**怎么读一张卡**：

- `[自研]` 的部件是本项目写的；`[TB]` 是平台自带
- 接口里 `/api/energy/*` 是自研后端，其余是 TB 原生接口
- 最后一列是「关键表」——想核对数字就去这些表查

> 本页由脚本自动生成（2026-11-15），数据全部来自实测：数据库 + 部件脚本 + 源码。
> 改了看板或代码后请重跑文末脚本，**不要手改**。

## 一、总览（26 个页面）

| 页面 | 看板 | 部件 | 自研接口 | 主要 Controller |
| --- | --- | --- | --- | --- |
| [能耗概览](#能耗概览) | 能耗概览 | 8 | 7 | EnergyAnalysisController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗查询 / 实时能耗](#实时能耗-能耗查询) | 实时能耗 | 3 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗查询 / 历史能耗](#历史能耗-能耗查询) | 历史能耗 | 2 | 5 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗查询 / 抄表功能](#抄表功能-能耗查询) | 抄表功能 | 4 | 9 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 峰谷分析](#峰谷分析-能耗分析) | 峰谷分析 | 2 | 5 | EnergyAnalysisController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗分析 / 分项能耗](#分项能耗-能耗分析) | 分项能耗 | 4 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 区域能耗](#区域能耗-能耗分析) | 区域能耗 | 5 | 6 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [能耗分析 / 用能账单](#用能账单-能耗分析) | 我的账单 | 2 | 7 | EnergyAnalysisController, EnergyBillingController, EnergyMeterReadingController… |
| [综合报表 / 基础报表](#基础报表-综合报表) | 基础报表 | 2 | 5 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [综合报表 / 手工填报](#手工填报-综合报表) | 手工填报 | 4 | 8 | EnergyManualEntryController, EnergyMeterReadingController, EnergyMetricParamController… |
| [能耗优化 / 闲时能耗](#闲时能耗-能耗优化) | 闲时能耗 | 1 | 3 | EnergyRatePolicyController, IdleEnergyController |
| [能耗优化 / 负载预测](#负载预测-能耗优化) | 负载预测 | 2 | 4 | EnergyForecastController, EnergyRatePolicyController, EnergyTimeAnchorController |
| [能耗优化 / 用能建议](#用能建议-能耗优化) | 用能建议 | 1 | 3 | EnergyDiagnosisController |
| [能耗优化 / 用能质量](#用能质量-能耗优化) | 用能质量 | 1 | 3 | EnergyDiagnosisController |
| [告警事件](#告警事件) | 告警事件 | 1 | 8 | AlarmEventController, AlarmRuleCrudController |
| [设备管理 / 设备运维](#设备运维-设备管理) | 设备运维 | 2 | 4 | EnergyMeterReadingController, EnergyMetricParamController, EnergyRatePolicyController… |
| [设备管理 / 设备分组](#设备分组-设备管理) | 设备分组 | 1 | 5 | EnergyDeviceProfileMetaController, EnergyDictionaryController, EnergyRatePolicyController… |
| [设备管理 / 设备拓扑](#设备拓扑-设备管理) | 设备拓扑 | 1 | 1 | EnergyTopologyController |
| [综合能耗](#综合能耗) | 综合能耗 | 1 | 2 | EnergyMetricParamController, EnergyTelemetryController |
| [能源流向](#能源流向) | 能源流向 | 2 | 5 | EnergyMetricParamController, EnergyRatePolicyController, EnergyTimeAnchorController |
| [盘查报告](#盘查报告) | 盘查报告 | 1 | 2 | EnergyAuditReportController, EnergyMetricParamController |
| [节能记录](#节能记录) | 节能记录 | 1 | 1 | EnergyMetricParamController |
| [空调管理 / 空调运行监控](#空调运行监控-空调管理) | 空调运行监控 | 1 | 1 | EnergyRatePolicyController |
| [空调管理 / 运行计划与配置](#运行计划与配置-空调管理) | 运行计划与配置 | 1 | 1 | EnergyRatePolicyController |
| [空调管理 / 每日复盘报告](#每日复盘报告-空调管理) | 每日复盘报告 | 1 | 1 | EnergyRatePolicyController |
| [组织](#组织) | 组织与场站 | 1 | 13 | DeviceDisplayNameController, EnergyDictionaryController, EnergyMetricParamController… |

## 二、逐页链路卡


### 能耗概览

```
看板    能耗概览
看板ID  73dd2240-d2bd-11f1-b794-31725d9e3862
部件    8 个
        [自研] system.energy_management.calendar_heatmap
        [自研] system.energy_management.tou_summary
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.power_load
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.overview_stats
        [自研] system.energy_management.distribution_chart

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/tou-analysis                   -> EnergyAnalysisController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        ts_kv + tou_scheme 资产
        asset, relation（场站可见性）
```

### 告警事件

```
看板    告警事件
看板ID  573f38b0-d3d2-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_alarm.events_page

自研接口
        /api/energy/alarm-events                   -> AlarmEventController.java
        /api/energy/alarm-events/ack               -> AlarmEventController.java
        /api/energy/alarm-events/assign            -> AlarmEventController.java
        /api/energy/alarm-events/assignees         -> AlarmEventController.java
        /api/energy/alarm-events/clear             -> AlarmEventController.java
        /api/energy/alarm-events/sites             -> AlarmEventController.java
        /api/energy/alarm-rules                    -> AlarmRuleCrudController.java
        /api/energy/alarm-rules/status             -> AlarmRuleCrudController.java
TB 原生接口
        /api/alarm
        /api/auth/user
        /api/plugins/telemetry/DEVICE

关键表
        alarm（TB 原生）
        ★ alarm_rule 表（自研规则）+ 产出 TB 原生 alarm
```

### 综合能耗

```
看板    综合能耗
看板ID  73ba09e0-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.energy_overview

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
TB 原生接口
        /api/alarms
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        ...（共 9 个）

关键表
        relation
        ts_kv, ts_kv_latest, key_dictionary
```

### 能源流向

```
看板    能源流向
看板ID  744ef6e0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.sankey_flow

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/auth/user
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        ...（共 10 个）

关键表
        relation
        asset, device（名称/档案缓存）
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```

### 盘查报告

```
看板    盘查报告
看板ID  73abb200-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.audit_report

自研接口
        /api/energy/audit-report/versions          -> EnergyAuditReportController.java
        /api/energy/child-relations                -> EnergyMetricParamController.java
TB 原生接口
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        /api/tenant/devices

关键表
        ★ audit_report_version 资产（SERVER_SCOPE 属性）
        relation
```

### 节能记录

```
看板    节能记录
看板ID  7452c770-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.energy_management.saving_records

自研接口
        /api/energy/child-relations                -> EnergyMetricParamController.java
TB 原生接口
        /api/asset
        /api/customer
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry/ASSET
        /api/plugins/telemetry/DEVICE
        /api/relations
        /api/tenant/assets
        ...（共 9 个）

关键表
        relation
```

### 组织

```
看板    组织与场站
看板ID  04e26da0-d3b7-11f1-8238-c3a7be535a93
部件    1 个
        [自研] system.energy_org.sites_page

自研接口
        /api/energy/core-dictionaries              -> EnergyMetricParamController.java
        /api/energy/customer-roles                 -> SiteUserController.java
        /api/energy/device-display-name            -> DeviceDisplayNameController.java
        /api/energy/dictionaries                   -> EnergyDictionaryController.java
        /api/energy/gateway                        -> GatewayBindingController.java
        /api/energy/idle-config                    -> IdleEnergyController.java
        /api/energy/idle-recompute                 -> IdleEnergyController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/org-rate                       -> EnergyRatePolicyController.java
        /api/energy/rate-policies                  -> EnergyRatePolicyController.java
        /api/energy/site-rate-binding              -> EnergyRatePolicyController.java
        /api/energy/site-rate-custom               -> EnergyRatePolicyController.java
        /api/energy/vendor-models                  -> EnergyVendorModelController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/customers
        /api/device
        /api/entityGroup
        /api/entityGroups
        /api/groupPermission
        ...（共 15 个）

关键表
        admin_settings(key=energyDictionaries)
        admin_settings 或资产属性
        admin_settings(key=energyDictionaries), device_profile.profile_data
        rate_template 资产
        rate_template / tou_scheme 资产
        厂商/型号资产 + SERVER_SCOPE 属性
```


### 实时能耗（能耗查询）

```
看板    实时能耗
看板ID  74466b60-d2bd-11f1-b794-31725d9e3862
部件    3 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.realtime_trend
        [自研] system.energy_management.realtime_kpi

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 13 个）

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 历史能耗（能耗查询）

```
看板    历史能耗
看板ID  73e6bf30-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.timeseries_chart

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 抄表功能（能耗查询）

```
看板    抄表功能
看板ID  742ca1d0-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.meter_reading_board
        [自研] system.energy_management.meter_batch_detail
        [自研] system.energy_management.meter_plan

自研接口
        /api/energy/meter-reading/batches          -> EnergyMeterReadingController.java
        /api/energy/meter-reading/records          -> EnergyMeterReadingController.java
        /api/energy/meter-reading/retry            -> EnergyMeterReadingController.java
        /api/energy/meter-reading/run              -> EnergyMeterReadingController.java
        /api/energy/meter-reading/run-plan         -> EnergyMeterReadingController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 14 个）

关键表
        meter_reading_batch, meter_reading_record
        meter_reading_record, ts_kv_latest
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 峰谷分析（能耗分析）

```
看板    峰谷分析
看板ID  745670f0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.tou_analysis

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/tou-analysis                   -> EnergyAnalysisController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        ts_kv + tou_scheme 资产
        asset, relation（场站可见性）
```

### 分项能耗（能耗分析）

```
看板    分项能耗
看板ID  7412d840-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.distribution_chart
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.analysis_bar

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 区域能耗（能耗分析）

```
看板    区域能耗
看板ID  7397b4d0-d2bd-11f1-b794-31725d9e3862
部件    5 个
        [自研] system.energy_management.ranking_list
        [自研] system.energy_management.distribution_chart
        [自研] system.energy_management.asset_stats_chart
        [自研] system.energy_management.analysis_bar
        [自研] system.energy_management.ranking_list

自研接口
        /api/energy/entity-briefs                  -> EnergyMetricParamController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/device
        /api/entitiesQuery/find
        /api/plugins/telemetry
        /api/plugins/telemetry/ASSET
        /api/relations

关键表
        asset, device（名称/档案缓存）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 用能账单（能耗分析）

```
看板    我的账单
看板ID  7431aae0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.billing_workspace

自研接口
        /api/energy/billing/crosstab               -> EnergyAnalysisController.java
        /api/energy/billing/delete                 -> EnergyBillingController.java
        /api/energy/billing/generate               -> EnergyBillingController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        energy_bill 资产 + ts_kv
        ★ energy_bill 资产（SERVER_SCOPE 属性），**不写 billing 表**
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 基础报表（综合报表）

```
看板    基础报表
看板ID  73b500d0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.basic_report_workspace

自研接口
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/telemetry-series               -> EnergyTelemetryController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 12 个）

关键表
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        ts_kv, ts_kv_latest, key_dictionary
        admin_settings
        asset, relation（场站可见性）
```

### 手工填报（综合报表）

```
看板    手工填报
看板ID  7426ae60-d2bd-11f1-b794-31725d9e3862
部件    4 个
        [自研] system.energy_management.manual_entry
        [自研] system.energy_management.query_panel
        [自研] system.energy_management.monthly_bar
        [自研] system.energy_management.device_total

自研接口
        /api/energy/manual-entry/category          -> EnergyManualEntryController.java
        /api/energy/manual-entry/meta              -> EnergyManualEntryController.java
        /api/energy/manual-entry/save              -> EnergyManualEntryController.java
        /api/energy/manual-entry/sites             -> EnergyManualEntryController.java
        /api/energy/meters                         -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/device
        /api/deviceProfileInfo
        /api/deviceProfiles
        /api/entitiesQuery/find
        /api/plugins/telemetry
        ...（共 13 个）

关键表
        ★ 资产（手工填报表）
        device, device_profile, relation, ts_kv_latest
        admin_settings(key=energyDictionaries), device_profile.profile_data
        admin_settings
        asset, relation（场站可见性）
```


### 闲时能耗（能耗优化）

```
看板    闲时能耗
看板ID  74091440-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [自研] system.idle_energy.analysis_board

自研接口
        /api/energy/idle-analysis                  -> IdleEnergyController.java
        /api/energy/idle-device                    -> IdleEnergyController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/auth/user

关键表
        ts_kv + 资产汇总
        asset, relation（场站可见性）
```

### 负载预测（能耗优化）

```
看板    负载预测
看板ID  741d86a0-d2bd-11f1-b794-31725d9e3862
部件    2 个
        [自研] system.energy_management.forecast_context
        [自研] system.energy_management.forecast_chart

自研接口
        /api/energy/forecast/context               -> EnergyForecastController.java
        /api/energy/forecast/predict               -> EnergyForecastController.java
        /api/energy/time-anchor                    -> EnergyTimeAnchorController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java

关键表
        ts_kv（历史序列）
        admin_settings
        asset, relation（场站可见性）
```

### 用能建议（能耗优化）

```
看板    用能建议
看板ID  1cebb370-da6f-11f1-aec2-1192e109281d
部件    1 个
        [自研] system.energy_management.diagnosis_brief

自研接口
        /api/energy/diagnosis/brief                -> EnergyDiagnosisController.java
        /api/energy/diagnosis/forecast             -> EnergyDiagnosisController.java
        /api/energy/diagnosis/sites                -> EnergyDiagnosisController.java
TB 原生接口
        /api/plugins/telemetry/DEVICE

关键表
        ts_kv + 计算字段
```

### 用能质量（能耗优化）

```
看板    用能质量
看板ID  1d661390-da6f-11f1-aec2-1192e109281d
部件    1 个
        [自研] system.energy_management.diagnosis_brief

自研接口
        /api/energy/diagnosis/brief                -> EnergyDiagnosisController.java
        /api/energy/diagnosis/forecast             -> EnergyDiagnosisController.java
        /api/energy/diagnosis/sites                -> EnergyDiagnosisController.java
TB 原生接口
        /api/plugins/telemetry/DEVICE

关键表
        ts_kv + 计算字段
```


### 设备运维（设备管理）

```
看板    设备运维
看板ID  a9061a40-d3ca-11f1-9ee9-c3a7be535a93
部件    2 个
        [自研] system.energy_device.ops_page
        [自研] system.energy_device.gateway_detail

自研接口
        /api/energy/alarms                         -> SiteAlarmListController.java
        /api/energy/device-config                  -> EnergyMeterReadingController.java
        /api/energy/metric-params                  -> EnergyMetricParamController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/auth/user
        /api/customer
        /api/customers
        /api/device
        /api/deviceProfile
        /api/deviceProfileInfos
        /api/plugins/telemetry/DEVICE
        ...（共 9 个）

关键表
        alarm（TB 原生）
        device + device_profile
        admin_settings(key=energyDictionaries), device_profile.profile_data
        asset, relation（场站可见性）
```

### 设备分组（设备管理）

```
看板    设备分组
看板ID  a4917020-d3cc-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_device.group_page

自研接口
        /api/energy/device-profiles/meta           -> EnergyDeviceProfileMetaController.java
        /api/energy/devices/type-meta              -> EnergyDeviceProfileMetaController.java
        /api/energy/dictionaries                   -> EnergyDictionaryController.java
        /api/energy/structure-settings             -> EnergyStructureController.java
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/asset
        /api/assetProfileInfos
        /api/auth/user
        /api/customer
        /api/customers
        /api/deviceProfileInfos
        /api/relation
        /api/relations

关键表
        device_profile.profile_data
        admin_settings(key=energyDictionaries)
        asset_profile(SERVER_SCOPE energyRole)
        asset, relation（场站可见性）
```

### 设备拓扑（设备管理）

```
看板    设备拓扑
看板ID  4dd17660-d3cf-11f1-9ee9-c3a7be535a93
部件    1 个
        [自研] system.energy_device.topology_page

自研接口
        /api/energy/topologies                     -> EnergyTopologyController.java
TB 原生接口
        /api/auth/user
        /api/customers
        /api/resource/js_module/system/cytoscape.min.js

关键表
        资产（topology 档案）+ relation
```


### 空调运行监控（空调管理）

```
看板    空调运行监控
看板ID  73f58c40-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.operation_monitor

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/overview
        /api/plugins/telemetry/DEVICE

关键表
        asset, relation（场站可见性）
```

### 运行计划与配置（空调管理）

```
看板    运行计划与配置
看板ID  74001390-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.plan_config

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/modes
        /api/hvac/plan

关键表
        asset, relation（场站可见性）
```

### 每日复盘报告（空调管理）

```
看板    每日复盘报告
看板ID  73ed9d00-d2bd-11f1-b794-31725d9e3862
部件    1 个
        [TB  ] system.hvac_management.daily_report

自研接口
        /api/energy/visible-sites                  -> EnergyRatePolicyController.java
TB 原生接口
        /api/hvac/daily-report

关键表
        asset, relation（场站可见性）
```

## 三、四个「基础设施接口」——先搞懂它们，一半页面就通了

实测统计：这 4 个接口被 10 个以上页面共用。它们不是业务逻辑，是公共前置。

| 接口 | 用在几个页面 | Controller | 干什么 |
| --- | --- | --- | --- |
| `/api/energy/visible-sites` | 18 | EnergyRatePolicyController | 当前用户能看到哪些场站（客户权限过滤） |
| `/api/energy/metric-params` | 13 | EnergyMetricParamController | 指标参数定义（单位/小数位/口径） |
| `/api/energy/time-anchor` | 12 | EnergyTimeAnchorController | 时间窗的「今天」基准日 |
| `/api/energy/meters` | 10 | EnergyMeterReadingController | 电表清单（含档案与关系） |

> **理解顺序建议**：先读 visible-sites（权限），再读 metric-params（口径），
> 再读 time-anchor（时间窗）。这三个懂了，剩下的页面只是「过滤 + 渲染」。

## 四、⭐ 告警有三套机制并存（最容易搞混）

| 机制 | 存在哪 | 当前数量 | 谁评估 | 产出 |
| --- | --- | --- | --- | --- |
| ① 设备档案告警规则 | `device_profile.profile_data` 的 `alarms` | 15 个档案 | **TB 原生**（规则链/CF） | TB 原生 alarm |
| ② 计算字段告警 | `calculated_field` 表，`type=ALARM` | 7 条 | **TB 原生** CF 引擎 | TB 原生 alarm |
| ③ 客户自建规则 | `alarm_rule` 表（当前 0 行） | 0 条 | **自研** `AlarmRuleEngine`（定时 30s） | TB 原生 alarm |

三套都最终产出 **TB 原生 alarm**，所以确认/通知/看板/TTL 清理都照旧。

> 第 ③ 套就是「客户用户可以根据自身情况创建告警规则」的实现，
> 见 `AlarmRuleCrudController` 类注释。现在 0 行说明还没有客户建过规则。
> 当前 8,638 条告警中，8,593 条来自「功率因数偏低」——属于第 ①/② 套。

## 五、⚠️ 表名对得上，但数据不在那

这是最容易误导人的地方。三种情况要分清：

| 表 | 行数 | 真实情况 | 判断依据 |
| --- | --- | --- | --- |
| `billing` / `billing_detail` | **0** | **死表**。账单实际写 `energy_bill` 资产 + SERVER_SCOPE 属性 | `EnergyBillingController:106` 注释明确：「出账把结果写成 energy_bill 资产 + SERVER_SCOPE 属性（**不写 billing 表**）」 |
| `alarm_rule` / `alarm_rule_state` | **0** | **活着但没人用**。规则设计在这，还没客户建过 | 表由 `EnergySchemaInstaller:558` 创建，`AlarmRuleCrudController` 有完整 CRUD |
| `meter_reading_record` | **8** | **在用**，抄表记录明细 | 配套 `meter_reading_batch` 19 行 |

> **只有 `billing` 是真死表**（早期设计用表，后来改成资产，表没删）。
> 它现在只被 `EnergyCustomerPurgeController` 的清理清单引用。
>
> `alarm_rule` 是「功能已上线、尚未使用」——这是客户自建告警规则的存储，
> 现在 0 行说明还没有客户建过。
>
> **判据**：查数据前先 `SELECT count(*)`，别假设表名对就有数据。

## 六、关键表速查

| 你要查什么 | 查哪 |
| --- | --- |
| 有什么设备/资产/场站 | `device` / `asset` / `asset_profile` / `device_profile` |
| 谁归属谁 | `relation`（注意 `Contains` 和 `SiteContains` 两套口径） |
| 设备最新值 | `ts_kv_latest` + `key_dictionary` |
| 设备历史序列 | `ts_kv` + `key_dictionary` |
| 资产汇总（场站/分项/区域） | `ts_kv_latest`，entity 是 ASSET，key=`energy_total`/`power_total`/`energy_day` |
| 看板与部件 | `dashboard.configuration`（JSON） |
| 部件脚本 | `widget_type.descriptor.controllerScript` |
| 菜单 | `custom_menu.config` |
| [告警](#告警事件) | `alarm`（TB 原生，8638 条） |
| [抄表](#抄表功能-能耗查询) | `meter_reading_batch` / `meter_reading_record` |
| 账单 | `energy_bill` **资产**，不是 `billing` 表 |
| 盘查报告口径 | `audit_report_version` **资产** |
| [节能记录](#节能记录) | `saving_record` **资产** |
| 字典/口径参数 | `admin_settings` 里 key=`energyDictionaries` |
| 版本控制 | `admin_settings` 里 key=`entitiesVersionControl` |

**资产类数据的一个通用查法**（账单/盘查报告/节能记录都适用）：

```sql
SELECT a.name, k.key,
       coalesce(av.str_v, av.long_v::text, av.dbl_v::text, av.bool_v::text) AS val
FROM asset a
JOIN attribute_kv av ON av.entity_id = a.id AND av.attribute_type = 2   -- 2 = SERVER_SCOPE
JOIN key_dictionary k ON k.key_id = av.attribute_key
JOIN asset_profile p ON p.id = a.asset_profile_id
WHERE p.name = 'energy_bill'   -- 换成 audit_report_version / saving_record
ORDER BY a.name, k.key;
```

实跑输出（节选）：

```
BILL-7CE48900-2026-10-elec-7E9434D0   amount       3950.73
BILL-7CE48900-2026-10-elec-7E9434D0   basicFee     1500.00
BILL-7CE48900-2026-10-elec-7E9434D0   status       draft
BILL-7CE48900-2026-10-elec-7E9434D0   energy       elec
```

> ⚠️ **两个必须知道的字段陷阱**（踩过才知道）：
> - `attribute_kv.attribute_type` 是**整数枚举**，不是字符串：
>   `2 = SERVER_SCOPE`（1,516 行，业务数据几乎都在这）、`3 = SHARED_SCOPE`（18 行）。
>   写 `= 'SERVER_SCOPE'` 会报 `invalid input syntax for type integer`。
> - 数值列叫 `dbl_v`，不是 `double_v`。

## 七、怎么重新生成这份索引

这份文档的全部数据都是脚本提取的，**改了看板或代码后请重跑，不要手改**。

保存下面脚本为 `genpage.py`，在仓库根目录运行：

```python
#!/usr/bin/env python3
"""生成页面链路索引。在仓库根目录运行：python3 genpage.py"""
import json, re, glob, os, subprocess

PSQL = ['docker','exec','-i','energy-postgres','psql','-U','postgres','-d','thingsboard','-tA','-c']
def sql(q):
    return subprocess.run(PSQL+[q], capture_output=True, text=True).stdout

# 1) 菜单与看板
menu = json.loads(sql("SELECT config FROM custom_menu WHERE name LIKE '业务导航%';"))
dash = {d['id']: d for d in json.loads(sql(
    "SELECT json_agg(json_build_object('id',d.id::text,'title',d.title,"
    "'widgets',(SELECT json_agg(w.value->>'typeFullFqn')"
    " FROM jsonb_each((d.configuration::jsonb)->'widgets') w))) FROM dashboard d;"))}

# 2) 部件脚本里的接口
wf = {}
for f in glob.glob('guard-server/src/main/data/json/system/widget_types/*.json'):
    try: wf[json.load(open(f, encoding='utf-8'))['fqn']] = f
    except Exception: pass

def apis(fqn):
    f = wf.get(fqn) or wf.get(fqn.replace('system.', '', 1))
    if not f: return []
    try: s = json.load(open(f, encoding='utf-8'))['descriptor'].get('controllerScript', '')
    except Exception: return []
    return sorted({m.group(1).rstrip('/') for m in
                   re.finditer(r"['\"](/api/[a-zA-Z0-9_/\-{}.$]+)", s)})

# 3) 端点 -> Controller
ctrl = {}
for f in glob.glob('guard-server/src/main/java/com/guard/server/controller/*.java'):
    for m in re.finditer(r'@(?:Get|Post|Put|Delete)Mapping\(\s*(?:value\s*=\s*)?"([^"]+)"',
                         open(f, encoding='utf-8', errors='ignore').read()):
        p = m.group(1); p = '/api'+p if not p.startswith('/api') else p
        ctrl.setdefault(p,set()).add(os.path.basename(f)[:-5])

# 4) 遍历菜单
pages = []
def walk(ms, parent=''):
    for m in ms:
        did = m.get('dashboardId')
        did = did.get('id') if isinstance(did, dict) else did
        if m.get('pages') or m.get('children'):
            for k in ('pages','children'):
                if m.get(k): walk(m[k], m.get('name'))
        else: pages.append((parent, m.get('name'), did))
walk(menu.get('items', []))

# 5) 输出
print('# 客户页面链路索引\n')
print('| 页面 | 看板 | 部件 | 自研接口 | Controller |')
print('| --- | --- | --- | --- | --- |')
for parent, name, did in pages:
    d = dash.get(did) or {}
    wl = d.get('widgets') or []
    a = sorted({x for f in wl for x in apis(f) if '/energy/' in x})
    c = sorted({y for x in a for y in ctrl.get(x, ())})
    label = (parent+' / ' if parent else '') + name
    print('| %s | %s | %d | %d | %s |' % (label, d.get('title','-'), len(wl), len(a),
                                          ', '.join(c[:3]) + ('…' if len(c)>3 else '')))
```

```bash
python3 genpage.py > /tmp/gen.md
cp /tmp/gen.md shiyongshouce/content/admin/12-page-map.md   # 手册版（唯一权威）
cp /tmp/gen.md docs/PAGE-MAP.md                              # 仓库内快照
cd shiyongshouce && ./sync.sh                                # 同步到发布目录
```

> 两份内容必须一致：手册版是给人看的权威版本，`docs/` 是仓库内快照。
> 改完跑上面三行，不要只改一处。

脚本干什么：

1. 从 `custom_menu` 读菜单 → 页面与 `dashboardId`
2. 从 `dashboard.configuration.widgets` 读每个看板用了哪些部件
3. 扫 `widget_type.descriptor.controllerScript`，正则提取 `/api/...` 字面量
4. 扫 `controller/*.java` 的 `@*Mapping`，建立端点 → Controller 映射
5. 交叉输出

> 实测：26 个页面、54 个自研接口，**全部 54 个都能匹配到 Controller**。
> 如果重跑后出现未匹配，说明新加的端点路径和正则不匹配（只匹配
> `@GetMapping("...")` 字面量形式，动态拼接的路径抓不到）。

---

相关文档：[架构导航](/admin/architecture)（四步倒推法）· 
[④ 数据模型](/admin/data-model)（数据模型）· 
[⑧ 运维 SQL](/admin/ops-sql)（运维 SQL 1652 行）
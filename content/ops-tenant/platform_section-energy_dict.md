<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 运营配置 / 品种指标

> 菜单位置：运维管理 / 租户 / 运营配置 / 品种指标

> 页面路径：`/energy-dict`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `energy_dict` |
| 路径 | `/energy-dict` |
| 数据表 | `admin_settings` |

## 核对 SQL（可直接复制运行）

### 1. 品种指标字典（标准 key）

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT count(*) AS 字典项数,
       left(json_value, 120) AS 内容开头
FROM admin_settings
WHERE key = 'energyDictionaries'
GROUP BY json_value;
SQL
```

**本机实测结果**（前 1 行）：

| 字典项数 | 内容开头 |
| --- | --- |
| 1 | {"protocol":{"name":"协议支持","items":[{"code":"MQTT","name":"MQTT"},{"co |

**判据**：标准 key 改了会影响所有看板取数；改前先备份（手册 ④ 有对照表）。

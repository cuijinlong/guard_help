<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 数据处理 / 计算字段

> 菜单位置：运维管理 / 租户 / 数据处理 / 计算字段

> 页面路径：`/calculatedFields`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `calculated_fields` |
| 路径 | `/calculatedFields` |
| 数据表 | `calculated_field`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 计算字段

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT name AS 名称, type AS 类型, entity_type AS 实体类型, count(*) OVER () AS 总数
FROM calculated_field
WHERE tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY entity_type, name;
SQL
```

**本机实测结果**（前 8 行）：

| 名称 | 类型 | 实体类型 | 总数 |
| --- | --- | --- | --- |
| 功率因数偏低 | ALARM | DEVICE_PROFILE | 11 |
| 功率因数偏低 | ALARM | DEVICE_PROFILE | 11 |
| 电压不平衡度超限 | ALARM | DEVICE_PROFILE | 11 |
| 电压越限 | ALARM | DEVICE_PROFILE | 11 |
| 电压越限 | ALARM | DEVICE_PROFILE | 11 |
| 碳排放 | SIMPLE | DEVICE_PROFILE | 11 |
| 碳排放 | SIMPLE | DEVICE_PROFILE | 11 |
| 负荷率 | SIMPLE | DEVICE_PROFILE | 11 |

**判据**：字段配了但看板上没数 → 看 `entity_type` 与实体是否匹配、规则链是否在跑。

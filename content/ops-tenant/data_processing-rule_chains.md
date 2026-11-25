<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 数据处理 / 规则链

> 菜单位置：运维管理 / 租户 / 数据处理 / 规则链

> 页面路径：`/ruleChains`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `rule_chains` |
| 路径 | `/ruleChains` |
| 数据表 | `rule_chain`、`rule_node`、`tenant` |

## 核对 SQL（可直接复制运行）

### 1. 规则链与节点数

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT rc.name AS 规则链, rc.root AS 根链,
       (SELECT count(*) FROM rule_node rn WHERE rn.rule_chain_id = rc.id) AS 节点数
FROM rule_chain rc
WHERE rc.tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) ORDER BY rc.root DESC, rc.name;
SQL
```

**本机实测结果**（前 2 行）：

| 规则链 | 根链 | 节点数 |
| --- | --- | --- |
| Edge Root Rule Chain | t | 11 |
| Root Rule Chain | t | 18 |

**判据**：根链只能有一条。设备上报没进库 → 先确认根链里有「保存遥测」节点。

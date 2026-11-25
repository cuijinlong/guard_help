<!-- 由 tools/gen-ops-tenant-pages.py 生成，不要手改 -->

# 白标 / 邮件模板

> 菜单位置：运维管理 / 租户 / 白标 / 邮件模板

> 页面路径：`/white-labeling/mail-template`

## 这个功能的数据在哪

| 项 | 值 |
| --- | --- |
| 菜单 id | `mail_templates` |
| 路径 | `/white-labeling/mail-template` |
| 数据表 | `tenant`、`white_labeling` |

## 核对 SQL（可直接复制运行）

### 1. 邮件模板

```bash
docker exec -i energy-postgres psql -U administrator -d guarddb <<'SQL'
SELECT coalesce(type::text, '(未设)') AS 类型, left(settings::text, 200) AS 内容
FROM white_labeling
WHERE type::text = 'MAIL_TEMPLATES' AND (tenant_id = (SELECT id FROM tenant WHERE title = '星河能源集团' LIMIT 1) OR tenant_id IS NULL);
SQL
```

**本机实测结果：0 行**（类型、内容）

**判据**：变量占位符写错时邮件内容空白，但发送仍显示成功。

> ⚠ 0 行的：1. 邮件模板 —— 先确认是不是「本来就没启用/没数据」。

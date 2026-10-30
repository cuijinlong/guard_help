#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
网关专题页中文化 —— 可重复执行的补丁脚本

<h3>为什么需要一个脚本而不是一次性改库</h3>
TB 的网关专题页（`/entities/gateways`）来自
`https://github.com/thingsboard/gateway-management-extensions-dist.git`，
后端 `DashboardSyncService` 每次启动会把仓库里的 `gateways_dashboard.json`
直接写进 `resource` 表 —— 手动改的库**每次重启都会被打回英文**。
（2026-10-29 实测踩过：改完中文验证通过，重启后又变回 `Gateway list`。）

所以：
  ① `docker-compose.yml` 里已设 `TB_GATEWAY_DASHBOARD_SYNC_ENABLED=false` 停掉覆盖；
  ② 本脚本负责把中文补丁打进库，可反复执行（幂等）。

<h3>只翻显示字段</h3>
`dataKeys[].name` 是去设备取数的**技术键**（`voltage_a` / `energy_reading`…），
翻成中文会让表头变中文但数据全空。本脚本只改：

  settings.entitiesTitle / settings.entityNameColumnTitle / config.title
  dataKeys[].label / states.*.name / actions.headerButton[].name
  postFuncBody 与 cellContentFunction 里的 "Active" / "Inactive"

用法（在部署目录内）：

    python3 scripts/33-zh-gateway-dashboard.py            # 打补丁
    python3 scripts/33-zh-gateway-dashboard.py --check    # 只看会改哪些
    python3 scripts/33-zh-gateway-dashboard.py --restore  # 从备份恢复

退出码：0 = 成功；1 = 找不到资源 / 数据库不可用
"""

import argparse
import base64
import json
import re
import subprocess
import sys

CONTAINER = "energy-postgres"
DB = "thingsboard"
RESOURCE_KEY = "gateways_dashboard.json"

# 显示字段：只在放行清单里的键才替换
DISPLAY_KEYS = {
    "entitiesTitle",
    "entityNameColumnTitle",
    "title",
    "label",
}

TEXT = {
    # 列表 / 通用
    "Gateway list": "网关列表",
    "Gateway List": "网关列表",
    "Devices": "设备",
    "Device Name": "设备名称",
    "Created time": "创建时间",
    "Gateway name": "网关名称",
    "Status": "状态",
    "Enabled Connectors": "启用连接器",
    "Version": "版本",
    "Connector Name": "连接器名称",
    "Connector Type": "连接器类型",
    "Device Type": "设备类型",
    "Name": "名称",
    "Severity": "级别",
    "Type": "类型",
    "details": "详情",
    "Status": "状态",
    "Alarms": "告警",
    "Connectors": "连接器",
    # 详情页
    "General configuration": "通用配置",
    "Connectors configuration": "连接器配置",
    "Logs": "日志",
    "Statistics": "统计",
    "Remote Shell": "远程终端",
    "RPC": "RPC 调用",
    "Configuration": "配置",
    "Gateway devices": "网关设备",
    "Gateway custom statistics": "网关自定义统计",
    "New Gateway configuration": "新网关配置",
    "New Gateway connector": "新建网关连接器",
    "Connector RPC": "连接器 RPC",
    "Storage statistics": "存储统计",
    "Storage statistics info": "存储统计详情",
    "Machine statistics": "系统统计",
    "Machine statistics info": "系统统计详情",
    "Machine resources": "系统资源",
    "Custom statistics": "自定义统计",
    # 动作
    "Add Gateway": "添加网关",
    "Auto-provision": "自动开通",
    "Delete gateway": "删除网关",
    "Launch command": "启动命令",
    # 卡片
    "HTML Card": "HTML 卡片",
    "Markdown/HTML Card": "Markdown/HTML 卡片",
    # RPC 子页
    "RPC remote shell": "RPC 远程终端",
    "RPC Logs": "RPC 日志",
    "RPC debug terminal": "RPC 调试终端",
    "Service RPC": "服务 RPC",
    "Service command": "服务命令",
    "${connectorName} logs": "${connectorName} 日志",
}

# 部件脚本内部的字面量。<b>必须逐条精确匹配</b> —— 这里是 JS 源码区，
# 一个正则写松了就可能改到数据键（data[0].Name）、state id（gateway_devices_modbus）。
#
# 目前只有一处：网关设备卡片的 tab（label 硬编码在 markdownTextFunction 里）
JS_LITERAL = [
    ('<mat-tab label="All"', '<mat-tab label="全部"'),
]

BACKUP_KEY = "gateways_dashboard.json.zh-backup"


def psql(sql, want_output=False):
    """
    执行 SQL。

    <p><b>不能把 SQL 放进 -c 参数</b>：dashboard 的 base64 约 280KB，
    单参数超过 macOS 的 256KB 上限，命令会直接失败且报错为空（踩过）。
    这里一律走 stdin。
    """
    args = ["docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", "-d", DB, "-tA"]
    if want_output:
        args.append("-q")
    r = subprocess.run(args, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        print("数据库命令失败:", (r.stderr or r.stdout).strip()[:400], file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip() if want_output else None


def load_resource():
    raw = psql(
        "SELECT encode(data,'base64') FROM resource"
        f" WHERE resource_key='{RESOURCE_KEY}' AND resource_type='DASHBOARD'",
        want_output=True,
    )
    if not raw:
        print(f"找不到系统资源 {RESOURCE_KEY}", file=sys.stderr)
        sys.exit(1)
    return json.loads(base64.b64decode("".join(raw.split())))


def save_resource(doc):
    payload = base64.b64encode(
        json.dumps(doc, ensure_ascii=False).encode("utf-8")
    ).decode("ascii")
    psql(
        "UPDATE resource SET data = decode("
        f"'{payload}','base64') WHERE resource_key='{RESOURCE_KEY}'"
        " AND resource_type='DASHBOARD'"
    )


def protected_labels(widget_cfg):
    """
    找出**被当数据键引用**的 label，这些一个都不能翻。

    <h3>为什么</h3>
    部件的 `data[n].<KEY>` 里，KEY 取的是 dataKey 的 **label**（不是 name）。
    例如网关详情顶部的 markdown 卡片写死了 `data[0].Name`，
    如果对应的 dataKey 是 `label='Name'`，把 label 翻成「名称」以后
    `data[0].Name` 就是 undefined —— 界面上直接显示 `null`
    （2026-10-29 实测：「网关名称」变 null，「状态」「版本」整块消失）。

    label 在这类部件里**不显示给用户**（显示的是 createDataBlock 的第二个参数，
    走 `{{ 'xxx' | translate }}`），所以保留英文没有任何副作用。
    """
    blob = json.dumps(widget_cfg or {}, ensure_ascii=False)
    return set(re.findall(r"data\[\d+\]\.([A-Za-z_\u4e00-\u9fff][\w\u4e00-\u9fff]*)", blob))


def patch(doc, check_only=False):
    """把中文补丁打进 dashboard 文档，返回改动条目列表。"""
    changes = []
    skipped = []
    cfg = doc.get("configuration") or {}
    def walk(node, where, protected):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in DISPLAY_KEYS and isinstance(value, str) and value in TEXT:
                    if key == "label" and value in protected:
                        skipped.append(f"{where}.{key}: {value!r}（被 data[n] 引用，保留英文）")
                        continue
                    changes.append(f"{where}.{key}: {value!r} → {TEXT[value]!r}")
                    if not check_only:
                        node[key] = TEXT[value]
                else:
                    walk(value, f"{where}.{key}", protected)
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(value, f"{where}[{i}]", protected)

    # ① 部件标题、表头 label、列表标题
    #    protected 按**单个部件**算 —— 列表 widget 的 Status 该翻，
    #    markdown_card 里被 data[0].Status 引用的那个不翻，两者互不影响。
    for wid, widget in (cfg.get("widgets") or {}).items():
        wcfg = widget.get("config") or {}
        walk(wcfg, f"widget[{wid[:8]}]", protected_labels(wcfg))

    # ② 面包屑（state 名）
    for sid, state in (cfg.get("states") or {}).items():
        name = state.get("name")
        if isinstance(name, str) and name in TEXT:
            changes.append(f"state[{sid}].name: {name!r} → {TEXT[name]!r}")
            if not check_only:
                state["name"] = TEXT[name]

    # ③ 列表右上角「添加网关」按钮
    def walk_actions(node, where):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "name" and isinstance(value, str) and value == "Add Gateway":
                    changes.append(f"{where}.name: 'Add Gateway' → '添加网关'")
                    if not check_only:
                        node[key] = "添加网关"
                else:
                    walk_actions(value, f"{where}.{key}")
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk_actions(value, f"{where}[{i}]")

    walk_actions(cfg.get("actions") or {}, "actions")
    for wid, widget in (cfg.get("widgets") or {}).items():
        walk_actions((widget.get("config") or {}).get("actions") or {}, f"widget[{wid[:8]}].actions")

    # ④ 部件脚本里的字面量（精确片段替换）
    def walk_js(node, where):
        if isinstance(node, dict):
            for key, value in node.items():
                if isinstance(value, str) and ("<mat-tab" in value or "markdown" in key.lower()):
                    for old, new in JS_LITERAL:
                        if old in value:
                            changes.append(f"{where}.{key}: {old!r} → {new!r}")
                            if not check_only:
                                node[key] = value.replace(old, new)
                            value = node[key]
                walk_js(value, f"{where}.{key}")
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk_js(value, f"{where}[{i}]")

    for wid, widget in (cfg.get("widgets") or {}).items():
        walk_js(widget.get("config") or {}, f"widget[{wid[:8]}]")

    # ⑤ 在线/离线 —— 不是字面量，藏在 postFuncBody / cellContentFunction 的小脚本里
    for wid, widget in (cfg.get("widgets") or {}).items():
        for ds in ((widget.get("config") or {}).get("datasources") or []):
            for dk in (ds.get("dataKeys") or []):
                body = dk.get("postFuncBody")
                if isinstance(body, str) and '"Active"' in body:
                    changes.append(f"widget[{wid[:8]}].postFuncBody: Active/Inactive → 在线/离线")
                    if not check_only:
                        dk["postFuncBody"] = body.replace('"Active"', '"在线"').replace('"Inactive"', '"离线"')
                cell = (dk.get("settings") or {}).get("cellContentFunction")
                if isinstance(cell, str) and '"Active"' in cell:
                    changes.append(f"widget[{wid[:8]}].cellContentFunction: Active/Inactive → 在线/离线")
                    if not check_only:
                        dk["settings"]["cellContentFunction"] = (
                            cell.replace('"Active"', '"在线"').replace('"Inactive"', '"离线"')
                        )

    return changes, skipped


def verify(doc):
    """
    补丁后的自检：**取数用的技术键**一个都不能被翻成中文。

    只看 `dataKeys[].name` —— 它是去设备上取遥测/属性的键名
    （`voltage_a` / `energy_reading`…），翻成中文的后果是表头变中文、数据全空。

    下面这些 name 是**显示用**的，本来就该是中文，不在检查范围：
      * `configuration.states.*.name`      —— 面包屑
      * `actions...headerButton[].name`    —— 按钮文字
    """
    problems = []

    def is_cn(text):
        return any("\u4e00" <= ch <= "\u9fff" for ch in text)

    def collect(node, path):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "dataKeys" and isinstance(value, list):
                    for i, dk in enumerate(value):
                        if isinstance(dk, dict):
                            name = dk.get("name")
                            if isinstance(name, str) and is_cn(name):
                                problems.append(
                                    f"{path}.dataKeys[{i}].name = {name!r}（取数技术键被翻成中文）"
                                )
                collect(value, f"{path}.{key}")
        elif isinstance(node, list):
            for i, value in enumerate(node):
                collect(value, f"{path}[{i}]")

    collect(doc.get("configuration") or {}, "configuration")
    return problems


def main():
    ap = argparse.ArgumentParser(description="网关专题页中文化（幂等）")
    ap.add_argument("--check", action="store_true", help="只列出会改哪些，不写库")
    ap.add_argument("--restore", action="store_true", help="从备份恢复英文原版")
    args = ap.parse_args()

    if args.restore:
        raw = psql(
            "SELECT encode(data,'base64') FROM resource"
            f" WHERE resource_key='{BACKUP_KEY}'",
            want_output=True,
        )
        if not raw:
            print("没有备份可恢复", file=sys.stderr)
            sys.exit(1)
        psql(
            "UPDATE resource SET data = (SELECT data FROM resource"
            f" WHERE resource_key='{BACKUP_KEY}') WHERE resource_key='{RESOURCE_KEY}'"
            " AND resource_type='DASHBOARD'"
        )
        print("已恢复英文原版")
        return

    doc = load_resource()

    if not args.check:
        # 首次打补丁前留一份英文原版（已存在就不覆盖，保证备份是最初的）
        exists = psql(
            f"SELECT count(*) FROM resource WHERE resource_key='{BACKUP_KEY}'",
            want_output=True,
        )
        if exists == "0":
            payload = base64.b64encode(
                json.dumps(doc, ensure_ascii=False).encode("utf-8")
            ).decode("ascii")
            psql(
                "INSERT INTO resource (id, created_time, tenant_id, title, resource_type,"
                " resource_key, file_name, data, etag, search_text)"
                " SELECT gen_random_uuid(), extract(epoch from now())*1000, tenant_id,"
                f" title, resource_type, '{BACKUP_KEY}', file_name, decode('{payload}','base64'),"
                " etag, search_text FROM resource"
                f" WHERE resource_key='{RESOURCE_KEY}' AND resource_type='DASHBOARD'"
            )
            print(f"已备份英文原版 → {BACKUP_KEY}")

    changes, skipped = patch(doc, check_only=args.check)

    if args.check:
        print(f"将改动 {len(changes)} 处：")
        for c in changes[:40]:
            print("  ", c)
        if len(changes) > 40:
            print(f"   ... 共 {len(changes)} 处")
        if skipped:
            print(f"\n保留英文 {len(skipped)} 处（被 data[n] 引用，翻了会让数据变 null）：")
            for c in skipped:
                print("  ", c)
        return

    problems = verify(doc)
    if problems:
        print("自检失败，未写库：", file=sys.stderr)
        for p in problems[:10]:
            print("  ", p, file=sys.stderr)
        sys.exit(1)

    save_resource(doc)
    print(f"已写入中文补丁，共 {len(changes)} 处")
    print("浏览器硬刷新（Ctrl/Cmd + Shift + R）后生效")


if __name__ == "__main__":
    main()

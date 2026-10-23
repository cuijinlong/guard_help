#!/usr/bin/env python3
"""
手册一致性检查：代码/资源里的事实 vs 手册里写的数字。

## 为什么需要它

手册里的数字（菜单几项、档案几个、指标几条）是**手写**的，
而代码在持续改。改了代码忘了改手册，下次照手册部署就会：
  - 看不到手册承诺的菜单项，以为是部署失败
  - 按手册的指标数量对不上，以为数据没初始化全
  - 在已删除的页面路径上找功能

这类问题不报错、不影响运行，但会让运维照着文档做却得不到预期结果 ——
比功能 bug 更难排查，因为「文档说该有」。

## 检查什么

只检查**能从代码精确算出来**的项。算不出来的（比如某句话描述得对不对）
不在这里管，靠人工评审。

## 用法

    ./check-docs.py            # 检查，有问题退出码 1
    ./check-docs.py -v         # 额外打印每项的来源

建议在提交前跑，或者接进 CI。

## 怎么加新检查

在 CHECKS 列表里加一项：
    Check('键', '手册里的人类可读名', lambda repo: 实际值, '手册文件', r'正则')
正则的第 1 个捕获组必须是数字。
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent          # shiyongshouce/
REPO = ROOT.parent                              # 仓库根
GS = REPO / 'guard-server' / 'src' / 'main'
JAVA_INSTALL = GS / 'java' / 'com' / 'guard' / 'server' / 'service' / 'install'
RES_ENERGY = GS / 'resources' / 'data' / 'json' / 'system' / 'energy'
DASHBOARDS = GS / 'data' / 'json' / 'tenant' / 'dashboards'
DOCS = ROOT / 'content' / 'admin'
DOWNLOADS = ROOT / 'downloads'


# ----------------------------------------------------------------------
# 各项事实的提取函数
# ----------------------------------------------------------------------

def _read(p: Path) -> str:
    return p.read_text(encoding='utf-8')


def count_asset_profiles(_repo) -> int:
    """资产档案数：AssetProfileInstaller.ASSET_PROFILES 里 put(...) 的条数"""
    src = _read(JAVA_INSTALL / 'AssetProfileInstaller.java')
    # 只数 static 块里的 put("名字", "说明")
    m = re.search(r'ASSET_PROFILES\s*=\s*new LinkedHashMap<>\(\)\s*\{\{(.*?)\n    \}\}', src, re.S)
    if not m:
        raise RuntimeError('AssetProfileInstaller: 找不到 ASSET_PROFILES 定义')
    return len(re.findall(r'^\s*put\("', m.group(1), re.M))


def count_device_profiles(_repo) -> int:
    doc = json.loads(_read(RES_ENERGY / 'meter_types.json'))
    return len(doc.get('profiles', []))


def count_rules(_repo) -> int:
    """
    告警 + 派生指标总数。

    单相 = 除「不平衡度」外的全部；三相 = 全部。
    判定方式：installForProfile 里 `if (!singlePhase) { created += ensureXxx }`
    包住的那些，只对三相生效。
    """
    src = _read(JAVA_INSTALL / 'DeviceRuleInstaller.java')
    body = re.search(r'private int installForProfile\(.*?\n    \}', src, re.S)
    if not body:
        raise RuntimeError('DeviceRuleInstaller: 找不到 installForProfile')
    text = body.group(0)
    all_calls = len(re.findall(r'created \+= ensure\w+\(', text))
    # if (!singlePhase) { ... } 里的调用只对三相生效
    tri_only = 0
    for guard in re.findall(r'if\s*\(!singlePhase\)\s*\{(.*?)\}', text, re.S):
        tri_only += len(re.findall(r'created \+= ensure\w+\(', guard))
    single = all_calls - tri_only
    return single + all_calls      # 单相 + 三相


def count_energy_kinds(_repo) -> int:
    doc = json.loads(_read(RES_ENERGY / 'energy_library.json'))
    return len(doc.get('kinds', []))


def _elec_params():
    doc = json.loads(_read(RES_ENERGY / 'energy_library.json'))
    for k in doc.get('kinds', []):
        if k.get('code') == 'elec':
            return k.get('params', [])
    raise RuntimeError('energy_library.json: 找不到 elec 品种')


def count_elec_params(_repo) -> int:
    """电能一级指标数"""
    return len(_elec_params())


def count_elec_keys(_repo) -> int:
    """电能二级 key 总数"""
    return sum(len(p.get('children', [])) for p in _elec_params())


def count_tou_schemes(_repo) -> int:
    """分时方案数：createTouScheme(tenantId, ...) 的调用次数"""
    src = _read(JAVA_INSTALL / 'EnergyLibraryInstaller.java')
    body = re.search(r'private void createTouSchemes\(.*?\n    \}', src, re.S)
    if not body:
        raise RuntimeError('EnergyLibraryInstaller: 找不到 createTouSchemes')
    return len(re.findall(r'createTouScheme\(tenantId,', body.group(0)))


def count_rate_templates(_repo) -> int:
    """费率模板数：createRateTemplate(tenantId, ...) 的调用次数（不含 linkTouSchemes 等）"""
    src = _read(JAVA_INSTALL / 'EnergyLibraryInstaller.java')
    body = re.search(r'private void createRateTemplates\(.*?\n    \}', src, re.S)
    if not body:
        raise RuntimeError('EnergyLibraryInstaller: 找不到 createRateTemplates')
    return len(re.findall(r'createRateTemplate\(tenantId,', body.group(0)))


def count_org_tabs(_repo) -> int:
    """组织节点右侧页签数：读 sites.component.html 里 type !== '场站' 的 tab 组"""
    src = _read(REPO / 'ui-ngx' / 'src' / 'app' / 'modules' / 'home' / 'pages' / 'sites'
                / 'sites.component.html')
    m = re.search(r"<mat-tab-group \*ngIf=\"selectedNode\.type !== '场站'\".*?</mat-tab-group>",
                  src, re.S)
    if not m:
        raise RuntimeError('sites.component.html: 找不到组织页签组')
    return len(re.findall(r'<mat-tab[ >]', m.group(0)))


def count_verify_items(_repo) -> int:
    """
    发布验收项数：读 08-verify-release.sh 里的 EXPECTED_PASS。

    不静态数 ok/ge/eq 调用 —— 有些断言在 if/else 分支里，
    实际执行到哪一支取决于数据，静态统计会得出错误项数。
    脚本自己会在结尾用这个常量自校验，所以它是唯一可信来源。
    """
    src = _read(DOWNLOADS / 'scripts' / '08-verify-release.sh')
    m = re.search(r'^EXPECTED_PASS=(\d+)\s*$', src, re.M)
    if not m:
        raise RuntimeError('08-verify-release.sh: 找不到 EXPECTED_PASS')
    return int(m.group(1))


def count_dashboards(_repo) -> int:
    return len(list(DASHBOARDS.glob('*.json')))


def count_tenant_menu(_repo) -> int:
    """
    租户菜单顶层项数 = items.add(...) 的次数。
    DEFAULT 引用是循环里批量加的，按数组元素个数算。
    """
    src = _read(JAVA_INSTALL / 'EnergyMenuInstaller.java')
    body = re.search(r'private List<MenuItem> tenantItems\(.*?\n    \}', src, re.S)
    if not body:
        raise RuntimeError('EnergyMenuInstaller: 找不到 tenantItems')
    text = body.group(0)
    # for (String id : new String[]{ ... }) 里的元素
    m = re.search(r'new String\[\]\s*\{(.*?)\}', text, re.S)
    loop = len(re.findall(r'"\w+"', m.group(1))) if m else 0
    # 直接 add 的项：先把整个 for 循环剔除，否则循环体里的 items.add 会被重复计数
    outside = re.sub(r'for\s*\(String id\s*:\s*new String\[\]\s*\{.*?\}\)\s*\{.*?\}',
                     '', text, flags=re.S)
    direct = len(re.findall(r'^\s*items\.add\(', outside, re.M))
    return direct + loop


def count_customer_menu(_repo) -> int:
    src = _read(JAVA_INSTALL / 'EnergyMenuInstaller.java')
    body = re.search(r'private List<MenuItem> customerItems\(.*?\n    \}', src, re.S)
    if not body:
        raise RuntimeError('EnergyMenuInstaller: 找不到 customerItems')
    return len(re.findall(r'^\s*items\.add\(', body.group(0), re.M))


# ----------------------------------------------------------------------
# 检查项：代码事实 ↔ 手册声明
# ----------------------------------------------------------------------

class Check:
    """
    一项事实。

    `targets` 是 [(手册文件, 正则), ...] —— 手册里同一个数字常常出现在多处
    （初始化清单、部署完成状态表、章节标题）。只检查其中一处，改了别处照样不一致，
    所以这里要求**所有位置都必须匹配且数值相同**。
    """

    def __init__(self, key, label, fn, targets):
        self.key = key
        self.label = label
        self.fn = fn
        self.targets = targets    # [(file, regex), ...]，正则第 1 组是数字


CHECKS = [
    Check('asset_profiles', '资产档案', count_asset_profiles, [
        ('03-init.md', r'\| 资产档案 \| 建租户时自动 \| (\d+) 个'),
        ('03-init.md', r'- 资产档案（(\d+) 个）'),
        ('02-deploy.md', r'\| 资产档案 \| (\d+) 个 \|'),
        ('02-deploy.md', r'资产档案 (\d+) 个 / 设备档案'),
    ]),
    Check('device_profiles', '设备档案', count_device_profiles, [
        ('03-init.md', r'\| 设备档案 \| 建租户时自动 \| (\d+) 个'),
        ('03-init.md', r'## 四、设备档案（(\d+) 个）'),
        ('02-deploy.md', r'\| 设备档案 \| (\d+) 个 \|'),
        ('02-deploy.md', r'/ 设备档案 (\d+) 个'),
    ]),
    Check('rules', '告警 + 派生指标', count_rules, [
        ('03-init.md', r'\| 告警规则 \+ 派生指标 \| 建租户时自动 \| (\d+) 条'),
        ('03-init.md', r'- 设备档案上的告警规则 \+ 派生指标（(\d+) 条）'),
        ('02-deploy.md', r'\| 告警 / 派生指标 \| (\d+) 条 \|'),
    ]),
    Check('kinds', '能源品种', count_energy_kinds, [
        ('03-init.md', r'\| 能源参数字典 \| 建租户时自动 \| (\d+) 品种'),
    ]),
    Check('elec_params', '电能一级指标', count_elec_params, [
        ('03-init.md', r'\| 电能 \| `elec` \| kWh \| (\d+) 项一级指标'),
    ]),
    Check('elec_keys', '电能二级 key', count_elec_keys, [
        ('03-init.md', r'\d+ 项一级指标（(\d+) 个二级 key）'),
    ]),
    Check('tou', '分时时段方案', count_tou_schemes, [
        ('03-init.md', r'\| 分时时段方案 \| 建租户时自动 \| (\d+) 套'),
        ('03-init.md', r'## 五、分时时段方案（(\d+) 套）'),
    ]),
    Check('rate_templates', '费率模板', count_rate_templates, [
        ('03-init.md', r'\| 费率模板（示例价） \| 建租户时自动 \| (\d+) 个'),
    ]),
    Check('org_tabs', '组织页签', count_org_tabs, [
        ('03-init.md', r'选中组织 → (\d+) 个页签'),
    ]),
    Check('verify_items', '发布验收项数', count_verify_items, [
        ('03-init.md', r'\*\*期望\*\*：`通过 (\d+) 项`'),
        ('00-index.md', r'期望 `通过 (\d+) 项`'),
    ]),
    Check('dashboards', '看板模板', count_dashboards, [
        ('02-deploy.md', r'wc -l\s+# 必须是 (\d+)'),
    ]),
    Check('tenant_menu', '租户菜单', count_tenant_menu, [
        ('03-init.md', r'\| 租户菜单 \| 建租户时自动 \| (\d+) 个顶层项'),
        ('02-deploy.md', r'\| 租户菜单 \| (\d+) 个顶层项 \|'),
    ]),
    Check('customer_menu', '客户菜单', count_customer_menu, [
        ('03-init.md', r'\| 客户菜单 \| 建客户时自动 \| (\d+) 个顶层项'),
        ('02-deploy.md', r'\| 客户菜单 \| (\d+) 个顶层项 \|'),
    ]),
]


def check_doc_sql() -> tuple[int, int, list[str]]:
    """
    校验手册里的运维 SQL 是否还能在真实库上跑通。

    <p>为什么值得做：改了表名/列名之后，手册里的 SQL 会静默失效 ——
    运维照着敲，得到的是 `column does not exist`，而没人会去改手册。
    这里把每条 SQL 真跑一遍（`ON_ERROR_STOP=1`，结果丢弃）。

    <p>可选：需要 `docker` 且 `energy-postgres` 容器在跑。
    不满足就整体跳过（返回 0,0），不阻塞文档同步 ——
    文档一致性不该依赖数据库是否启动。
    """
    import json as _json
    import subprocess
    import tempfile
    import os

    try:
        probe = subprocess.run(
            ['docker', 'exec', 'energy-postgres', 'psql', '-U', 'postgres', '-d', 'thingsboard',
             '-tAc', 'SELECT 1'],
            capture_output=True, text=True, timeout=20)
    except Exception:
        return 0, 0, ['跳过：docker 不可用']
    if probe.returncode != 0:
        return 0, 0, ['跳过：energy-postgres 未运行']

    # 校验范围：故障排查页的「运维常用 SQL」+ 两页功能/数据流文档的全部 SQL。
    #
    # ★ 为什么把新页面也纳进来（2026-10-23）：
    #   06/07 两页给的 SQL 是「用户拿去和页面数字对照」的，写错一条就等于
    #   给出一个错误的核对方法 —— 比没有更糟。让它们进自动化校验，
    #   表名/列名一改就会被抓出来，而不是等用户复制执行时才发现。
    sql_docs = [
        ('05-troubleshoot.md', '## 14. 运维常用 SQL'),
        ('06-customer-menu.md', None),
        ('07-data-pipeline.md', None),
        # 客户手册「看懂分析页」也给了对照 SQL —— 客户/运营会直接复制执行，
        # 写错一条就等于教错核对方法，所以一并跑通。
        ('../user/03-pages.md', None),
    ]
    blocks: list[str] = []
    for fname, marker in sql_docs:
        src = _read(DOCS / fname)
        tail = src[src.find(marker):] if marker else src
        blocks.extend(re.findall(r'```sql\n(.*?)```', tail, re.S))

    # 取一个真实客户 id，用来**验证带占位符的 SQL**。
    #
    # ★ 为什么要这一步（2026-10-22）：原先含 `<客户id>` 的 SQL 一律跳过，
    #   于是「看起来能跑、实际报错」的 SQL 永远不会被发现。
    #   实测就抓到一条：`WHERE t.key = 'energy'` —— ts_kv.key 是整数 key id，
    #   直接比字符串报 invalid input syntax for type integer。
    #   现在把占位符替换成真实 id 再跑，语法/列名/类型错误一律暴露。
    sample_cid = ''
    try:
        r = subprocess.run(
            ['docker', 'exec', 'energy-postgres', 'psql', '-U', 'postgres', '-d', 'thingsboard',
             '-tAc', 'SELECT id FROM customer ORDER BY created_time LIMIT 1'],
            capture_output=True, text=True, timeout=20)
        sample_cid = (r.stdout or '').strip()
    except Exception:
        pass

    # 不能安全替换的占位符（需要用户自己拿的令牌之类）仍然跳过
    UNSAFE = re.compile(r'_TOKEN|你的|xxx')

    ran = 0
    errors: list[str] = []
    # 中文别名里带空格 → PostgreSQL 只把第一个词当别名，剩下的词成为多余 token，
    # 报 `syntax error at or near "id"`。实测踩过：`AS 源 id`。
    # 静态检查先拦一道，比等 psql 报错更容易定位。
    BAD_ALIAS = re.compile(r'\bAS\s+[\u4e00-\u9fff]+\s+[\u4e00-\u9fffa-zA-Z_]+\s*(?:,|$)', re.M)
    for i, sql in enumerate(blocks, 1):
        if UNSAFE.search(sql):
            continue
        m = BAD_ALIAS.search(sql)
        if m:
            alias = m.group(0).strip()
            errors.append(f'第 {i} 条 SQL 有非法中文别名「{alias}」'
                          f'（中文别名不能含空格，加双引号或去掉空格）')
            continue
        body = sql
        # ★ 占位符识别必须排除比较运算符（2026-10-23 踩过）：
        #   原来的 `<[^>]*id>` 会把 `ts <= 1792... AND ... '<设备id>'` 整段吞掉，
        #   因为从 `<=` 那个 `<` 开始、一直到 `'<设备id>'` 的 `id>` 全符合
        #   「不含 > 且以 id> 结尾」—— 结果 SQL 被替换成非法内容，
        #   报 `trailing junk after numeric literal`，而真凶是校验器自己。
        #   现在要求 `<` 后面不是 `=` 或 `<`，且占位符内部不含空白。
        PLACEHOLDER = re.compile(r'<(?![=<])[^<>\s]{1,40}id>')
        if PLACEHOLDER.search(body):
            if not sample_cid:
                continue          # 库里没客户，无从替换
            # 把 <客户id> / <CID> / <设备id> 统一换成真实客户 id
            body = PLACEHOLDER.sub(sample_cid, body)
        with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False, encoding='utf-8') as f:
            f.write(body)
            path = f.name
        try:
            r = subprocess.run(
                ['docker', 'exec', '-i', 'energy-postgres', 'psql', '-U', 'postgres',
                 '-d', 'thingsboard', '-v', 'ON_ERROR_STOP=1', '-o', '/dev/null', '-f', '-'],
                stdin=open(path), capture_output=True, text=True, timeout=60)
        finally:
            os.unlink(path)
        ran += 1
        if r.returncode != 0:
            first = next((l for l in r.stderr.splitlines() if 'ERROR' in l), r.stderr[:80])
            tag = '（占位符已替换）' if body != sql else ''
            # 带上 SQL 首行非注释内容：只报「第 N 条」时根本定位不到是哪段
            head = next((l.strip() for l in sql.splitlines()
                         if l.strip() and not l.strip().startswith('--')), '')[:50]
            errors.append(f'第 {i} 条 SQL 失败{tag}［{head}］：{first.strip()[:80]}')
    return ran, len(blocks), errors


def main() -> int:
    ap = argparse.ArgumentParser(description='手册与代码一致性检查')
    ap.add_argument('-v', '--verbose', action='store_true', help='打印每项的来源与匹配文本')
    args = ap.parse_args()

    rows = []
    failed = 0

    for c in CHECKS:
        try:
            actual = c.fn(REPO)
        except Exception as e:                      # 提取失败也算失败，但要能看出原因
            rows.append((c.label, '提取失败', str(e)[:28], 'ERR'))
            failed += 1
            continue

        declared_values = []
        problem = None

        for fname, pattern in c.targets:
            doc_path = DOCS / fname
            if not doc_path.exists():
                problem = f'{fname} 不存在'
                break
            m = re.search(pattern, _read(doc_path))
            if not m:
                problem = f'{fname} 找不到该表述'
                break
            declared_values.append(int(m.group(1)))
            if args.verbose:
                print(f'    {c.label}: 代码={actual} 手册={m.group(1)}  ← {m.group(0)[:64]}')

        if problem:
            rows.append((c.label, actual, problem, 'MISS'))
            failed += 1
            continue

        # 手册内部自相矛盾（同一数字多处不一致）也算失败
        if len(set(declared_values)) > 1:
            rows.append((c.label, actual, '/'.join(map(str, declared_values)), 'DIFF'))
            failed += 1
            continue

        declared = declared_values[0]
        ok = declared == actual
        if not ok:
            failed += 1
        rows.append((c.label, actual, declared, 'OK' if ok else 'DIFF'))

    # 输出对齐表（中文按 2 列宽处理）
    def width(s):
        return sum(2 if ord(ch) > 0x2E80 else 1 for ch in str(s))

    def pad(s, n):
        return str(s) + ' ' * max(0, n - width(s))

    head = ('检查项', '代码', '手册', '状态')
    w = [max(width(r[i]) for r in rows + [head]) for i in range(4)]

    print()
    print('手册一致性检查')
    print('-' * (sum(w) + 8))
    print('  '.join(pad(h, w[i]) for i, h in enumerate(head)))
    print('-' * (sum(w) + 8))
    for r in rows:
        print('  '.join(pad(v, w[i]) for i, v in enumerate(r)))
    print('-' * (sum(w) + 8))

    # 手册 SQL 可跑性（可选，依赖数据库在跑）
    # ---------------- 手册页面完整性 ----------------
    # 站点由 content/manifest.json 驱动导航：每个 item 的 file 必须真实存在，
    # 否则侧边栏点进去就是「没有找到 admin/xxx 这一页」。
    # 这类错误 check-docs 原来完全没查（实测踩过：新增的 cassandra 页在
    # manifest 里登记了，但没人验证文件在不在）。
    manifest_errors: list[str] = []
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'content', 'manifest.json')
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding='utf-8') as f:
            manifest = json.load(f)
        seen_items: set[tuple[str, str]] = set()
        for section in manifest.get('sections', []):
            for item in section.get('items', []):
                key = (section.get('id', ''), item.get('id', ''))
                if key in seen_items:
                    manifest_errors.append(f'重复的路由 {key[0]}/{key[1]}（manifest 里登记了两次）')
                seen_items.add(key)

                rel = item.get('file', '')
                if not rel:
                    manifest_errors.append(f'{key[0]}/{key[1]} 缺 file 字段')
                    continue
                fpath = os.path.join(os.path.dirname(manifest_path), rel)
                if not os.path.exists(fpath):
                    manifest_errors.append(f'{key[0]}/{key[1]} 指向的 {rel} 不存在')
                    continue
                if os.path.getsize(fpath) == 0:
                    manifest_errors.append(f'{rel} 是空文件')

        # 反向：content 下有 .md 但没登记 → 写了却进不去（漏登记）
        content_dir = os.path.dirname(manifest_path)
        for root, _dirs, files in os.walk(content_dir):
            for fn in files:
                if not fn.endswith('.md'):
                    continue
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, content_dir)
                if not any(i.get('file') == rel
                           for sec in manifest.get('sections', [])
                           for i in sec.get('items', [])):
                    manifest_errors.append(f'{rel} 未在 manifest 登记（写了但侧边栏进不去）')

    if manifest_errors:
        failed += len(manifest_errors)
        print(f'\n✗ 手册页面完整性有 {len(manifest_errors)} 处问题：')
        for e in manifest_errors:
            print(f'    · {e}')
        print('  改完重新运行；页面必须在 manifest 登记，file 必须真实存在。')
    else:
        n_items = sum(len(sec.get('items', [])) for sec in
                      json.load(open(manifest_path, encoding='utf-8')).get('sections', [])) \
                  if os.path.exists(manifest_path) else 0
        print(f'✓ 手册页面完整（manifest 登记 {n_items} 页，文件全部存在）')

    sql_ran, sql_total, sql_errors = check_doc_sql()
    if sql_total:
        if sql_errors:
            failed += len(sql_errors)
            print(f'\n✗ 运维 SQL 校验失败（{sql_ran}/{sql_total} 条执行过）：')
            for e in sql_errors:
                print(f'    · {e}')
        else:
            print(f'\n✓ 运维 SQL 全部可执行（{sql_ran}/{sql_total} 条；'
                  f'带 <客户id> 占位符的已替换成真实 id 验证）')

    if failed:
        print(f'\n✗ {failed} 项不一致 —— 改代码后要同步手册：')
        for r in rows:
            if r[3] != 'OK':
                print(f'  · {r[0]}：代码 {r[1]}，手册 {r[2]}')
        print('\n  改完跑 ./sync.sh 推送到 guard_help。')
        return 1

    print(f'\n✓ 全部一致（{len(CHECKS)} 项）')
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给设备补「能源分项」属性（additionalInfo.energyCategory）。

<h3>它解决什么问题</h3>
AI 侧三个页面按分项选对象：

| 页面 | 读什么 |
| --- | --- |
| 负载预测 · 按分项 | `/ngxapi/biz/targets` 里 `scope_type=category` 的绑定 |
| 用能建议 · 按分项 | `/ngxapi/biz/advice-targets`，再按 `energyCategory` 展开设备 |
| 用能质量 · 分项口径 | 分项聚合用的是同一属性 |

`energyCategory` 为空时：分项下拉全灰、按分项分析 0 台设备、分项汇总落到「其他」。
实测 2026-10-24：整套演示数据 46 台设备该字段全空，客户看到的就是
「能源分项全是 disabled 的，没法选」。

<h3>谁会写这个字段</h3>
- **新装客户**：`EnergyBootstrapInstaller#createDevice` 已按「档案 + 分项 + 层级」
  自动写入，不需要跑本脚本。
- **存量数据**（本脚本）：老版本建的设备没有该字段，用 `--fix` 补齐。
  `--check` 只报告，给验收脚本与排障用。

<h3>分类口径（与 ngxai backend/app/api/biz.py 的 CATEGORY_LABELS 一致）</h3>
```
水表 → water_utility    燃气 → gas        蒸汽 → steam
电表：进线总表 → total
      分项名含「动力/空压/车床」→ power
      含「照明/插座」→ lighting
      含「空调」→ hvac
温湿度 / 网关 / 继电器 / 虚拟表 → 不写（它们不参与用能分项聚合）
```

<h3>用法</h3>
```bash
# 1) 只检查（退出码 0 = 全部已就绪；1 = 有缺失）
python3 scripts/24-device-categories.py --check

# 2) 补齐（幂等，可重复执行）
python3 scripts/24-device-categories.py --fix

# 3) 只看会改哪些、不写库
python3 scripts/24-device-categories.py --fix --dry-run

# 4) 只处理指定客户
python3 scripts/24-device-categories.py --fix --customer 平台演示中心
```

凭据默认读同目录 `../DEPLOY-CREDENTIALS.txt`（重装时生成），也可用
`--tenant` / `--tenant-pass` 覆盖。

退出码：0 全部就绪 / 已修复；1 有缺失（--check）或写入失败；2 参数或登录问题。
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8090'
HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- HTTP
def api(path, token=None, method='GET', body=None):
    req = urllib.request.Request(BASE + path, method=method)
    if body is not None:
        req.data = json.dumps(body).encode()
        req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('X-Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        raise RuntimeError('HTTP %s %s → %s'
                           % (e.code, path, e.read().decode('utf-8', 'replace')[:300]))
    except urllib.error.URLError as e:
        raise RuntimeError('连不上平台：%s' % e.reason)


def paged(path, token):
    out, page = [], 0
    while True:
        sep = '&' if '?' in path else '?'
        d = api('%s%spageSize=500&page=%d' % (path, sep, page), token)
        out.extend(d.get('data') or [])
        if not d.get('hasNext'):
            return out
        page += 1


def credentials(args):
    """默认从 DEPLOY-CREDENTIALS.txt 读租户管理员账号。"""
    if args.tenant and args.tenant_pass:
        return args.tenant, args.tenant_pass
    path = os.path.join(HERE, '..', 'DEPLOY-CREDENTIALS.txt')
    text = ''
    if os.path.exists(path):
        text = open(path, encoding='utf-8', errors='replace').read()
    # 格式（docker-98-rebuild.sh 生成）：  租户管理员     tenant@x.com / 密码
    m = re.search(r'租户管理员\s+(\S+@\S+)\s*/\s*(\S+)', text)
    tenant = args.tenant or (m.group(1) if m else
                             re.search(r'租户[^\n]*?[:：]\s*(\S+@\S+)', text))
    pwd = args.tenant_pass or (m.group(2) if m else
                               re.search(r'租户[^\n]*?密码[^\n]*?[:：]\s*(\S+)', text))
    tenant = tenant if isinstance(tenant, str) else (tenant.group(1) if tenant else '')
    pwd = pwd if isinstance(pwd, str) else (pwd.group(1) if pwd else '')
    return tenant, pwd


# ---------------------------------------------------------------- 分类规则
def classify(device):
    """设备对象 → energyCategory；返回 None 表示不该有该字段。"""
    name = device.get('name') or ''
    profile = device.get('type') or ''
    info = device.get('additionalInfo') or {}

    # 非计量设备：网关 / 继电器 / 温湿度 / 虚拟表 / 空壳
    if profile == '温湿度变送器' or '温湿度' in name:
        return None
    if info.get('gateway') or 'Gateway' in name or '网关' in profile:
        return None
    if 'Relay' in name or '继电器' in name:
        return None
    if info.get('virtual') == 'virtual' or '虚拟' in name:
        return None

    if '水表' in name or profile == '水表':
        return 'water_utility'
    if '燃气' in name or '燃气' in profile:
        return 'gas'
    if '蒸汽' in name or '蒸汽' in profile:
        return 'steam'

    if '电能' not in profile and '电表' not in profile:
        return None
    if '进线总表' in name:
        return 'total'
    if '动力' in name or '空压' in name or '车床' in name:
        return 'power'
    if '空调' in name:
        return 'hvac'
    if '照明' in name or '插座' in name:
        return 'lighting'
    # 区域汇总表（如「三相园-办公区总表」）不参与分项聚合。
    #
    # 它下辖「办公照明回路」，但它是办公区这个**区域**的总表，不是照明分项的
    # 计量点。算进照明分项会让「照明 = 办公区总表 + 办公照明回路」，父子重复。
    # 这类表在演示树里挂在一个分项下（为了树结构），名称却不含该分项名。
    if '总表' in name and not any(k in name for k in ('进线', '动力', '照明', '插座', '空调')):
        return None
    # 兜底：认不出分项的电表按「总用电」处理。
    #
    # 为什么不是留空：留空会被 AI 侧归到「其他」，客户选分项时这台表直接消失；
    # 而「总用电」至少是个语义正确的桶 —— 进线表、现场 RTU 那台单相表
    # 都属于「这个范围的总量」。
    return 'total'


def main():
    global BASE
    ap = argparse.ArgumentParser(description='设备能源分项属性检查 / 修复')
    ap.add_argument('--base', default=BASE)
    ap.add_argument('--tenant', default='')
    ap.add_argument('--tenant-pass', default='')
    ap.add_argument('--customer', default='', help='只处理该客户名下的设备')
    ap.add_argument('--check', action='store_true', help='只检查，不写库')
    ap.add_argument('--fix', action='store_true', help='补齐缺失（幂等）')
    ap.add_argument('--dry-run', action='store_true', help='配合 --fix：只打印不写库')
    a = ap.parse_args()
    if not a.check and not a.fix:
        ap.error('需要 --check 或 --fix（二者可同时用：先检查再修）')
    BASE = a.base

    tenant, pwd = credentials(a)
    if not tenant or not pwd:
        print('✗ 缺少租户管理员凭据：传 --tenant/--tenant-pass，'
              '或确认同目录 ../DEPLOY-CREDENTIALS.txt 存在')
        return 2

    tok = api('/api/auth/login', method='POST',
              body={'username': tenant, 'password': pwd})['token']
    devs = paged('/api/tenant/devices', tok)

    customers = {c['id']['id']: c['name'] for c in paged('/api/customers', tok)}
    if a.customer:
        want = {cid for cid, nm in customers.items() if nm == a.customer}
        if not want:
            print('✗ 找不到客户「%s」' % a.customer)
            return 2
        devs = [d for d in devs
                if ((d.get('customerId') or {}).get('id')) in want]

    missing, wrong, stale, okc, skipped = [], [], [], 0, 0
    for d in devs:
        want = classify(d)
        have = (d.get('additionalInfo') or {}).get('energyCategory') or ''
        if want is None:
            if have:
                stale.append((d, have))
            else:
                skipped += 1
            continue
        if have == want:
            okc += 1
        elif have:
            wrong.append((d, have, want))
        else:
            missing.append((d, want))

    print('设备 %d 台：已就绪 %d，缺失 %d，取值不符 %d，多余 %d，不参与分类 %d'
          % (len(devs), okc, len(missing), len(wrong), len(stale), skipped))
    for d, want in missing:
        print('  缺失 %-36s → %s' % (d.get('name'), want))
    for d, have, want in wrong:
        print('  不符 %-36s 现为 %s，应为 %s' % (d.get('name'), have, want))
    for d, have in stale:
        print('  多余 %-36s 现为 %s，应清除（区域汇总表/虚拟表不参与分项）'
              % (d.get('name'), have))

    if a.check and not a.fix:
        if missing or wrong or stale:
            print('\n✗ 有 %d 台设备的分项属性未就绪；执行 --fix 补齐。'
                  % (len(missing) + len(wrong) + len(stale)))
            return 1
        print('\n✓ 全部就绪（AI 侧「按分项」可选）')
        return 0

    if not missing and not wrong and not stale:
        print('\n✓ 无需修改')
        return 0

    changed = 0
    for d, want in [(d, w) for d, _h, w in wrong] + list(missing):
        if a.dry_run:
            changed += 1
            continue
        info = dict(d.get('additionalInfo') or {})
        info['energyCategory'] = want
        d['additionalInfo'] = info
        # 保留 customerId 原样回传：删掉会被后端判成「变更归属」而 400
        api('/api/device', tok, method='POST', body=d)
        changed += 1
    for d, _have in stale:
        if a.dry_run:
            changed += 1
            continue
        info = dict(d.get('additionalInfo') or {})
        info.pop('energyCategory', None)
        d['additionalInfo'] = info
        api('/api/device', tok, method='POST', body=d)
        changed += 1
    print('\n%s：%d 台' % ('dry-run 预览' if a.dry_run else '已修复', changed))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as e:
        print('✗ %s' % e)
        sys.exit(1)

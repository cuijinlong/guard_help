#!/usr/bin/env node
/**
 * 部件「设备总用量」(energy_management.device_total) 的指标语义回归。
 *
 * ## 为什么要有它
 *
 * 这个部件按指标的 `agg` 决定「那一列算成什么」，三种语义不能混：
 *
 *   SUM  —— 区间增量（用电量 energy）：逐点求和，可跨设备相加
 *   MAX  —— 累计表底（正向有功总电度 energy_reading）：**绝不能求和**
 *           区间用量 = 末值 − 初值
 *   AVG  —— 瞬时量（电压/电流/功率因数）：区间平均，跨设备合计无意义
 *
 * 2026-11-09 实测：原实现硬编码 `agg=SUM` 并把所有点相加。在「手工填报」
 * 看板上看不出来（虚拟表只写 energy），但客户在这个部件上选「正向有功总电度」
 * 时，会把逐日表底加总成一个看着像真数据的错数（1400 → 3750）。
 * 同一类错误明细表用 `isAdditive` 防着，这个部件当时漏了。
 *
 * ## 用法
 *
 *     node shiyongshouce/downloads/scripts/check-widget-device-total.mjs
 *     node shiyongshouce/downloads/scripts/check-widget-device-total.mjs --verbose
 *
 * 退出码 0 = 全部通过；1 = 有不符（可直接进 CI / 提交前跑）。
 *
 * ## 它测的是**真代码**
 *
 * 不复制一份逻辑来测（那样测的是副本，改了真代码测试照样绿）：
 * 从部件 JSON 里抽出 `controllerScript`，用最小 TB 桩
 * （$scope / http / stateController）执行，然后读 $scope 上的结果。
 */

import fs from 'node:fs'
import path from 'node:path'
import url from 'node:url'

const HERE = path.dirname(url.fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '../../..')
const WIDGET = path.join(
  ROOT, 'guard-server/src/main/data/json/system/widget_types/energy_management_device_total.json')

const verbose = process.argv.includes('--verbose')

if (!fs.existsSync(WIDGET)) {
  console.error(`找不到部件 JSON：${WIDGET}`)
  process.exit(2)
}

const descriptor = JSON.parse(fs.readFileSync(WIDGET, 'utf8')).descriptor || {}
const SCRIPT = descriptor.controllerScript || ''
const TPL = descriptor.templateHtml || ''

if (!SCRIPT.includes('kindOf')) {
  console.error('部件里没有 kindOf —— 指标语义分流被移除了？')
  process.exit(2)
}

const DAY = 86400000
const FROM = Date.UTC(2026, 10, 1)
const TO = FROM + 3 * DAY - 1

/**
 * 用最小 TB 桩执行一遍 onInit，返回 $scope 与它发过的请求 URL。
 *
 * @param payload    查询设置下发的状态参数（devices/timeRange/paramSeries/paramUnit）
 * @param telemetry  (deviceId, agg) => 该设备返回的点数组
 */
function run(payload, telemetry) {
  const scope = {}
  const urls = []
  const self = {
    ctx: {
      $scope: scope,
      settings: {},
      detectChanges() {},
      stateController: {
        getStateParams: () => payload,
        stateChanged: () => ({ subscribe: () => ({ unsubscribe() {} }) }),
      },
      http: {
        get(u) {
          urls.push(u)
          const key = decodeURIComponent((u.match(/keys=([^&]+)/) || [])[1] || '')
          const agg = (u.match(/agg=([A-Z]+)/) || [])[1]
          const did = (u.match(/DEVICE\/([^/]+)/) || [])[1]
          const res = {}
          res[key] = telemetry(did, agg) || []
          return { subscribe: (ok) => ok(res) }
        },
      },
    },
  }
  // TB 运行时依次调用 typeParameters / onInit
  new Function('self', SCRIPT)(self)
  self.onInit()
  return { scope, urls }
}

let pass = 0
let fail = 0
function chk(name, cond, extra) {
  if (cond) {
    pass++
    if (verbose) console.log('  ✓', name)
  } else {
    fail++
    console.log('  ✗', name, extra === undefined ? '' : JSON.stringify(extra))
  }
}
function group(name) {
  if (verbose) console.log(name)
}

const payloadOf = (devices, key, agg) => ({
  devices,
  deviceNames: Object.fromEntries(devices.map((d) => [d, d])),
  timeRange: { fromTs: FROM, toTs: TO },
  paramSeries: [{ key, agg }],
  paramUnit: 'kW·h',
})

// ① 区间增量（用电量）：逐点求和
group('① 用电量 SUM')
{
  const { scope } = run(payloadOf(['d1'], 'energy', 'SUM'), () => [
    { ts: FROM + 1000, value: 10 },
    { ts: FROM + DAY, value: 20 },
    { ts: FROM + 2 * DAY, value: 30 },
  ])
  chk('10+20+30 = 60', Math.abs(scope.rows[0].value - 60) < 1e-9, scope.rows)
  chk('列名「总用量」', scope.colLabel === '总用量', scope.colLabel)
}

// ② 累计表底：末值 − 初值，绝不相加
group('② 正向有功总电度 MAX')
{
  const days = [
    { ts: FROM - DAY, value: 1000 },        // 窗口前的基准
    { ts: FROM + 1000, value: 1100 },
    { ts: FROM + DAY, value: 1250 },
    { ts: FROM + 2 * DAY + 1000, value: 1400 },
  ]
  const { scope, urls } = run(payloadOf(['d1', 'd2'], 'energy_reading', 'MAX'), () => days)
  const d1 = scope.rows.find((r) => r.deviceId === 'd1')
  chk('1400 − 1000 = 400（不是 3750）', Math.abs(d1.value - 400) < 1e-9, d1)
  chk('列名标明「末−初」', /末−初/.test(scope.colLabel), scope.colLabel)
  chk('两台合计 800', Math.abs(Number(scope.totalText) - 800) < 1e-6, scope.totalText)
  chk('显示合计行', scope.showTotal === true)
  const u = urls[0] || ''
  chk('请求用 agg=MAX', /[?&]agg=MAX(&|$)/.test(u), u)
  chk('startTs 往前推一天取基准', u.indexOf('startTs=' + (FROM - DAY)) >= 0, u)
}

// ③ 表底倒走（换表/归零）：该行留空并提示，合计不被拉负
group('③ 表底倒走')
{
  const { scope } = run(payloadOf(['d1', 'd2'], 'energy_reading', 'MAX'), (did) => (
    did === 'd1'
      ? [{ ts: FROM - DAY, value: 1000 }, { ts: FROM + 1000, value: 50 },
        { ts: FROM + 2 * DAY, value: 120 }]
      : [{ ts: FROM - DAY, value: 500 }, { ts: FROM + 2 * DAY, value: 700 }]
  ))
  chk('倒走那台不出现在表里',
    scope.rows.map((r) => r.deviceId).indexOf('d1') < 0,
    scope.rows.map((r) => r.deviceId))
  chk('正常那台 700 − 500 = 200',
    Math.abs(scope.rows.find((r) => r.deviceId === 'd2').value - 200) < 1e-9)
  chk('脚注说明倒走', /表底倒走/.test(scope.noteText), scope.noteText)
}

// ④ 瞬时量：区间平均，不显示合计
group('④ 电压 AVG')
{
  const { scope } = run(payloadOf(['d1', 'd2'], 'voltage_a', 'AVG'), (did) => (
    did === 'd1'
      ? [{ ts: FROM + 1000, value: 230 }, { ts: FROM + DAY, value: 234 }]
      : [{ ts: FROM + 1000, value: 220 }]
  ))
  chk('(230+234)/2 = 232（不是 464）',
    Math.abs(scope.rows.find((r) => r.deviceId === 'd1').value - 232) < 1e-9)
  chk('不显示合计', scope.showTotal === false && scope.totalText === '',
    [scope.showTotal, scope.totalText])
  chk('列名「区间平均」', scope.colLabel === '区间平均', scope.colLabel)
}

// ⑤ 缺窗口前基准：退回窗口内首点并说明是估算
group('⑤ 缺基准表底')
{
  const { scope } = run(payloadOf(['d1'], 'energy_reading', 'MAX'), () => [
    { ts: FROM + 1000, value: 300 },
    { ts: FROM + 2 * DAY, value: 420 },
  ])
  chk('420 − 300 = 120', Math.abs(scope.rows[0].value - 120) < 1e-9, scope.rows[0])
  chk('脚注说明是估算', /估算/.test(scope.noteText), scope.noteText)
}

// ⑥ 多选指标：优先选用量类
group('⑥ 多选优先 SUM')
{
  const { scope } = run({
    devices: ['d1'],
    deviceNames: { d1: 'd1' },
    timeRange: { fromTs: FROM, toTs: TO },
    paramSeries: [{ key: 'voltage_a', agg: 'AVG' }, { key: 'energy', agg: 'SUM' }],
    paramUnit: 'kW·h',
  }, () => [{ ts: FROM + 1000, value: 10 }])
  chk('选 energy 而非 voltage', Math.abs(scope.rows[0].value - 10) < 1e-9)
  chk('列名「总用量」', scope.colLabel === '总用量', scope.colLabel)
}

// ⑦ 模板：列名必须动态绑定，合计行必须受 showTotal 控制
group('⑦ 模板绑定')
{
  chk('表头用 {{ colLabel }}', /\{\{\s*colLabel\s*\}\}/.test(TPL))
  // 正则不能用 [^>]*：ngIf 里是 `rows?.length > 1 && showTotal`，
  // 那个 `>` 会让 [^>]* 提前终止，测试假失败（写测试时踩过一次）。
  chk('合计行受 showTotal 控制', /<tfoot[\s\S]{0,160}showTotal/.test(TPL))
  chk('脚注节点存在', /noteText/.test(TPL))
}

const total = pass + fail
if (fail) {
  console.log(`\n${total - fail}/${total} 通过，${fail} 条不符`)
  process.exit(1)
}
console.log(`\n${total}/${total} 全部通过（设备总用量的指标语义）`)
process.exit(0)

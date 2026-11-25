# ⑥ 规则

平台里「规则」只有两类，都在**设备档案**上配、同档案设备自动继承：

| 类型 | 干什么 | 存哪 | 存在表 |
| --- | --- | --- | --- |
| **派生指标**（`SIMPLE`） | 用已有遥测算出新指标 | `calculated_field` | 2 条 |
| **告警**（`ALARM`） | 条件满足则产生/清除告警 | `calculated_field` | 4 种（租户 + 系统各一份） |

> **不要在「告警规则」页找**：TB 原生的 `alarm_rule` 表在本平台是空的，
> 告警已经全部迁到 `calculated_field` 的 `ALARM` 类型。
> 平台里对应的入口是**设备档案 → 计算字段**。

---

## 一、派生指标（SIMPLE）

| 名称 | 输入 | 公式 | 输出 |
| --- | --- | --- | --- |
| 负荷率 | `power_total` | 功率 / 变压器容量 × 100 | `load_rate`（%） |
| 碳排放 | `energy` | 电量 × 排放因子 | `carbon`（kgCO₂） |

**为什么不放在规则链里**：挂在档案上，**同档案的所有设备自动继承**。
第 21 台表接入时不用再配一遍 —— 这是「一次配好、长期有效」的关键。

### 排放因子

默认用生态环境部 2022 全国电网平均因子。**改法**：档案上的计算字段配置，
或部件设置里覆盖（综合能耗部件支持）。

---

## 二、告警（ALARM）

### 2.1 平台预置的 4 条

| 名称 | 触发条件 | 级别 | 依据 |
| --- | --- | --- | --- |
| 电压越限 | `voltage_a` 超出 220V ±7%（204.6~235.4） | MAJOR | GB/T 12325 |
| 电压不平衡度超限 | `voltage_unbalance` > 2% | WARNING | GB/T 15543 |
| 功率因数偏低 | `power_factor_total` < 0.90 | MINOR | 供电公司考核线 |
| 闲时能耗超标 | `idle_exceed` = true | WARNING | 客户自定义闲时时段 |

**全部挂在「电能表」档案上**，所以三相表、单相表都自动生效；
水表/气表/热力表不受影响（它们没有 `voltage_a` 这类键）。

### 2.2 一条告警规则的完整结构

以「功率因数偏低」为例：

```json
{
  "type": "ALARM",
  "arguments": {
    "pf": { "refEntityKey": { "key": "power_factor_total", "type": "TS_LATEST" } }
  },
  "createRules": {
    "MINOR": {
      "condition": {
        "type": "SIMPLE",
        "expression": {
          "type": "SIMPLE",
          "filters": [{
            "argument": "pf",
            "valueType": "NUMERIC",
            "operation": "AND",
            "predicates": [{ "type": "NUMERIC", "operation": "LESS",
                             "value": { "staticValue": 0.9 } }]
          }],
          "operation": "AND"
        },
        "schedule": null
      },
      "alarmDetails": "功率因数 ${pf} 低于 0.90，请检查无功补偿",
      "dashboardId": null
    }
  },
  "clearRule": { ... }
}
```

**四个关键点**：

| 字段 | 含义 | 注意 |
| --- | --- | --- |
| `arguments` | 把遥测键绑成变量名 | `type: "TS_LATEST"` 读最新值 |
| `createRules` | 按级别分别配条件 | 级别：`CRITICAL`/`MAJOR`/`MINOR`/`WARNING`/`INDETERMINATE` |
| `alarmDetails` | 告警详情，可用 `${变量}` | 变量名必须是 `arguments` 里的键 |
| `clearRule` | 恢复条件 | **不配永远不会自动清除** |

### 2.3 告警是「按最新值」判的，不是按历史点

`TS_LATEST` 意味着**每来一个新遥测就判一次**。所以：

- 设备上报频率 = 判定的最细粒度。5 秒一报就是 5 秒判一次
- **设备停止上报，告警不会自己消失** —— 它判的是「最后那个值」，不是「没有值」
- 要「掉线告警」，得配 `device activity` 类条件，不是数值条件

### 2.4 加一条新告警

**别用界面硬配**（配置是深层 JSON，手点容易漏 `clearRule`）。用脚本：

```python
# 伪代码：挂在「电能表」档案上
cf = {
  "name": "电流超载",
  "type": "ALARM",
  "arguments": {"ia": {"refEntityKey": {"key": "current_a", "type": "TS_LATEST"}}},
  "createRules": {
    "MAJOR": {
      "condition": {"type": "SIMPLE", "expression": {"type": "SIMPLE", "filters": [{
        "argument": "ia", "valueType": "NUMERIC", "operation": "AND",
        "predicates": [{"type": "NUMERIC", "operation": "GREATER",
                        "value": {"staticValue": 60}}]
      }], "operation": "AND"}, "schedule": None},
      "alarmDetails": "A 相电流 ${ia} A 超过额定 60 A",
      "dashboardId": None
    }
  },
  "clearRule": {
    "type": "SIMPLE", "expression": {"type": "SIMPLE", "filters": [{
      "argument": "ia", "valueType": "NUMERIC", "operation": "AND",
      "predicates": [{"type": "NUMERIC", "operation": "LESS",
                      "value": {"staticValue": 55}}]
    }], "operation": "AND"}
  }
}
# POST /api/deviceProfile/<档案id>/calculatedField  （或对应接口）
```

**两个必须遵守的习惯**：

1. **`create` 与 `clear` 阈值要留回差**（如 > 60 报警、< 55 清除）。
   同一个阈值会让告警在临界点反复产生/清除，刷满告警列表。
2. **挂档案不挂设备**。挂设备 = 换一台表就失效，第 21 台表没人管。

### 2.5 两套告警并存，分工不同（别搞混）

平台里其实有**两套**告警能力，它们服务于不同的人：

| | 档案级告警（上面 2.1~2.4） | **客户自建告警** |
| --- | --- | --- |
| 谁修改 | 只有**租户管理员** | **客户用户自己** |
| 管哪里 | 挂在设备档案上，该档案**全部设备** | 指定档案 + 可选限定场站 |
| 能配什么 | `voltage_a` / `power_factor_total` 等指标的超限 | 同样是指标超限，但自己选指标、阈值、方向 |
| 防抖 | `DURATION`（持续 N 秒）/ `REPEATING`（连续 N 次） | 间隔 N 秒看一次，连续 M 次命中才告警 |
| 界面 | 平台原生告警规则界面（客户看不到） | 「告警事件 → 告警规则」 |

**为什么不能合成一套**：

TB 原生的告警规则 API **全部要求租户管理员权限**，而且规则实体本身
没有客户归属字段 —— 客户 A 配的规则会作用到客户 B 的设备上。
但「客户用户根据自身情况自己建规则」是明确的产品需求，所以另做了一套。

**客户自建告警怎么用**（客户用户账号即可）：

1. 进「告警事件」→「告警规则」→「新建」
2. 选设备档案（比如「单相电能表」）、可选限定场站
3. 选监测指标（下拉里是该档案能报的键）、方向（高于/低于）、阈值
4. 配间隔（多少秒看一次）与次数（连续几次才报）
5. 选级别（WARNING / MAJOR …），保存

**告警产生后的处理**（客户用户都能做）：

| 动作 | 效果 |
| --- | --- |
| **确认** | 标「我已知道」，告警仍在，不会重复通知你 |
| **消除** | 标「已处理」，进「已处理」页签 |
| **派单** | 指定处理人（只能派给本客户下的人） |

> **级别与阈值怎么定**：没有强制标准。参考上面 2.1 那四条国标依据，
> 再按自己设备情况调。口诀是：**阈值留回差，次数防抖动**。
>
> **客户自己建的规则，只能管自己的设备** —— 这是写入时就把 `customer_id`
> 写死了的，不是靠查询过滤（改不了）。
>
> 两套告警最终都落在同一个 `alarm` 表里，所以在「告警事件」页能看到全部，
> 确认/消除/派单的操作也完全一样。

---

## 三、规则链（Key 标准化）

平台的规则链只有两条，都是 TB 原生的：

| 规则链 | 节点数 | 作用 |
| --- | --- | --- |
| `Root Rule Chain` | 16 | 主处理链：保存遥测 → 触发计算字段 → 告警 |
| `Edge Root Rule Chain` | 11 | 边缘端，用于 RTU 侧预处理 |

**能源业务没有自定义规则链**。厂家键名转换如果要做，加在
`Root Rule Chain` 的「电表Key标准化」节点（`renameKeys`）。

> **不要为业务逻辑加规则链节点**。规则链逐条消息触发，
> 汇总、批处理这类需求用后端定时任务（见 [⑤ 数据流](/admin/data-flow)）。

---

## 四、五类「静默失效」的规则配置

这些坑的共同点是：**配置保存成功、界面无报错、但永远不生效**。

| 坑 | 症状 | 原因 |
| --- | --- | --- |
| 告警挂设备而非档案 | 新表没人管 | 换表即失效 |
| 缺 `clearRule` | 告警产生后再也不消失 | 没有恢复条件 |
| `alarmDetails` 变量名写错 | 详情显示 `${pf}` 原文 | 变量名必须在 `arguments` 里 |
| 场站告警阈值页填了但没用 | 「保存成功」却从不告警 | 该页只存属性，没有判定逻辑 |
| 用能等级/等级阈值只存不用 | 界面能填，报表不变 | 已废弃的页面 |

**判据**：任何「配置类」页面，配完必须能回答
「**它被谁读？**」。答不上来就是死配置。

---

## 五、验证规则真的在跑

```bash
# ① 计算字段存在吗（应 5 种，租户 + 系统各一份）
docker exec energy-postgres psql -U administrator -d guarddb -c "
SELECT name, type, tenant_id IS NULL AS 系统级 FROM calculated_field ORDER BY name;"

# ② 告警有没有产生（空 = 条件从没满足，或规则没生效）
docker exec energy-postgres psql -U administrator -d guarddb -c "
SELECT type, severity, count(*) FROM alarm GROUP BY 1,2;"

# ③ 派生指标有没有落库
docker exec energy-postgres psql -U administrator -d guarddb -c "
SELECT kd.key, count(*) FROM ts_kv t
JOIN ts_kv_dictionary kd ON kd.key_id = t.key
WHERE kd.key IN ('load_rate','carbon','idle_exceed') GROUP BY 1;"
```

**三者都不为空**才算规则链路通。只有 ① 有配置、② 和 ③ 空 →
规则没被触发（数据没上报，或键名对不上）。

---

## 六、规则与看板的关系

| 看板位置 | 读什么 | 来自 |
| --- | --- | --- |
| 「待处理异常」卡片 | `alarm` 表（未清除） | 告警规则 |
| 「用能异常与节能机会」 | 部件内的规则判断（阈值可在部件设置改） | 部件逻辑，**不走告警规则** |
| 「负荷率」报表列 | `load_rate` 遥测 | 派生指标 |
| 「碳排放」卡片 | `carbon` 遥测或部件现算 | 派生指标 / 部件 |

**注意**：综合能耗部件的「用能异常与节能机会」是**部件自己的判断**
（读遥测 + 部件内阈值），不是读 `alarm` 表。改告警规则不会改变那张卡片，
要改部件设置里的阈值。

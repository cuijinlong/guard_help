#!/usr/bin/env node
/**
 * 3D-NGX · AI 搭建桥接服务（2026-11-24）
 *
 * <h2>它解决什么</h2>
 *
 * <p>客户原始需求：「开发一个 Chat 聊天对接 codewhale 代替命令行」。
 * 前端 `AiBuildPanel` 早就做好了 UI 与契约，但后端 `POST /api/ngx/ai/chat`
 * 一直没人实现 —— 面板只能报「后端未接通」。
 *
 * <p>这个服务就是那层桥：收前端的聊天请求，转给本机的 `codewhale exec`，
 * 把回答和「可落地的布局改动」一起返回。
 *
 * <h2>为什么是独立进程，不是塞进 Java 后端</h2>
 *
 * <p>codewhale 是宿主机的 CLI（Rust 二进制 + 用户自己的 API key 与配置），
 * Java 后端跑在容器里，既没有这个二进制，也不该拿到用户的模型凭据。
 * 桥接放在宿主机、nginx 转发一条 `/api/ngx/ai/` 过去，是唯一不需要
 * 往容器里塞 Node 与用户密钥的做法。
 *
 * <h2>★ 安全边界（这是最要紧的部分）</h2>
 *
 * <ol>
 *   <li><b>只读</b>：固定 `--permission-mode plan`。AI 不能改文件、不能跑写命令。
 *       它做的是「读懂需求 → 产出一份改动提案」，落地由前端校验 + 用户确认。</li>
 *   <li><b>工作目录限定在空临时目录</b>：即使将来换了模式，也读不到项目源码。</li>
 *   <li><b>共享密钥</b>：nginx 注入 `X-Ngx-Ai-Key`，不匹配一律 401。
 *       服务监听 0.0.0.0 是必需的（容器要走宿主 IP），所以必须靠密钥兜底。</li>
 *   <li><b>并发上限 2</b>：codewhale 每次拉起是独立进程，并发放开会把机器打满。</li>
 *   <li><b>超时 150s</b>：单次对话实测 5~40s；超时杀掉子进程，不留僵尸。</li>
 *   <li><b>不拼 shell</b>：用 `spawn` 的参数数组，prompt 作为单个 argv 传入。
 *       用户输入里的引号、分号、反引号都只是普通字符。</li>
 * </ol>
 *
 * <h2>为什么不把工具能力开给 AI</h2>
 *
 * <p>看起来「让 AI 自己跑命令查设备」更聪明，但那等于把整个平台的操作权
 * 交给一个可能理解错需求的模型。当前设计里 AI 只产出**结构化提案**，
 * 提案必须通过 `examineLayoutProposal` 校验（前端已有 13 条测试），
 * 再由人点「应用到布局」。出错的代价是一份被拒绝的提案，不是一次误操作。
 */

"use strict";

const http = require("node:http");
const { spawn } = require("node:child_process");
const { mkdtempSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const crypto = require("node:crypto");

/* ───────────────────────── 配置 ───────────────────────── */

const PORT = Number(process.env.NGX_AI_PORT || 8092);
const HOST = process.env.NGX_AI_HOST || "0.0.0.0";
/**
 * 共享密钥。
 *
 * <p>不设默认值：没有密钥就拒绝启动。
 * 「默认空表示不校验」这种设计会在生产上变成一个敞开的门 ——
 * 而这台机器上的 codewhale 花的是用户自己的模型额度。
 */
const SHARED_KEY = process.env.NGX_AI_KEY || "";
const CODEWHALE_BIN = process.env.NGX_CODEWHALE_BIN || "codewhale";
/** 单次对话超时（毫秒）。实测 5~40s，留足余量。 */
const TIMEOUT_MS = Number(process.env.NGX_AI_TIMEOUT_MS || 150000);
/** 并发上限。 */
const MAX_CONCURRENCY = Number(process.env.NGX_AI_MAX_CONCURRENCY || 2);
/** 单条请求体上限。 */
const MAX_BODY_BYTES = 64 * 1024;

/**
 * 平台地址 —— 用来校验「调用者是谁」。
 *
 * <h3>为什么桥接自己必须验身份（2026-11-24）</h3>
 *
 * <p>nginx 给 `/api/ngx/ai/` **无条件**注入共享密钥，那是
 * 「nginx → 桥接」这一跳的内部凭证，证明请求来自自家网关。
 * 它**不证明**请求背后是一个已登录的租户管理员。
 *
 * <p>实测漏得很彻底：不带任何登录凭据 POST `http://127.0.0.1:8090/api/ngx/ai/chat`
 * 直接返回 200 和一段完整的 AI 回答。任何能访问 8090 的人都能白嫖
 * 这台机器上 codewhale 的模型额度 —— 而那是用户自己付钱的。
 *
 * <p>所以这里补第二道：读 `X-Authorization`，拿去问平台
 * `GET /api/auth/user`。用 8090（nginx）而不是直连后端，
 * 是因为它就监听在本机、走的是同一套路由规则。
 */
const PLATFORM_BASE = process.env.NGX_AI_PLATFORM || "http://127.0.0.1:8090";
/** 允许使用 AI 搭建的角色。客户角色进不到编辑器，也就不该能调这里。 */
const ALLOWED_AUTHORITIES = ["TENANT_ADMIN", "SYS_ADMIN"];
/** 单条消息内容上限（防把整份场景 JSON 塞进来）。 */
const MAX_MESSAGE_CHARS = 4000;
/** 历史消息最多带几条。 */
const MAX_HISTORY = 12;

/* ───────────────────────── 系统提示 ───────────────────────── */

/**
 * 发给 codewhale 的系统提示。
 *
 * <h3>为什么把 widget 类型、操作字段全写死在这里</h3>
 *
 * <p>模型不可能知道本项目的私有约定。少写一条，AI 就会产出
 * 一份「字段名对不上」的提案 —— 而用户看到的是「AI 说改好了」但界面没变。
 * 这些常量与 `packages/data-adapter/src/scene-widget-layout.ts` 的
 * `SceneWidgetTypeId`、`layout-proposal.ts` 的 `LayoutOperation` 一一对应，
 * 改那边要同步改这里。
 */
const SYSTEM_PROMPT = `你是「3D-NGX 工业三维数字孪生大屏」的搭建助手。

你的工作：理解用户对大屏的改动意图，产出一份**结构化的改动提案**（JSON）。
你不会直接改任何文件或大屏 —— 提案会先被系统校验，再由用户点「应用」才生效。

## 输出格式（严格遵守）

只输出一个 JSON 对象，不要任何解释文字、不要 Markdown 代码块标记：

{"content":"给用户看的中文回答","actions":[...]}

- content：必填。面向现场人员，说清你打算改什么。允许简短（一到三句）。
- actions：可选。不需要改布局时省略或给空数组 []。

## 需求资料的用法（有【模板文件】时必须遵守）

【模板文件】里可能有作者写的「现场资料与需求」（requirements.md）。**它是现场真实情况的唯一权威来源**，优先级高于你的通用常识。

- 它写了的内容：照做，不要用你的默认假设覆盖（比如它说「温度」，就不要改成「进水温度」）。
- 它**留空、写「待确认」或明显没填**的条目（统计口径、告警定义、设备指标名）：**不要猜**。
  在 content 里用一句话问清楚，actions 给空数组。
  理由：猜出来的配置看着合理，但和现场不符，而大屏是给值班员做判断用的 —— 错的口径比空白更危险。
- 用户口头说明与文件冲突时，以**用户当前这句话**为准，并在 content 里提醒他同步更新文件，
  否则下次 AI 又会按旧文件做。
- 文件里没有的东西（场站规模、设备台数、关注点），如果直接决定布局与统计口径，也要问，不要编。

## 可用的操作（只有这 4 种）

1. {"op":"update-widget","id":"卡片id","patch":{"title":"新标题"}}
   patch 可含：title / subtitle / filterText / slots（**slots 是整体替换**，必须给完整数组）/
   x / y / w / h / style。**不能改 id 和 type**。

2. {"op":"add-widget","widget":{完整的卡片对象，含 id/type/x/y/w/h/title}}

3. {"op":"remove-widget","id":"卡片id"}

4. {"op":"bind-telemetry","id":"卡片id","slotKey":"槽位key","telemetryKey":"遥测键"}

## 可用卡片类型（type）

metric-card 指标卡 · ratio-ring 环形比例 · gauge-ring 环形仪表 · trend-chart 趋势图
summary-card 汇总卡 · selection-card 选中设备卡 · device-list 设备列表
bar-compare 条形对比 · control-bar 控制条 · title 整屏标题 · caption 说明

同一类型里 title / caption / selection-card 各最多 1 块。

## 布局坐标

x / y / w / h 都是**百分比**（0~100），原点左上。
左右翼常用宽度 18.6~20.4，标题条 y 约 1~2、高 6~7。

**放置新卡片前先看【现有卡片】里的「位置 x,y,w,h」**，逐张算是否重叠：
矩形重叠的判据是 x1 < x2+w2 且 x2 < x1+w1 且 y1 < y2+h2 且 y2 < y1+h1。
两张卡**贴边不算重叠**（共边是常态）。

**这是硬性约束，不是建议**：系统会逐对校验你给的坐标，
有一处重叠就**整体拒绝**这次提案，用户看到的是「提案被拒」而不是「卡片放好了」。
所以宁可缩小尺寸、换到空白处，也不要硬塞。

安全区：x 在 2~98、y 在 2~97 之内；宽最小 8、高最小 6，超出会被系统钳回去
（钳回去之后可能就压住别人了，所以自己先留够余量）。

确实找不到空位时，缩小卡片或明确告诉用户「需要先腾出位置」，不要假装放下了。

## 硬性规则

- 只能操作**当前布局里已有**的卡片 id 做 update/remove/bind；新加才用 add。
- 用户说的卡片名要映射到 id：按 title 匹配，不要自己编 id。
- 需求不清时**不要猜**，在 content 里问一句，actions 留空。
- 涉及设备/测点的改动，如果上下文里没给出遥测键，就说「需要先确认遥测键」，不要编键名。
- bind-telemetry 的 slotKey 必须是上面列出的该卡片槽位之一，不要自己取名字。
- bind-telemetry 的 telemetryKey 只能从【可用遥测键】里挑；需要指定设备时，
  deviceId 只能从【可绑定设备】里挑。
- 要绑数据但【可用遥测键】为空时：说明原因，不要用占位键名凑一个提案。
- add-widget 的 slots **必须照【卡片类型与槽位模板】给**：键名逐字一致，
  不要自造。标「取数范围」的槽位不要填 telemetryKey。
- add-widget 时把该类型的「部件级设置」也写进 widget 顶层（如 dataSource/energyMetric），
  并按槽位模板带上默认 aggregate / displayType —— 不写的话卡片会是空白的。
- **但先判断用户要的是什么**：说「按能源品种/分项看」才写 dataSource=energy；
  说「几台设备之间比高低」就不要写 dataSource，否则会变成一张分项占比卡。
- 类型模板里标「范围槽位」的项**不要放进 slots**，改成写 widget.scope，
  值必须是**对象**（不是字符串），内容照抄【默认取数范围】那一行。
- 标「按设备逐台各读一个值」的类型（device-list / bar-compare），
  测点槽位**不要加 aggregate**。加了会让它去求历史聚合，
  表现为「等待范围内设备上报 … 的历史（用于求平均）」，而它要的是每台的最新值。
`;

/* ───────────────────────── 并发闸门 ───────────────────────── */

let running = 0;
const waiting = [];

function acquire() {
  if (running < MAX_CONCURRENCY) {
    running += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => waiting.push(resolve));
}

function release() {
  const next = waiting.shift();
  if (next) {
    /* 直接把手上的名额交出去，running 不减少 —— 避免中间被插队 */
    next();
    return;
  }
  running -= 1;
}

/* ───────────────────────── 调用 codewhale ───────────────────────── */

/**
 * 校验调用者身份（2026-11-24）。
 *
 * <p>共享密钥只证明「请求来自自家 nginx」。它挡不住「能访问 8090 的任何人」 ——
 * 实测不带任何凭据也能拿到 200 与完整回答。这里补第二道闸门：
 * 把 `X-Authorization` 拿去问平台，只放行租户管理员与系统管理员。
 *
 * <p>失败一律**说清原因**，不要笼统 401：用户看到「登录已失效」
 * 会去重新登录，看到「只有租户管理员可以用」就知道是权限问题，
 * 看到「平台不可达」会去找运维 —— 三种情况处置完全不同。
 *
 * @returns {{ok:true, user:object} | {ok:false, status:number, error:string}}
 */
async function verifyCaller(req) {
  const raw = String(req.headers["x-authorization"] || "");
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    return { ok: false, status: 401, error: "未授权：缺少平台登录凭据。请先登录 3D-NGX 再使用 AI 搭建。" };
  }
  let res;
  try {
    res = await fetch(`${PLATFORM_BASE}/api/auth/user`, {
      headers: { "X-Authorization": `Bearer ${token}` },
      signal: AbortSignal.timeout(8000),
    });
  } catch (e) {
    return { ok: false, status: 503, error: `无法校验登录状态（平台不可达：${e?.message || e}）。` };
  }
  if (!res.ok) {
    /* 401/403 都归到「登录已失效」：对用户来说动作一样，重新登录。 */
    return { ok: false, status: 401, error: `登录已失效（平台返回 ${res.status}）。请重新登录后再试。` };
  }
  let user;
  try {
    user = await res.json();
  } catch (e) {
    return { ok: false, status: 503, error: "无法解析平台返回的用户信息。" };
  }
  const authority = String(user?.authority || "");
  if (!ALLOWED_AUTHORITIES.includes(authority)) {
    return {
      ok: false,
      status: 403,
      error: `只有租户管理员可以使用 AI 搭建（当前身份：${authority || "未知"}）。`,
    };
  }
  return { ok: true, user };
}

/**
 * 组装发给模型的单条 prompt。
 *
 * <p>把「系统提示 + 场景上下文 + 历史对话 + 本轮问题」拼成一段文本，
 * 而不是依赖多轮 messages 协议 —— `codewhale exec` 收的是**一条** prompt，
 * 没有 messages 数组。自己去维护会话状态反而更简单可控。
 */
function buildPrompt(messages, context) {
  const lines = [];

  if (context && typeof context === "object") {
    const bits = [];
    if (context.name) bits.push(`场景名「${context.name}」`);
    if (context.site) bits.push(`场站「${context.site}」`);
    if (context.widgets != null) bits.push(`当前 ${context.widgets} 张卡片`);
    if (context.bindings != null) bits.push(`${context.bindings} 条设备绑定`);
    if (bits.length) lines.push(`【当前场景】${bits.join("，")}`);
  }

  /*
   * 现有卡片清单（含槽位）。
   *
   * 第一层是 id 与 title 的对应关系 —— 不给它，模型会凭标题猜一个 id，
   * 提案必然报「找不到卡片」。
   *
   * 第二层是**槽位键**（2026-11-24 补）。`bind-telemetry` 必须带 `slotKey`，
   * 而槽位键和卡片标题完全是两回事（`main` / `limit` / `rows` …）。
   * 不告诉它的直接后果实测过：AI 一次也没成功绑过数据，
   * 每次都只能说「上下文未提供遥测键」。
   */
  const widgets = Array.isArray(context?.widgetList) ? context.widgetList : [];
  if (widgets.length) {
    lines.push("【现有卡片】（id | 类型 | 标题 | 位置 x,y,w,h）");
    for (const w of widgets.slice(0, 40)) {
      const box = w.box
        ? `${w.box.x},${w.box.y},${w.box.w},${w.box.h}`
        : "?";
      /*
       * 统计口径也印在卡片行上（2026-11-24）。
       *
       * <p>客户要求：「最起码用户可以参与告诉 AI 现场是什么情况，
       * 好让他修改大屏的布局和统计维度」。
       *
       * <p>只看「类型 + 标题」模型分不清这张卡读的是设备遥测还是场站能耗；
       * 用户说「改成看碳排」时它不知道该改哪个字段。把口径印出来，
       * 它就能直接把 energyMetric 从 usage 改成 carbon。
       */
      const stats = w.stats && typeof w.stats === "object" ? w.stats : null;
      const statsText = stats
        ? [
            `口径 ${stats.dataSource === "energy" ? "场站能耗" : "设备遥测"}`,
            stats.energyMetric ? `统计项 ${stats.energyMetric}${stats.energyMetricDefaulted ? "（类型默认，未显式配置）" : ""}` : "",
            stats.energyKind ? `品种 ${stats.energyKind}` : "",
          ].filter(Boolean).join("，")
        : "";
      const rangeText = [
        w.filterText ? `设备过滤「${w.filterText}」` : "",
        w.scope ? `范围 ${w.scope}` : "",
      ].filter(Boolean).join("，");
      lines.push(`  ${w.id} | ${w.type} | ${w.title ?? ""} | ${box}`
        + (statsText ? ` | ${statsText}` : "")
        + (rangeText ? ` | ${rangeText}` : ""));
      const slots = Array.isArray(w.slots) ? w.slots : [];
      for (const s of slots.slice(0, 12)) {
        const extra = [
          s.label ? `标签「${s.label}」` : "",
          s.unit ? `单位 ${s.unit}` : "",
          s.telemetryKey ? `已绑 ${s.telemetryKey}` : "未绑",
        ].filter(Boolean).join("，");
        lines.push(`      槽位 ${s.key}（${extra}）`);
      }
    }
  }

  /*
   * 卡片类型的槽位模板（2026-11-24 补）。
   *
   * <p>没有这段，模型**不能新增卡片** —— 它不知道那种类型该有哪些槽位键。
   * 实测原话：「上下文未提供 trend-chart 的槽位定义，不能瞎绑」，
   * 然后拒绝出提案。它没错：槽位键是设计契约，猜错就是 slot-not-found，
   * 而提案是**整体拒绝**、不做部分应用。
   */
  const types = Array.isArray(context?.widgetTypes) ? context.widgetTypes : [];
  if (types.length) {
    lines.push("【卡片类型与槽位模板】（新增该类型时必须按此给 slots）");
    for (const t of types.slice(0, 20)) {
      const size = t.defaultSize ? `默认 ${t.defaultSize.w}×${t.defaultSize.h}` : "";
      const perDevice = t.perDevice ? "，按设备逐台各读一个值" : "";
      lines.push(`  ${t.type}（${t.label ?? ""}${size ? "，" + size : ""}${perDevice}）`);
      for (const s of (t.slots ?? []).slice(0, 12)) {
        if (s.usesScope) {
          /*
           * ★ scope 槽位**不进 slots 数组**（2026-11-24 实测踩到）。
           *
           * <p>它是「取数范围」的配置入口，实例化后会变成 `widget.scope`。
           * 真库里 load-compare 的 slots 只有 `load`，scope 在顶层。
           *
           * <p>AI 不知道这一点时，会把 scope 写进 slots —— 于是卡上有
           * 一个永远为空的「范围」槽位，而 `widget.scope` 缺失，
           * 渲染层不知道取哪些设备，卡片显示「还没有绑定设备」。
           */
          lines.push(`      范围槽位 ${s.key}「${s.name ?? ""}」→ 不要写进 slots，`
            + "改用 widget.scope（见【默认取数范围】）");
          continue;
        }
        const bits = [s.valueType ?? "", "测点"];
        if (s.aggregate) bits.push(`默认 aggregate=${s.aggregate}`);
        if (s.displayType) bits.push(`displayType=${s.displayType}`);
        /* ★ 逐台类型绝不能带 aggregate，见下方规则说明 */
        if (t.perDevice) bits.push("不要加 aggregate");
        lines.push(`      槽位 ${s.key}「${s.name ?? ""}」（${bits.join("，")}）`);
      }
      /*
       * 取数口径必须一起给（2026-11-24）。
       *
       * 只给槽位不够：两张卡槽位可以完全一样，区别只在「走场站能量口径
       * 还是走设备遥测」。缺这一段，AI 新建的 trend-chart 会走设备路径，
       * 而它名下没有 deviceId —— 结果是一张**空白卡片，且不报错**。
       */
      if (t.settings && Object.keys(t.settings).length) {
        const kv = Object.entries(t.settings).map(([k, v]) => `${k}=${v}`).join(" ");
        lines.push(`      部件级设置：${kv}（写在 widget 顶层，不是 slots 里）`);
        /*
         * ★ dataSource=energy 会**换掉整张卡的语义**，不只是换个数据源。
         *
         * <p>以 bar-compare 为例（2026-11-24 实测踩到）：
         * 写 dataSource=energy + energyMetric=ranking 时，它渲染的是
         * **能源品种分项**（电能/热力/蒸汽各占多少）；
         * 不写 dataSource 时，它才是**设备之间同一点位的对比**（9 台机组功率）。
         *
         * <p>只给 settings 不说这个区别，模型会把「9 台机组功率对比」
         * 做成一张和「用能分项占比」长得一样的卡 —— 而两者标题不同、
         * 内容一样，现场会以为是 bug。
         */
        if (t.settings.dataSource === "energy") {
          lines.push("      注意：带 dataSource=energy 时这张卡显示「能源品种分项」；"
            + "要做「多台设备同一测点对比」就不要写 dataSource。");
        }
      }
    }
  }

  /*
   * 可用的遥测键与设备（2026-11-24 补）。
   *
   * <p>这是「绑定」这件事的前提。键名**不能由模型编** —— 编出来的键
   * 在大屏上永远是空值，而且不报错，现场根本查不出为什么没数。
   *
   * <p>所以只列场景已有绑定里出现过的键：那些是用户配好、正在刷数的。
   * 清单为空意味着「这个场景还没绑过设备」，此时正确做法是说清楚，
   * 而不是猜一个键名。
   */
  /*
   * 统计维度词表（2026-11-24）。
   *
   * <p>客户说「其实就是知识库提供给 AI」—— 这是知识库中关于口径的那份。
   * 没有它，模型只知道有个 energyMetric 字段，不知道能改成哪几个值，
   * 于是用户说「改成看碳排」时它只能瞎猜一个字符串（然后被 schema 丢弃）。
   */
  const vocab = context?.statsVocabulary && typeof context.statsVocabulary === "object"
    ? context.statsVocabulary : null;
  if (vocab) {
    lines.push("【统计维度】（改统计口径时只能用这些值）");
    for (const item of (Array.isArray(vocab.dataSource) ? vocab.dataSource : [])) {
      lines.push(`  dataSource=${item.value}｜${item.label}：${item.note ?? ""}`);
    }
    for (const item of (Array.isArray(vocab.energyMetric) ? vocab.energyMetric : [])) {
      lines.push(`  energyMetric=${item.value}｜${item.label}：${item.note ?? ""}`);
    }
    if (vocab.energyKindNote) lines.push(`  energyKind：${vocab.energyKindNote}`);
    const defaults = Array.isArray(vocab.defaultsByType) ? vocab.defaultsByType : [];
    if (defaults.length) {
      lines.push("  不填时的默认值：" + defaults
        .map((d) => `${d.type}→${d.energyMetric ?? d.dataSource}`)
        .join("，"));
    }
    lines.push("  改口径用 update-widget 的 patch（dataSource / energyMetric / energyKind 是 widget 顶层字段，不是 slots）。");
  }

  const keys = Array.isArray(context?.telemetryKeys) ? context.telemetryKeys : [];
  if (keys.length) {
    lines.push("【可用遥测键】（只能从这里挑，不要编）");
    for (const k of keys.slice(0, 60)) {
      const bits = [
        k.label ? `标签「${k.label}」` : "",
        k.unit ? `单位 ${k.unit}` : "",
        k.deviceCount ? `${k.deviceCount} 台设备有` : "",
      ].filter(Boolean).join("，");
      lines.push(`  ${k.key}${bits ? `（${bits}）` : ""}`);
    }
  } else if (widgets.length) {
    /*
     * 有卡片但没有任何键 —— 新场景的常态。
     * 明说一句，避免模型「努力」编一个看似合理的键名出来。
     */
    lines.push("【可用遥测键】无。本场景还没有任何设备绑定，不知道设备上报哪些键。"
      + "涉及数据的改动请在 content 里说明「需要先在绑定面板配好设备」，actions 只做不依赖数据的部分。");
  }

  /*
   * 默认取数范围（2026-11-24）。
   *
   * <p>新增 device-list / bar-compare 这类「按范围取设备」的卡时，
   * widget.scope 必须有值，否则卡片显示「还没有绑定设备」。
   * AI 编不出 UUID，只能从这里抄。
   */
  const sceneScope = context?.sceneScope;
  if (sceneScope && (sceneScope.siteId || sceneScope.topologyId)) {
    /*
     * 输出成 **JSON 对象原文**，不是 "k=v" 串。
     *
     * <p>第一版写成 `kind=topology topologyId=…`，模型照抄成一个字符串塞进
     * `widget.scope` —— 而 scope 必须是对象，字符串会被解析器丢弃，
     * 卡片于是显示「还没有绑定设备」。给形状比给描述可靠。
     */
    const scopeObject = { kind: sceneScope.kind };
    if (sceneScope.topologyId) scopeObject.topologyId = sceneScope.topologyId;
    if (sceneScope.topologyName) scopeObject.topologyName = sceneScope.topologyName;
    if (sceneScope.siteId) scopeObject.siteId = sceneScope.siteId;
    if (sceneScope.siteName) scopeObject.siteName = sceneScope.siteName;
    lines.push(`【默认取数范围】需要范围的新卡，widget.scope 用这个对象（原样复制）：`);
    lines.push(`      ${JSON.stringify(scopeObject)}`);
  }

  const devices = Array.isArray(context?.devices) ? context.devices : [];
  if (devices.length) {
    lines.push("【可绑定设备】（id | 名称）");
    for (const d of devices.slice(0, 24)) {
      lines.push(`  ${d.id} | ${d.name ?? ""}`);
    }
  }

  /*
   * 模板底稿 + 用户已做的偏离（2026-11-24）。
   *
   * <p>客户原话：「我还是想通过不断的修改实例化的模板来更好的和 AI 交互理解」。
   *
   * <p>用户手工挪卡、改标题，本身就是偏好的表达。只给「现状」的话，
   * 模型分不清「这是模板原样」还是「用户特意改的」，于是会把人做的调整
   * 当成模板原样的样子，甚至好心改回去。
   *
   * <p>给出基线 + 偏离后，它能读出意图：「告警卡被从右下挪到右中 →
   * 用户更看重告警 → 加新卡时避开这块」。
   */
  const baseline = context?.templateBaseline && typeof context.templateBaseline === "object"
    ? context.templateBaseline : null;
  if (baseline) {
    lines.push(`【模板底稿】${baseline.name ?? ""}（${baseline.templateId ?? ""}）`);
    const regions = Array.isArray(baseline.regions) ? baseline.regions : [];
    if (regions.length) {
      lines.push("  模板规划的区域（id | 类型 | 标题 | 位置 x,y,w,h）：");
      for (const r of regions.slice(0, 40)) {
        const b = r.box ? `${r.box.x},${r.box.y},${r.box.w},${r.box.h}` : "?";
        lines.push(`    ${r.id} | ${r.type} | ${r.title ?? ""} | ${b}`);
      }
    }
    const dev = baseline.deviations && typeof baseline.deviations === "object" ? baseline.deviations : null;
    if (dev) {
      const notes = [];
      for (const d of (Array.isArray(dev.removed) ? dev.removed : []).slice(0, 20)) {
        notes.push(`    删除：${d.id}（${d.type}｜${d.title ?? ""}）`);
      }
      for (const d of (Array.isArray(dev.added) ? dev.added : []).slice(0, 20)) {
        notes.push(`    新增：${d.id}（${d.type}｜${d.title ?? ""}）`);
      }
      for (const d of (Array.isArray(dev.moved) ? dev.moved : []).slice(0, 20)) {
        notes.push(`    位置改动：${d.id}（${d.title ?? ""}）${d.from} → ${d.to}`);
      }
      for (const d of (Array.isArray(dev.retitled) ? dev.retitled : []).slice(0, 20)) {
        notes.push(`    改名：${d.id}「${d.from}」→「${d.to}」`);
      }
      if (notes.length) {
        lines.push("  ★ 用户相对模板做过的调整（这是他的偏好，不要当成错误改回去）：");
        lines.push(...notes);
      }
    }
  }


  /*
   * 模板文档（2026-11-24）。
   *
   * <h3>为什么必须有这一层</h3>
   *
   * <p>客户要求：「我可以在文件资源管理器中编辑我的需求，然后让 AI 读取
   * 帮我开发 AI 构建大屏」。
   *
   * <p>此前 AI 只能看到**当前场景的结构**（有哪些卡、哪些遥测键），
   * 看不到「作者想让这个模板长什么样」。于是它每次都得从零推测意图，
   * 而意图本来就该由人写在文件里。
   *
   * <p>数据来自模板资产里的文本文件（`requirements.md` / `SKILL.md` /
   * `schema.json` 等），前端读好随 `context.templateDocs` 发过来 ——
   * bridge 不直连平台（它没有租户令牌，也不该有）。
   *
   * <h3>上限</h3>
   *
   * <p>逐份截断 + 总长封顶：一份 requirements.md 可能被写成几万字，
   * 全塞进 prompt 会让模型抓不住重点，也会拖慢响应（实测一次 5~20 秒，
   * 再长用户就开始怀疑卡死）。需求文档本身就该是精炼的。
   */
  const docs = Array.isArray(context?.templateDocs) ? context.templateDocs : [];
  if (docs.length) {
    const MAX_DOC_CHARS = 6000;
    const MAX_DOCS_CHARS = 16000;
    let used = 0;
    const blocks = [];
    for (const doc of docs) {
      const name = String(doc?.name ?? "").trim();
      const content = String(doc?.content ?? "").trim();
      if (!name || !content) continue;
      const room = Math.min(MAX_DOC_CHARS, MAX_DOCS_CHARS - used);
      if (room <= 200) break; /* 剩余空间已经放不下有意义的内容 */
      const body = content.length > room ? `${content.slice(0, room)}\n…（已截断）` : content;
      blocks.push(`--- ${name} ---\n${body}`);
      used += body.length;
    }
    if (blocks.length) {
      lines.push("【模板文件】（作者写的需求与约定，优先级高于你的默认假设）");
      lines.push(...blocks);
    }
  }

  const history = messages.slice(-MAX_HISTORY);
  if (history.length > 1) {
    lines.push("【对话】");
    for (const m of history.slice(0, -1)) {
      const who = m.role === "user" ? "用户" : m.role === "assistant" ? "助手" : "系统";
      lines.push(`${who}：${String(m.content ?? "").slice(0, MAX_MESSAGE_CHARS)}`);
    }
  }

  const last = history[history.length - 1];
  lines.push("【本轮要求】");
  lines.push(String(last?.content ?? "").slice(0, MAX_MESSAGE_CHARS));

  return `${SYSTEM_PROMPT}\n\n${lines.join("\n")}`;
}

/** 从模型输出里抠出 JSON。模型经常包 ```json 或前后带解释。 */
function extractJson(text) {
  const raw = String(text ?? "").trim();
  if (!raw) return null;

  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(raw);
  const candidate = fenced ? fenced[1].trim() : raw;

  const tryParse = (s) => {
    try {
      const v = JSON.parse(s);
      return v && typeof v === "object" && !Array.isArray(v) ? v : null;
    } catch {
      return null;
    }
  };

  const direct = tryParse(candidate);
  if (direct) return direct;

  /*
   * 退化路径：从第一个 { 到最后一个 } 截取。
   *
   * <p>模型常写成「好的，我建议这样改：{...}  希望有帮助」。
   * 直接 JSON.parse 失败时，截取最大括号区间还有机会救回来 ——
   * 比整条回答变成「解析失败」有用得多。
   */
  const start = candidate.indexOf("{");
  const end = candidate.lastIndexOf("}");
  if (start >= 0 && end > start) return tryParse(candidate.slice(start, end + 1));
  return null;
}

function runCodewhale(prompt, workdir) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let out = "";
    let err = "";
    let settled = false;

    const child = spawn(CODEWHALE_BIN, ["exec", "--json", "--permission-mode", "plan", prompt], {
      cwd: workdir,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try {
        child.kill("SIGKILL");
      } catch {
        /* 已经退出 */
      }
      resolve({ ok: false, code: "timeout", message: `模型响应超过 ${Math.round(TIMEOUT_MS / 1000)} 秒`, elapsedMs: Date.now() - startedAt });
    }, TIMEOUT_MS);

    child.stdout.on("data", (d) => {
      out += d.toString("utf8");
      /* 简单兜底：输出总量上限，防模型吐几 MB */
      if (out.length > 512 * 1024) {
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
      }
    });
    child.stderr.on("data", (d) => {
      err += d.toString("utf8");
    });

    child.on("error", (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ ok: false, code: "spawn-failed", message: e.message, elapsedMs: Date.now() - startedAt });
    });

    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const elapsedMs = Date.now() - startedAt;

      let parsed = null;
      try {
        parsed = JSON.parse(out);
      } catch {
        parsed = null;
      }

      if (code !== 0) {
        resolve({
          ok: false,
          code: "nonzero-exit",
          message: (parsed?.error || err || `codewhale 退出码 ${code}`).slice(0, 400),
          elapsedMs,
        });
        return;
      }
      if (!parsed) {
        resolve({ ok: false, code: "bad-json", message: "codewhale 没有返回 JSON 摘要", elapsedMs });
        return;
      }
      resolve({ ok: true, envelope: parsed, elapsedMs });
    });
  });
}

/* ───────────────────────── 请求处理 ───────────────────────── */

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    "Cache-Control": "no-store",
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("请求体过大"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

async function handleChat(req, res) {
  try {
    await handleChatInner(req, res);
  } catch (e) {
    console.error("[ai-bridge] handleChat 失败:", e && (e.stack || e.message || e));
    try {
      sendJson(res, 500, { content: "", error: `内部错误：${e && e.message ? e.message : e}` });
    } catch {
      /* 响应已经发出去就没办法了 */
    }
  }
}

async function handleChatInner(req, res) {
  let body;
  try {
    body = JSON.parse((await readBody(req)) || "{}");
  } catch (e) {
    sendJson(res, 400, { content: "", error: `请求体不是合法 JSON：${e.message}` });
    return;
  }

  const messages = Array.isArray(body.messages) ? body.messages : [];
  const last = messages[messages.length - 1];
  if (!last || last.role !== "user" || !String(last.content ?? "").trim()) {
    sendJson(res, 400, { content: "", error: "messages 的最后一条必须是用户消息" });
    return;
  }

  /* 每一轮对话都新建空目录：AI 看不到任何项目文件 */
  let workdir;
  try {
    workdir = mkdtempSync(join(tmpdir(), "ngx-ai-"));
  } catch (e) {
    sendJson(res, 500, { content: "", error: `创建临时目录失败：${e.message}` });
    return;
  }

  await acquire();
  try {
    const prompt = buildPrompt(messages, body.context);
    const result = await runCodewhale(prompt, workdir);

    if (!result.ok) {
      /*
       * 失败也返回 200 + 明确的 error 字段。
       *
       * <p>不用 5xx：前端把非 2xx 一律当「后端未接通」并提示去实现接口，
       * 而这里接口是通的，只是模型超时了。给错方向的提示比不给更糟。
       */
      sendJson(res, 200, {
        content: "",
        error: result.message,
        errorCode: result.code,
        elapsedMs: result.elapsedMs,
      });
      return;
    }

    const envelope = result.envelope;
    const modelOutput = String(envelope.output ?? "");
    const parsed = extractJson(modelOutput);

    if (parsed && typeof parsed.content === "string") {
      sendJson(res, 200, {
        content: parsed.content,
        actions: Array.isArray(parsed.actions) ? parsed.actions : [],
        model: envelope.model,
        provider: envelope.provider,
        elapsedMs: result.elapsedMs,
      });
      return;
    }

    /*
     * 模型没按格式输出 JSON（常见于它只想回答问题）。
     *
     * <p>这时**把原文当 content 返回**、actions 留空 —— 用户至少能看到
     * AI 说了什么。硬要解析成 JSON 会得到一句「格式错误」，
     * 而那对用户没有任何帮助。
     */
    sendJson(res, 200, {
      content: modelOutput.trim() || "（模型没有返回内容）",
      actions: [],
      model: envelope.model,
      provider: envelope.provider,
      elapsedMs: result.elapsedMs,
      note: "模型未按 JSON 格式回答，本次没有可应用的布局改动。",
    });
  } catch (e) {
    sendJson(res, 500, { content: "", error: `内部错误：${e.message}` });
  } finally {
    release();
    try {
      rmSync(workdir, { recursive: true, force: true });
    } catch {
      /* 临时目录清不掉不影响结果 */
    }
  }
}

/*
 * 兜底日志（2026-11-24）。
 *
 * <p>实测踩到过：处理某个请求时进程直接消失、日志里什么都没有 ——
 * 后台进程的未捕获异常默认打到 stderr，而脚本把它重定向进了日志，
 * 但 pm 层级一旦有 unhandledRejection，node 会以非零码退出。
 * 加这两行让「为什么死了」至少留下痕迹。
 */
process.on("uncaughtException", (e) => {
  console.error("[ai-bridge] uncaughtException:", e && (e.stack || e.message || e));
});
process.on("unhandledRejection", (e) => {
  console.error("[ai-bridge] unhandledRejection:", e && (e.stack || e.message || e));
});

const server = http.createServer((req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);

  if (url.pathname === "/healthz") {
    sendJson(res, 200, { ok: true, running, waiting: waiting.length, maxConcurrency: MAX_CONCURRENCY });
    return;
  }

  if (url.pathname !== "/api/ngx/ai/chat") {
    sendJson(res, 404, { content: "", error: `未知路径 ${url.pathname}` });
    return;
  }
  if (req.method !== "POST") {
    sendJson(res, 405, { content: "", error: "只支持 POST" });
    return;
  }

  /*
   * 密钥比对用 timingSafeEqual：
   * 普通字符串比较会在第一个不同字节就返回，理论上能被逐字节猜出来。
   * 这里的攻击面很小，但常量时间比较是无成本的正确做法。
   */
  const given = String(req.headers["x-ngx-ai-key"] || "");
  const a = Buffer.from(given);
  const b = Buffer.from(SHARED_KEY);
  const authorized = SHARED_KEY.length > 0 && a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!authorized) {
    sendJson(res, 401, { content: "", error: "未授权：缺少或错误的 X-Ngx-Ai-Key" });
    return;
  }

  /*
   * 第二道闸门：调用者是谁（2026-11-24）。
   * 共享密钥只说明「来自自家 nginx」，不说明「是个已登录的租户管理员」。
   */
  void (async () => {
    const caller = await verifyCaller(req);
    if (!caller.ok) {
      sendJson(res, caller.status, { content: "", error: caller.error });
      return;
    }
    void handleChat(req, res);
  })();
});

if (!SHARED_KEY) {
  console.error("[ai-bridge] 拒绝启动：必须设置 NGX_AI_KEY（共享密钥）。");
  console.error("[ai-bridge] 生成方法：node -e \"console.log(require('crypto').randomBytes(24).toString('hex'))\"");
  process.exit(1);
}

server.listen(PORT, HOST, () => {
  console.log(`[ai-bridge] 监听 http://${HOST}:${PORT}`);
  console.log(`[ai-bridge] codewhale = ${CODEWHALE_BIN}`);
  console.log(`[ai-bridge] 并发上限 ${MAX_CONCURRENCY}，超时 ${Math.round(TIMEOUT_MS / 1000)}s，模式 plan（只读）`);
});

/* 优雅退出：把在跑的子进程也带走，不留僵尸 */
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    console.log(`[ai-bridge] 收到 ${sig}，退出`);
    server.close(() => process.exit(0));
  });
}

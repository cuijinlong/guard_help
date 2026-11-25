# AI 搭建桥接服务

把 3D-NGX 大屏编辑器的「AI 搭建」面板接到本机 **codewhale**。

```
浏览器 (AiBuildPanel)
   │  POST /api/ngx/ai/chat
   │  X-Authorization: Bearer <平台登录令牌>        ← ① 调用者是谁
   ▼
nginx (energy-gateway)  ── /api/ngx/ai/ ──▶  宿主机 host.docker.internal:8092
   │  注入 X-Ngx-Ai-Key                          ← ② 请求来自自家网关
   ▼
ai-bridge (8092)
   │  拿 ① 去 GET /api/auth/user 验一遍           ← ③ 必须是租户管理员
   │  spawn
   ▼
codewhale exec --json --permission-mode plan
```

### 三道闸门，各管一件事（2026-11-24 补齐）

| # | 校验 | 挡的是 | 谁提供 |
| --- | --- | --- | --- |
| ① | `X-Authorization` → `GET /api/auth/user` | **未登录 / 客户角色** | 浏览器 |
| ② | `X-Ngx-Ai-Key` | 绕过 nginx 直连 8092 | nginx |
| ③ | 角色 ∈ {TENANT_ADMIN, SYS_ADMIN} | 客户角色（进不到编辑器） | ai-bridge |

**为什么必须有三道，而不是只留 ②**：建这个服务时只有 ②，
实测发现不带任何登录凭据直接 `POST http://127.0.0.1:8090/api/ngx/ai/chat`
**返回 200 和完整的 AI 回答** —— 只要能访问 8090，谁都能白嫖这台机器上
codewhale 的模型额度。②只证明「请求来自自家 nginx」，不证明背后是谁。

> 桥接必须监听 `0.0.0.0`（容器要经 `host.docker.internal` 访问宿主），
> 所以靠 ② 的密钥挡住局域网直连。密钥是 48 位十六进制随机串，
> 生成后不要外传。

---

## 为什么需要它

「AI 搭建」的 UI 与契约在 `apps/web/src/features/scene-editor/AiBuildPanel.tsx`，
后端契约 `POST /api/ngx/ai/chat` 由本服务实现。

codewhale 是**宿主机**上的 CLI，Java 后端跑在容器里，既没有这个二进制，
也不该持有用户的模型凭据。所以桥接单独跑在宿主机，nginx 转发一条路径过去。

> **一个运行前提**：桥接要拿用户的令牌去平台验身份（`GET /api/auth/user`）。
> 所以**平台必须在线** —— 平台挂了，AI 搭建也会返回 503
> 「无法校验登录状态（平台不可达）」。
> 这是刻意的：宁可明确报错，也不留一条绕过身份校验的路。

---

## 安装（三步）

```bash
# 0. 前提：node ≥ 22、codewhale 已安装且 `codewhale --version` 能跑
codewhale --version

# 1. 部署文件并生成密钥
mkdir -p ~/energy-app/ai-bridge
cp ai-bridge/*.js ai-bridge/*.sh ~/energy-app/ai-bridge/
chmod +x ~/energy-app/ai-bridge/*.sh
bash ~/energy-app/ai-bridge/start.sh        # 首次会生成 .key

# 2. 注册成系统服务（★ 关键，别跳过）
bash ~/energy-app/ai-bridge/install-service.sh

# 3. 接进 nginx
bash ~/energy-app/ai-bridge/wire-nginx.sh
```

> **为什么第 2 步不能省**：直接用 `nohup node server.js &` 起的进程挂在那个 shell 上，
> 终端一关就死 —— 表现为「启动了但过一会儿 connection refused」，日志里只有启动那三行。
> 这不是代码问题，是托管方式不对。launchd / systemd 才是正确的托管。

---

## 验证

```bash
# 桥接直连（健康端点不需要密钥）
curl -s http://127.0.0.1:8092/healthz
# → {"ok":true,"running":0,"waiting":0,"maxConcurrency":2}

# 三道闸门各验一次（TOKEN = 租户令牌，CUST = 客户令牌）
KEY=$(cat ~/energy-app/ai-bridge/.key)

# 无凭据 → 401「缺少平台登录凭据」
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8090/api/ngx/ai/chat \
  -H 'Content-Type: application/json' -d '{"messages":[]}'
# 租户 → 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8090/api/ngx/ai/chat \
  -H "X-Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
# 客户 → 403「只有租户管理员可以使用」
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8090/api/ngx/ai/chat \
  -H "X-Authorization: Bearer $CUST" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}' 

# 经 nginx（浏览器实际走的路径）
curl -s -X POST http://127.0.0.1:8090/api/ngx/ai/chat \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"用一句话说明你是谁"}]}'
# → {"content":"我是「3D-NGX 工业三维数字孪生大屏」的搭建助手…","actions":[],"model":"deepseek-v4-pro",…}
```

带布局改动的问题，会返回可应用的 `actions`：

```bash
curl -s -X POST http://127.0.0.1:8090/api/ngx/ai/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "messages":[{"role":"user","content":"把「场站用电趋势」改名成「机组功率趋势」"}],
    "context":{
      "name":"天骄科技园",
      "widgetList":[{"id":"power-trend","type":"trend-chart","title":"场站用电趋势"}]
    }
  }'
```

```json
{
  "content": "把「场站用电趋势」卡片改名为「机组功率趋势」。",
  "actions": [{ "op": "update-widget", "id": "power-trend", "patch": { "title": "机组功率趋势" } }],
  "model": "deepseek-v4-pro",
  "elapsedMs": 5993
}
```

---

## 安全边界

这是最要紧的部分 —— 这个服务能让一个模型影响生产大屏。

| 边界 | 做法 | 为什么 |
| --- | --- | --- |
| **只读** | 固定 `--permission-mode plan` | AI 不改文件、不跑写命令。它只产出**提案**，落地由前端校验 + 人点确认 |
| **工作目录** | 每轮新建空临时目录（`mkdtempSync`） | 即使换了模式，也读不到项目源码 |
| **共享密钥** | `X-Ngx-Ai-Key`，`timingSafeEqual` 比对 | 服务必须监听 `0.0.0.0`（容器要走宿主 IP），靠密钥兜底 |
| **并发上限** | 默认 2 | 每次调用是独立进程，并发放开会打满机器 |
| **超时** | 150s（nginx 180s） | 让桥接先超时并返回结构化错误，而不是 nginx 先断、前端只看到 504 |
| **不拼 shell** | `spawn(bin, [args])` 数组传参 | 用户输入里的引号/分号/反引号都只是普通字符 |

**为什么不让 AI 直接调用工具改布局**：那等于把平台操作权交给一个可能理解错需求的模型。
当前设计下，出错的代价是一份被拒绝的提案，不是一次误操作。

---

## 配置项（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NGX_AI_PORT` | 8092 | 监听端口 |
| `NGX_AI_HOST` | 0.0.0.0 | 必须能被子网访问 |
| `NGX_AI_KEY` | **必填** | 共享密钥；未设置则拒绝启动 |
| `NGX_AI_TIMEOUT_MS` | 150000 | 单次对话超时 |
| `NGX_AI_MAX_CONCURRENCY` | 2 | 并发上限 |
| `NGX_CODEWHALE_BIN` | `codewhale` | 二进制路径（launchd 下 PATH 可能不同） |

密钥写在 `~/energy-app/ai-bridge/.key`（权限 600），`wire-nginx.sh` 会把它注入 nginx 配置。

---

## 常见问题

**「codewhale: Node.js 22 or newer is required」**

launchd / systemd 的 PATH 里 `node` 可能是旧版本（本机 `/usr/local/bin/node` 是 v20）。
`install-service.sh` 已把 `dirname(node)` 放在 PATH **最前**，因为 codewhale 的 wrapper 是
`#!/usr/bin/env node`，它按 PATH 找 node。

手工跑正常、服务里报这个错，就是 PATH 顺序问题。

**「启动成功但过一会儿 connection refused」**

进程被 shell 退出带走了。跑 `install-service.sh`。

**「nginx 502」**

三段分别查：

```bash
curl -s http://127.0.0.1:8092/healthz                      # 桥接活着吗
docker exec energy-gateway wget -qO- http://host.docker.internal:8092/healthz   # 容器能到宿主吗
docker logs energy-gateway --tail 20                       # nginx 说什么
```

**「模型没按 JSON 回答」**

桥接会把原文当 `content` 返回、`actions` 为空，并带 `note` 说明。
这比硬解析失败报「格式错误」有用 —— 用户至少看到 AI 说了什么。

**Linux 上 `host.docker.internal` 不解析**

在 compose 里给 gateway 加：

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

---

## 卸载

```bash
bash ~/energy-app/ai-bridge/install-service.sh --uninstall
bash ~/energy-app/ai-bridge/wire-nginx.sh --remove
```

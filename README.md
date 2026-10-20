# 手册站点（shiyongshouce）

静态站点，零构建，可直接部署到 Cloudflare Pages。

## 本地预览

必须用 HTTP 服务打开，**不能双击 index.html**（`file://` 下 fetch 会被 CORS 拦住）。

```bash
cd shiyongshouce
python3 -m http.server 8899
# 打开 http://127.0.0.1:8899/
```

## 目录结构

```
shiyongshouce/
├── index.html              入口（勿动，除非改整体框架）
├── assets/
│   ├── app.js              路由 + Markdown 渲染 + 目录生成
│   ├── style.css           全站样式
│   └── vendor/
│       └── marked.min.js   Markdown 解析器（本地，不依赖 CDN）
├── content/
│   ├── manifest.json       ★ 导航结构的唯一来源
│   ├── user/               用户手册（客户视角）
│   └── admin/              系统运维手册（平台方视角）
└── _headers                Cloudflare Pages 缓存与安全响应头
```

## 加一页 / 改一页

**只改两个地方**：

1. 在 `content/user/` 或 `content/admin/` 下新建 `.md`
2. 在 `content/manifest.json` 对应 section 的 `items` 里加一条

```json
{ "id": "new-page", "title": "页面标题", "file": "user/05-new-page.md" }
```

`id` 决定 URL：`#/user/new-page`。`id` 一旦发布就不要再改 ——
外部链接和书签会失效。

## 写 Markdown 的约定

- 一级标题 `#` 只出现一次，作为页面标题
- 二级 `##` 会自动进右侧目录，三级 `###` 会缩进显示
- 章节之间用 `---` 分隔
- 代码块用三个反引号并标注语言
- 相对链接可以直接写文件名（如 `01-quick-start.md`），
  `app.js` 会自动转成 SPA 路由；找不到时保留原样

## 部署到 Cloudflare Pages

**方式一：连 Git 仓库（推荐）**

| 配置项 | 值 |
|---|---|
| Framework preset | None |
| Build command | （留空） |
| Build output directory | `shiyongshouce` |

推送后自动构建，几十秒生效。

**方式二：直接上传**

```bash
npx wrangler pages deploy shiyongshouce --project-name=energy-manual
```

**自定义域名**：Cloudflare Pages → Custom domains，按提示加 CNAME。

## 缓存策略

`_headers` 已经配好：

- `index.html` 与 `manifest.json`：`no-cache`，保证内容更新立即生效
- `assets/`：长缓存（文件名变更时靠版本号或重新部署失效）
- Markdown：短缓存，避免改完手册用户还看到旧版

## 维护节奏建议

| 时机 | 动作 |
|---|---|
| 每次发版 | 更新 `manifest.json` 的 `version` 与 `updated` |
| 新增功能 | 对应章节补一节，并在 FAQ 加一条 |
| 客户报问题 | 先修 FAQ，再考虑改进产品 |
| 每月 | 检查一遍「待补充」清单，清掉已完成项 |

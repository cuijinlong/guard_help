/**
 * 手册站点：manifest 驱动导航 + hash 路由 + 前端渲染 Markdown。
 *
 * <H3>为什么不用构建工具</H3>
 *
 * Cloudflare Pages 直接托管静态文件，零构建零依赖。
 * 加一页只需要改 manifest.json 再放一个 .md —— 不需要 Node、不需要 CI。
 * 代价是首次加载要 fetch manifest 和 md，但对一个手册站完全可以接受。
 *
 * <H3>路径约定</H3>
 *
 * 路由形如 #/user/quick-start，对应 manifest 里某 section 的 item.id。
 * markdown 文件路径由 manifest 显式给出，不在代码里拼 ——
 * 这样调整文件名不必改 JS。
 */

(function () {
  'use strict';

  const CONTENT_BASE = 'content/';

  let manifest = null;
  let currentKey = '';

  const navEl = document.getElementById('nav');
  const contentEl = document.getElementById('content');
  const tocEl = document.getElementById('toc');
  const versionEl = document.getElementById('version');
  const sidebarEl = document.getElementById('sidebar');

  // ---------------- 工具 ----------------

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /** 中文标题也能生成稳定锚点：保留中英文数字，其余转连字符 */
  function slugify(text) {
    return String(text)
      .trim()
      .toLowerCase()
      .replace(/[`*_~]/g, '')
      .replace(/[^\w\u4e00-\u9fa5-]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'section';
  }

  function resolveRoute() {
    const hash = location.hash.replace(/^#\/?/, '');
    if (!hash) return null;
    const parts = hash.split('/').filter(Boolean);
    if (!parts.length) return null;
    // 路径深度不固定：老的两级路由 #/admin/deploy，新的三级 #/menu-ops/customer/energy-overview
    return { sectionId: parts[0], path: parts.slice(1) };
  }

  /**
   * 按路径找节点。path 可以是字符串（旧的两级路由）或数组（任意深度）。
   *
   * 深度不写死，是因为菜单要跟系统的「一级 → 二级 → 三级」逐级对齐；
   * 写死两级后，加一层就得改路由、改渲染、改链接三处。
   */
  function findItem(sectionId, path) {
    if (!manifest) return null;
    const section = manifest.sections.find((s) => s.id === sectionId);
    if (!section) return null;
    const segs = Array.isArray(path) ? path : String(path || '').split('/').filter(Boolean);
    if (!segs.length) return null;
    let items = section.items;
    let found = null;
    for (const seg of segs) {
      found = (items || []).find((i) => i.id === seg);
      if (!found) return null;
      items = found.children;
    }
    return { section, item: found, key: sectionId + '/' + segs.join('/') };
  }

  // ---------------- 导航（可折叠树） ----------------
  //
  // 为什么做成树而不是全部铺开：
  //   「运维管理 → 客户」下有 26 个功能页，全展开要滚好几屏，找东西反而慢。
  //   平台左侧菜单就是折叠树，手册跟它保持一致，用起来不用换脑子。
  //
  // 状态存 localStorage：换页、刷新都保持用户上次的展开/收起，
  // 否则每跳一页都得重新点开一次。

  // ★ key 带版本号（-v2）：2026-11-25 把默认从「展开当前路径」改成「全部收起」。
  //   不带版本的话，老访客浏览器里存着上一版的展开状态，升级后打开
  //   **看到的还是展开的** —— 会以为「默认收缩没生效」。
  //   换 key 等于一次性作废旧偏好；之后用户自己的选择照常记住。
  const NAV_STATE_KEY = 'help-nav-collapsed-v2';
  /** 被收起的节点路径集合（如 'admin'、'menu-ops/customer/query'） */
  const collapsedPaths = new Set();
  let navStateStored = false;    // localStorage 里是否已有用户的显式状态
  let navDefaultApplied = false; // 首次的「全部收起」是否已生效
  let navVisited = false;        // 是否已经完成过首次渲染（用于区分「首次」与「导航」）

  function loadNavState() {
    try {
      const raw = localStorage.getItem(NAV_STATE_KEY);
      if (raw !== null) {
        navStateStored = true;
        JSON.parse(raw).forEach((p) => collapsedPaths.add(p));
      }
    } catch (e) { /* 隐私模式/file:// 下不可用：退化成全部展开，不影响阅读 */ }
  }

  function saveNavState() {
    try {
      localStorage.setItem(NAV_STATE_KEY, JSON.stringify([...collapsedPaths]));
    } catch (e) { /* 存不了就算了，本次会话内的折叠仍然有效 */ }
  }

  /**
   * 首次进入：**全部收起**。
   *
   * 客户明确要求「默认是收缩的」——平台左侧菜单进去也是全收的，
   * 手册保持一致。展开哪个组由用户自己点，不要替他猜。
   *
   * 先前的做法是「只展开当前页所在路径」，好处是能一眼看到自己在哪，
   * 但 26 个功能页展开后仍要滚很长；客户定了全收，就按全收。
   * 当前页藏在收起的分组里时，靠标题提亮（data-active-parent）提示位置。
   */
  function collapseAllByDefault() {
    if (navStateStored || navDefaultApplied || !manifest) return;
    navDefaultApplied = true;
    const walk = (items, prefix) => {
      for (const it of items || []) {
        const p = prefix + '/' + it.id;
        if (it.children && it.children.length) {
          collapsedPaths.add(p);
          walk(it.children, p);
        }
      }
    };
    for (const sec of manifest.sections) {
      if ((sec.items || []).length) collapsedPaths.add(sec.id);
      walk(sec.items, sec.id);
    }
  }

  /**
   * 跳转到某页时，把它所有祖先分组展开。
   *
   * 不这么做的话：用户收起「能耗查询」，再从别页点链接进来，
   * 当前页就藏在自己收起的组里 —— 只有标题高亮，看不见任何条目。
   *
   * 只用于**用户点击后的导航**；首次加载不调它，否则默认就不是「全收起」了。
   */
  function expandAncestors(activeKey) {
    const parts = String(activeKey || '').split('/').filter(Boolean);
    let changed = false;
    for (let i = 1; i < parts.length; i++) {
      const p = parts.slice(0, i).join('/');
      if (collapsedPaths.delete(p)) changed = true;
    }
    if (changed) saveNavState();
  }

  function caretHtml(path, open) {
    return `<button type="button" class="nav-caret-btn${open ? ' open' : ''}"
              data-toggle="${escapeHtml(path)}"
              aria-expanded="${open ? 'true' : 'false'}"
              aria-label="${open ? '收起' : '展开'}"></button>`;
  }

  /** 递归渲染菜单。有 children 的节点是可折叠分组，下面挂子项。 */
  function navItemsHtml(items, prefix, activeKey, depth) {
    return (items || []).map((item) => {
      const key = prefix + '/' + item.id;
      const active = key === activeKey ? ' class="active"' : '';
      const hasKids = Array.isArray(item.children) && item.children.length > 0;
      if (!hasKids) {
        return `<a href="#/${key}"${active}>${escapeHtml(item.title)}</a>`;
      }
      const open = !collapsedPaths.has(key);
      // 当前页就在这个折叠组里 → 标题上做个标记，收起时也知道「东西在这」
      const inHere = (activeKey || '') === key || (activeKey || '').startsWith(key + '/');
      // 有 file 就可点（显示该层总览），没有就只是可点开合的标题文字
      const title = item.file
        ? `<a class="nav-sub-title" href="#/${key}"${active}>${escapeHtml(item.title)}</a>`
        : `<span class="nav-sub-title is-plain">${escapeHtml(item.title)}</span>`;
      return `<div class="nav-sub-group nav-depth-${depth}" data-path="${escapeHtml(key)}"
        ${open ? '' : 'data-collapsed="true"'}${inHere ? ' data-active-parent="true"' : ''}>
        <div class="nav-sub-row">${caretHtml(key, open)}${title}</div>
        <div class="nav-sub-items">${navItemsHtml(item.children, key, activeKey, depth + 1)}</div>
      </div>`;
    }).join('');
  }

  function renderNav(activeKey) {
    if (!manifest) return;
    const html = manifest.sections.map((section) => {
      // 是否能折叠：只要有条目就能收起。
      // 早期只给「有子分组」的章节加箭头，结果「客户使用手册」「平台运维手册」
      // 这种平铺的章节收不起来 —— 而它们各有一二十条，收起恰恰最有用。
      const canCollapse = (section.items || []).length > 0;
      const open = !collapsedPaths.has(section.id);
      const inHere = (activeKey || '') === section.id || (activeKey || '').startsWith(section.id + '/');
      const items = navItemsHtml(section.items, section.id, activeKey, 1);
      // 分组标题下的说明：让读者一眼知道这组是给谁看的
      const desc = section.description
        ? `<div class="nav-group-desc">${escapeHtml(section.description)}</div>`
        : '';
      return `
        <div class="nav-group" data-path="${escapeHtml(section.id)}"
          ${canCollapse && !open ? 'data-collapsed="true"' : ''}${inHere ? ' data-active-parent="true"' : ''}>
          <div class="nav-group-row">
            ${canCollapse ? caretHtml(section.id, open) : '<span class="nav-caret-spacer"></span>'}
            <span class="nav-icon nav-icon-${section.icon || 'doc'}"></span>
            <span class="nav-group-title">${escapeHtml(section.title)}</span>
          </div>
          ${desc}
          <div class="nav-items">${items}</div>
        </div>`;
    }).join('');
    navEl.innerHTML = html;
  }

  /**
   * 折叠/展开只改 class 与属性，**不重渲染整个导航**。
   *
   * 重渲染会把 sidebar 的滚动位置和按钮焦点一起清零 ——
   * 用户点了第 20 项的箭头，界面一下跳回顶部，很难用。
   */
  function toggleGroup(group, btn) {
    const willOpen = group.getAttribute('data-collapsed') === 'true';
    if (willOpen) group.removeAttribute('data-collapsed');
    else group.setAttribute('data-collapsed', 'true');
    btn.classList.toggle('open', willOpen);
    btn.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
    btn.setAttribute('aria-label', willOpen ? '收起' : '展开');
    const path = group.getAttribute('data-path');
    if (!path) return;
    if (willOpen) collapsedPaths.delete(path);
    else collapsedPaths.add(path);
    navStateStored = true;   // 用户操作过 → 默认折叠策略不再覆盖
    saveNavState();
  }

  navEl.addEventListener('click', (e) => {
    // 箭头按钮：只管开合
    const btn = e.target.closest('.nav-caret-btn');
    if (btn) {
      e.preventDefault();
      e.stopPropagation();
      const group = btn.closest('[data-path]');
      if (group) toggleGroup(group, btn);
      return;
    }
    // 没有 file 的分组标题（纯文字）：整行点击也能开合，
    // 否则用户会很自然地戳文字，然后什么都没发生。
    const plain = e.target.closest('.nav-sub-title.is-plain');
    if (plain) {
      e.preventDefault();
      const group = plain.closest('[data-path]');
      const caret = group && group.querySelector(':scope > .nav-sub-row > .nav-caret-btn');
      if (group && caret) toggleGroup(group, caret);
      return;
    }
    // 章节标题（客户使用手册 / 平台运维手册 …）：整行可点，与平台菜单一致。
    // 只处理 .nav-group-row —— 它里面只有箭头/图标/文字，没有链接，
    // 点哪都是「展开收起」的意思。子分组的行不行：那里有链接，点链接要导航。
    const grow = e.target.closest('.nav-group-row');
    if (grow) {
      const group = grow.closest('[data-path]');
      const caret = group && group.querySelector(':scope > .nav-group-row > .nav-caret-btn');
      if (group && caret) toggleGroup(group, caret);
    }
  });

  // ---------------- 目录 ----------------

  function renderToc() {
    const headings = contentEl.querySelectorAll('h2, h3');
    if (headings.length < 2) {
      tocEl.innerHTML = '';
      tocEl.classList.add('empty');
      return;
    }
    tocEl.classList.remove('empty');
    const links = Array.from(headings).map((h) => {
      const level = h.tagName === 'H2' ? 'lvl2' : 'lvl3';
      return `<a class="toc-${level}" href="#${location.hash.split('#')[1] || ''}"
                data-anchor="${h.id}">${escapeHtml(h.textContent)}</a>`;
    }).join('');
    tocEl.innerHTML = `<div class="toc-title">本页目录</div>${links}`;

    tocEl.querySelectorAll('a[data-anchor]').forEach((a) => {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        const target = document.getElementById(a.dataset.anchor);
        if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });
  }

  function highlightToc() {
    const headings = Array.from(contentEl.querySelectorAll('h2, h3'));
    if (!headings.length) return;
    const offset = 96;
    let active = headings[0];
    for (const h of headings) {
      if (h.getBoundingClientRect().top <= offset) active = h;
      else break;
    }
    tocEl.querySelectorAll('a[data-anchor]').forEach((a) => {
      a.classList.toggle('active', a.dataset.anchor === active.id);
    });
  }

  // ---------------- 渲染 ----------------

  function renderMarkdown(md) {
    // marked 默认不生成 heading id，这里手动补上，锚点与目录都靠它
    const renderer = new marked.Renderer();
    const seen = Object.create(null);
    renderer.heading = function (text, level) {
      const raw = text.replace(/<[^>]+>/g, '');
      let id = slugify(raw);
      if (seen[id]) id = id + '-' + (++seen[id]);
      else seen[id] = 1;
      return `<h${level} id="${id}">${text}</h${level}>`;
    };

    marked.setOptions({
      renderer,
      gfm: true,
      breaks: false,
      mangle: false,
      headerIds: false,
    });

    let html = marked.parse(md);

    // 把 markdown 之间的相对链接改成 hash 路由。
    // 写法有两种：01-quick-start.md 或 ../admin/02-deploy.md，
    // 都归一到 manifest 里登记的 item 上；找不到就原样保留。
    html = html.replace(/href="([^"]+\.md)(#[^"]*)?"/g, (match, href, anchor) => {
      const target = resolveMarkdownLink(href);
      if (!target) return match;
      return `href="#/${target}${anchor || ''}"`;
    });

    // 站内短链：/admin/deploy、/user/quick-start、/menu-ops/tenant/... 这类写法
    // 也要走 hash 路由。/downloads/ 下是真实文件（脚本与 SQL），必须保持原样。
    //
    // 字符集与深度都要放宽：
    //   · item id 可以是 02b-cassandra（带点/数字）
    //   · 新增的「运维管理」菜单有多层，写成 /menu-ops/tenant/entities/devices/device_all
    //     早先只允许一段，那些链接会原样输出成 http://站点/menu-ops/... → 404。
    html = html.replace(/href="\/(admin|user|menu-ops)\/([a-zA-Z0-9._\/-]+)"/g,
      (match, section, rest) => `href="#/${section}/${rest.replace(/\/+$/, '')}"`);

    return html;
  }

  function resolveMarkdownLink(href) {
    if (!manifest) return null;
    const clean = href.replace(/^\.\//, '').replace(/^\.\.\//, '');
    const parts = clean.split('/');
    const file = parts[parts.length - 1];
    const dir = parts.length > 1 ? parts[parts.length - 2] : '';

    // 菜单可能有多层（children 嵌套），所以拍平成 [(path, item)] 再比 ——
    // 只遍历一层的话，三级页面的链接会全部落到「页面不存在」。
    const flat = [];
    const walk = (items, prefix) => {
      for (const it of items || []) {
        const path = prefix ? prefix + '/' + it.id : it.id;
        flat.push({ path, item: it });
        if (it.children) walk(it.children, path);
      }
    };
    for (const section of manifest.sections) walk(section.items, section.id);

    for (const e of flat) {
      const itemFile = (e.item.file || '').split('/').pop();
      if (itemFile !== file) continue;
      // 目录能对上就精确匹配，对不上（如 user/01-x.md 与 admin/01-x.md 同名）时退回首个
      if (!dir || e.item.file === dir + '/' + file) return e.path;
    }
    for (const e of flat) {
      if ((e.item.file || '').split('/').pop() === file) return e.path;
    }
    return null;
  }

  async function loadPage(sectionId, path) {
    const found = findItem(sectionId, path);
    if (!found) {
      const shown = Array.isArray(path) ? path.join('/') : path;
      contentEl.innerHTML = `
        <h1>页面不存在</h1>
        <p>没有找到 <code>${escapeHtml(sectionId)}/${escapeHtml(shown)}</code> 这一页。</p>
        <p><a href="#/user/quick-start">返回快速开始</a></p>`;
      tocEl.innerHTML = '';
      return;
    }

    const key = found.key;
    currentKey = key;
    // 首次渲染不展开任何分组（默认收缩，含当前页所在的组）——
    // 全收起已在 init 里应用，这里仅在**用户点击导航**后展开祖先：
    // 用户点了某个条目，总得让他看见它。
    const isFirstRender = !navVisited;
    navVisited = true;
    if (!isFirstRender) expandAncestors(key);
    renderNav(key);
    document.title = found.item.title + ' · ' + manifest.title;

    contentEl.innerHTML = '<div class="loading">正在加载…</div>';
    try {
      const res = await fetch(CONTENT_BASE + found.item.file, { cache: 'no-cache' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const md = await res.text();
      contentEl.innerHTML = renderMarkdown(md);
      renderToc();
      window.scrollTo(0, 0);
    } catch (err) {
      contentEl.innerHTML = `
        <h1>加载失败</h1>
        <p>无法读取 <code>${escapeHtml(found.item.file)}</code>（${escapeHtml(err.message)}）。</p>
        <p>若在本地打开，请用 HTTP 服务（如 <code>python3 -m http.server</code>）而不是 <code>file://</code>，
           后者会被浏览器的跨域策略拦住 fetch。</p>`;
      tocEl.innerHTML = '';
    }

    if (window.innerWidth <= 900) closeSidebar();
  }

  // ---------------- 启动 ----------------

  function closeSidebar() {
    document.body.classList.remove('menu-open');
  }

  function route() {
    // 页内锚点（形如 #某个标题）不是路由，不能走下方「找不到就跳默认页」的逻辑。
    // 之前所有 #xxx 都会被 resolveRoute 判为非法并跳回快速开始，
    // 于是手册里「跳到本节」这类链接一点就飞走。有对应元素时滚动过去即返回。
    if (location.hash && location.hash.indexOf('#/') !== 0) {
      const anchorId = decodeURIComponent(location.hash.slice(1));
      const el = anchorId && document.getElementById(anchorId);
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        return;
      }
    }
    const r = resolveRoute();
    if (!r) {
      // 默认落到快速开始
      location.replace('#/user/quick-start');
      return;
    }
    loadPage(r.sectionId, r.path);
  }

  async function init() {
    try {
      // 加时间戳：单纯 cache:'no-cache' 只约束浏览器，CDN 边缘仍可能返回旧副本，
      // 表现为「改了 manifest，侧边栏还是旧的」。manifest 仅 2KB，代价可忽略。
      const res = await fetch(CONTENT_BASE + 'manifest.json?v=' + Date.now(),
                              { cache: 'no-cache' });
      manifest = await res.json();
      versionEl.textContent = manifest.version || '';
      loadNavState();
      // 在这里就把默认的「全部收起」应用上：
      //   放到 loadPage 里做，首次会先渲染一次全展开再变收起 —— 肉眼能看到的闪动。
      collapseAllByDefault();
      if (manifest.sections.length) {
        // 首页默认展示第一组的第一页
        const first = manifest.sections[0];
        if (first.items.length && !resolveRoute()) {
          // 不跳转，交给 route() 的默认值处理
        }
      }
      renderNav('');
      route();
    } catch (err) {
      contentEl.innerHTML = `
        <h1>站点初始化失败</h1>
        <p>无法读取 <code>content/manifest.json</code>：${escapeHtml(err.message)}</p>
        <p>请确认用 HTTP 服务打开本页，而不是直接双击 <code>index.html</code>。</p>`;
    }
  }

  document.getElementById('menuToggle').addEventListener('click', () => {
    document.body.classList.toggle('menu-open');
  });

  document.addEventListener('click', (e) => {
    if (window.innerWidth > 900) return;
    if (sidebarEl.contains(e.target) || e.target.closest('.menu-toggle')) return;
    closeSidebar();
  });

  window.addEventListener('hashchange', route);
  window.addEventListener('scroll', highlightToc, { passive: true });

  init();
})();

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
    const [sectionId, itemId] = hash.split('/');
    return { sectionId, itemId };
  }

  function findItem(sectionId, itemId) {
    if (!manifest) return null;
    const section = manifest.sections.find((s) => s.id === sectionId);
    if (!section) return null;
    const item = section.items.find((i) => i.id === itemId);
    if (!item) return null;
    return { section, item };
  }

  // ---------------- 导航 ----------------

  function renderNav(activeKey) {
    if (!manifest) return;
    const html = manifest.sections.map((section) => {
      const items = section.items.map((item) => {
        const key = section.id + '/' + item.id;
        const active = key === activeKey ? ' class="active"' : '';
        return `<a href="#/${key}"${active}>${escapeHtml(item.title)}</a>`;
      }).join('');
      // 分组标题下的说明：让读者一眼知道这组是给谁看的
      const desc = section.description
        ? `<div class="nav-group-desc">${escapeHtml(section.description)}</div>`
        : '';
      return `
        <div class="nav-group">
          <div class="nav-group-title">
            <span class="nav-icon nav-icon-${section.icon || 'doc'}"></span>
            <span>${escapeHtml(section.title)}</span>
          </div>
          ${desc}
          <div class="nav-items">${items}</div>
        </div>`;
    }).join('');
    navEl.innerHTML = html;
  }

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

    // 站内短链：/admin/deploy、/user/quick-start 这类写法也要走 hash 路由。
    // /downloads/ 下是真实文件（脚本与 SQL），必须保持原样。
    html = html.replace(/href="\/(admin|user)\/([a-z0-9-]+)"/g,
      (match, section, item) => `href="#/${section}/${item}"`);

    return html;
  }

  function resolveMarkdownLink(href) {
    if (!manifest) return null;
    const clean = href.replace(/^\.\//, '').replace(/^\.\.\//, '');
    const parts = clean.split('/');
    const file = parts[parts.length - 1];
    const dir = parts.length > 1 ? parts[parts.length - 2] : '';
    for (const section of manifest.sections) {
      for (const item of section.items) {
        const itemFile = item.file.split('/').pop();
        if (itemFile !== file) continue;
        // 目录能对上就精确匹配，对不上（如 user/01-x.md 与 admin/01-x.md 同名）时退回首个
        if (!dir || item.file === dir + '/' + file) return section.id + '/' + item.id;
      }
    }
    for (const section of manifest.sections) {
      for (const item of section.items) {
        if (item.file.split('/').pop() === file) return section.id + '/' + item.id;
      }
    }
    return null;
  }

  async function loadPage(sectionId, itemId) {
    const found = findItem(sectionId, itemId);
    if (!found) {
      contentEl.innerHTML = `
        <h1>页面不存在</h1>
        <p>没有找到 <code>${escapeHtml(sectionId)}/${escapeHtml(itemId)}</code> 这一页。</p>
        <p><a href="#/user/quick-start">返回快速开始</a></p>`;
      tocEl.innerHTML = '';
      return;
    }

    const key = sectionId + '/' + itemId;
    currentKey = key;
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
    const r = resolveRoute();
    if (!r) {
      // 默认落到快速开始
      location.replace('#/user/quick-start');
      return;
    }
    loadPage(r.sectionId, r.itemId);
  }

  async function init() {
    try {
      const res = await fetch(CONTENT_BASE + 'manifest.json', { cache: 'no-cache' });
      manifest = await res.json();
      versionEl.textContent = manifest.version || '';
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

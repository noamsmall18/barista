// Marketbar site: the menu bar clock, the session the market is in right now,
// the session tabs, the charts and the feature previews. All figures are
// sample data and add up (see the totals in the dropdown).
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- Seeded noise so charts look the same on every visit ----------
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);

  // ---------- Clock in the menu bar ----------
  const clock = $('#mbClock');
  const fmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
  const tick = () => { const d = new Date(); clock.textContent = fmt.format(d); clock.dateTime = d.toISOString(); };
  tick(); setInterval(tick, 15000);

  // ---------- Which session is New York in right now? ----------
  function sessionNow() {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/New_York', weekday: 'short', hour: 'numeric', minute: 'numeric', hourCycle: 'h23'
    }).formatToParts(new Date()).map(x => [x.type, x.value]));
    const m = (+p.hour % 24) * 60 + +p.minute, day = p.weekday;
    if (day === 'Sat') return null;
    if (day === 'Sun') return m >= 1200 ? 'on' : null; // overnight opens Sunday 8 PM
    if (m < 240) return 'on';
    if (m < 570) return 'pre';
    if (m < 960) return 'reg';
    if (m < 1200) return 'ah';
    return day === 'Fri' ? null : 'on'; // no overnight session on Friday night
  }

  // ---------- The four sessions, for NVDA in the sample portfolio ----------
  const S = {
    reg: { bar: ['181.20', '▲1.40%'], tag: false, ext: null, now: 6.5, time: '3:59 PM ET', base: 178.70,
      desc: "From 9:30 to 4 the menu bar and the dropdown agree: NVDA is up 1.40% on yesterday's close, refreshed every 5 seconds.",
      cap: 'A sample portfolio, shown the way Marketbar shows it right now: regular trading in New York.' },
    ah: { bar: ['182.95', '▲2.38%'], tag: false, ext: ['After hours', '182.95', '+0.97%'], now: 10, time: '7:30 PM ET', base: 178.70,
      desc: 'After 4 the menu bar follows the live price, up 2.38% on the day. The dropdown still says NVDA closed up 1.40%, with the after-hours 0.97% on its own line.',
      cap: 'A sample portfolio, shown the way Marketbar shows it right now: after hours in New York.' },
    on: { bar: ['182.10', '▲0.50%'], tag: true, ext: ['Overnight', '182.10', '+0.50%'], now: 15.5, time: '1:00 AM ET', base: 181.20,
      desc: "From 8 PM to 4 AM, Robinhood's 24/5 quotes keep the menu bar moving, marked ON, instead of freezing on the 4 PM close.",
      cap: 'A sample portfolio, shown the way Marketbar shows it right now: the overnight session.' },
    pre: { bar: ['183.40', '▲1.21%'], tag: false, ext: ['Pre-market', '183.40', '+1.21%'], now: 22.75, time: '8:15 AM ET', base: 181.20,
      desc: "Before the open, the day's gain starts from the last close, so yesterday's 1.40% is never counted twice.",
      cap: 'A sample portfolio, shown the way Marketbar shows it right now: pre-market in New York.' }
  };

  // ---------- The trading-day chart on the plate ----------
  // x runs from 9:30 AM (0 h) to 9:30 AM the next day (24 h).
  const W = 480, TOP = 40, BOT = 236, LO = 177.6, HI = 184.2;
  const X = h => (h / 24) * W, Y = v => BOT - ((v - LO) / (HI - LO)) * (BOT - TOP);
  const anchors = [[0, 179.4], [1, 180.6], [2, 179.9], [3.2, 180.9], [4.5, 180.2], [5.6, 181.6], [6.5, 181.2],
    [7.2, 181.9], [8.5, 182.6], [10, 182.95], [10.5, 182.9], [12, 182.5], [14, 182.3], [15.5, 182.1], [18.5, 182.4],
    [20, 182.9], [21.5, 183.1], [22.75, 183.4], [24, 183.3]];
  const pts = [];
  for (let i = 0; i < anchors.length - 1; i++) {
    const [h0, v0] = anchors[i], [h1, v1] = anchors[i + 1], n = Math.max(2, Math.round((h1 - h0) * 5));
    for (let k = 0; k < n; k++) {
      const f = k / n, wig = k === 0 ? 0 : (rnd() - 0.5) * 0.32;
      pts.push([h0 + (h1 - h0) * f, v0 + (v1 - v0) * f + wig]);
    }
  }
  pts.push(anchors[anchors.length - 1]);
  const valueAt = h => { let best = anchors[0][1]; for (const [a, v] of anchors) if (a <= h) best = v; return best; };
  const path = arr => arr.map(([h, v], i) => (i ? 'L' : 'M') + X(h).toFixed(1) + ' ' + Y(v).toFixed(1)).join('');

  const bands = [['reg', 0, 6.5, 'Regular'], ['ah', 6.5, 10.5, 'After'], ['on', 10.5, 18.5, 'Overnight'], ['pre', 18.5, 24, 'Pre']];
  const NS = 'http://www.w3.org/2000/svg';
  const bandG = $('#bands'), labelG = $('#bandLabels');
  for (const [id, a, b, label] of bands) {
    const r = document.createElementNS(NS, 'rect');
    Object.entries({ x: X(a) + 1, y: 0, width: X(b) - X(a) - 2, height: 262, rx: 6, class: 'band', 'data-b': id }).forEach(([k, v]) => r.setAttribute(k, v));
    bandG.append(r);
    const t = document.createElementNS(NS, 'text');
    Object.entries({ x: X(a) + 8, y: 286, class: 'band-label', 'data-b': id }).forEach(([k, v]) => t.setAttribute(k, v));
    t.textContent = label; labelG.append(t);
  }

  function drawDay(s) {
    const st = S[s], now = st.now;
    const solid = pts.filter(([h]) => h <= Math.min(now, 6.5));
    const ext = now > 6.5 ? pts.filter(([h]) => h >= 6.5 && h <= now) : [];
    $('#dayLine').setAttribute('d', path(solid));
    $('#dayExt').setAttribute('d', ext.length ? path([[6.5, valueAt(6.5)], ...ext, [now, valueAt(now)]]) : '');
    const dot = $('#nowDot'); dot.setAttribute('cx', X(now)); dot.setAttribute('cy', Y(valueAt(now)));
    const base = $('#baseLine'); base.setAttribute('y1', Y(st.base)); base.setAttribute('y2', Y(st.base));
    $$('[data-b]').forEach(el => el.classList.toggle('on', el.dataset.b === s));
  }

  // ---------- Apply a session everywhere it shows ----------
  const tabs = $$('.tabs [role=tab]');
  function setSession(s, opts = {}) {
    const st = S[s];
    $('#mbPrice').textContent = st.bar[0]; $('#mbChg').textContent = st.bar[1]; $('#mbTag').hidden = !st.tag;
    $('#platePrice').textContent = st.bar[0]; $('#plateChg').textContent = st.bar[1]; $('#plateTag').hidden = !st.tag;
    $('#plateTime').textContent = st.time;
    const ext = $('#nvdaExt'), pe = $('#plateExt');
    if (st.ext) {
      ext.hidden = false; ext.innerHTML = `<span>${st.ext[0]}</span><span><b>${st.ext[1]}</b> <span class="up">${st.ext[2]}</span></span>`;
      pe.hidden = false; $('#plateExtName').textContent = st.ext[0]; $('#plateExtPrice').textContent = st.ext[1]; $('#plateExtChg').textContent = st.ext[2];
    } else { ext.hidden = true; pe.hidden = true; }
    const desc = $('#sessionDesc'); desc.textContent = st.desc;
    tabs.forEach(t => { const on = t.dataset.s === s; t.setAttribute('aria-selected', on); t.tabIndex = on ? 0 : -1; if (on) desc.setAttribute('aria-labelledby', t.id); });
    if (opts.caption) $('#heroCaption').textContent = opts.caption;
    drawDay(s);
  }

  tabs.forEach((t, i) => {
    t.addEventListener('click', () => setSession(t.dataset.s));
    t.addEventListener('keydown', e => {
      const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!d) return;
      const next = tabs[(i + d + tabs.length) % tabs.length]; next.focus(); setSession(next.dataset.s); e.preventDefault();
    });
  });

  const live = sessionNow();
  setSession(live || 'reg', { caption: live ? S[live].cap : "Markets are closed, so this sample portfolio shows the last session's close." });

  // ---------- Small charts ----------
  function walk(n, drift, vol) { const a = [0]; for (let i = 1; i < n; i++) a.push(a[i - 1] + drift + (rnd() - 0.5) * vol); return a; }
  function line(vals, w, h, pad = 6) {
    const lo = Math.min(...vals), hi = Math.max(...vals), sx = (w - pad * 2) / (vals.length - 1);
    return vals.map((v, i) => (i ? 'L' : 'M') + (pad + i * sx).toFixed(1) + ' ' + (h - pad - ((v - lo) / (hi - lo || 1)) * (h - pad * 2)).toFixed(1)).join('');
  }
  seed = 21;
  const m = walk(44, 0.35, 2.4), heroD = line(m, 400, 120, 4);
  $('#heroLine').setAttribute('d', heroD);
  $('#heroArea').setAttribute('d', heroD + 'L396 120L4 120Z');
  $$('[data-spark]').forEach(p => {
    const pct = +p.dataset.spark; const v = walk(18, pct / 6, 0.9);
    p.setAttribute('d', line(v, 80, 24, 2)); p.style.stroke = pct >= 0 ? 'var(--accent)' : 'var(--down)';
  });
  seed = 5;
  const g = walk(60, 0.16, 1.1), spy = walk(60, 0.07, 0.7);
  const lo = Math.min(...g, ...spy), hi = Math.max(...g, ...spy);
  const scaled = (vals) => vals.map((v, i) => (i ? 'L' : 'M') + (8 + i * (344 / 59)).toFixed(1) + ' ' + (162 - ((v - lo) / (hi - lo)) * 150).toFixed(1)).join('');
  $('#histLine').setAttribute('d', scaled(g)); $('#histSpy').setAttribute('d', scaled(spy));

  if (!reduce) {
    for (const el of [$('#heroLine')]) { const len = el.getTotalLength(); el.style.setProperty('--len', len); el.classList.add('draw'); }
  }

  // ---------- Features: point at a line to see it in the app ----------
  const items = $$('.item'), sheet = $('.sheet'), preview = $('.preview'), narrow = matchMedia('(max-width: 900px)');
  function show(item) {
    items.forEach(i => i.classList.toggle('on', i === item));
    $$('.pv').forEach(p => p.classList.toggle('on', p.dataset.pv === item.dataset.p));
    if (narrow.matches) {
      const li = item.closest('li');
      if (preview.parentElement !== li) li.after(preview);
      preview.classList.add('inline');
    }
  }
  items.forEach(i => {
    i.addEventListener('mouseenter', () => { if (!narrow.matches) { sheet.classList.add('pointing'); show(i); } });
    i.addEventListener('focus', () => { if (!narrow.matches) show(i); });
    i.addEventListener('click', () => show(i));
  });
  sheet.addEventListener('mouseleave', () => sheet.classList.remove('pointing'));
  items[0].classList.add('on');
  if (narrow.matches) show(items[0]);
  narrow.addEventListener('change', () => {
    if (!narrow.matches) { $('.features').append(preview); preview.classList.remove('inline'); }
  });

  // ---------- FAQ: one card open at a time ----------
  const cards = $$('.card');
  cards.forEach(c => c.addEventListener('toggle', () => { if (c.open) cards.forEach(o => { if (o !== c) o.open = false; }); }));

  // ---------- Entrances: heading, then text, then picture ----------
  const groups = [
    ['.hero', ['h1', '.lede', '.actions', '.meta']],
    ['.sessions', ['.plate', '.tabs', '.sessions-text h2', '.session-desc', '.cells']],
    ['.features', ['.sheet', '.sheet h2', '.group', '.preview']],
    ['.install', ['.install-copy h2', '.install-copy p', '.install-copy pre', '.slip']],
    ['.faq', ['h2', '.card']],
    ['.get', ['h2', 'p', '.ticker']],
    ['.foot', ['.foot-cols > div', '.wordmark']]
  ];
  if (reduce || !('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
  }), { rootMargin: '0px 0px -8% 0px' });
  for (const [root, sels] of groups) {
    const r = $(root); if (!r) continue;
    let i = 0;
    for (const s of sels) for (const el of $$(s, r)) { el.dataset.in = ''; el.style.setProperty('--d', (i++ % 8) * 80 + 'ms'); io.observe(el); }
  }
})();

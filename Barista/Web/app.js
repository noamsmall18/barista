'use strict';
const $ = id => document.getElementById(id);
const A = WorkspaceAnalytics;
const valid = A.finite;
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money = (n, currency = 'USD') => valid(n) ? new Intl.NumberFormat('en-US', {style:'currency', currency:/^[A-Z]{3}$/.test(currency) ? currency : 'USD', maximumFractionDigits:2}).format(n) : '—';
const num = n => valid(n) ? new Intl.NumberFormat('en-US', {maximumFractionDigits:4}).format(n) : '—';
const compact = n => valid(n) ? new Intl.NumberFormat('en-US', {notation:'compact', maximumFractionDigits:2}).format(n) : '—';
const pct = n => valid(n) ? `${n > 0 ? '+' : ''}${n.toFixed(2)}%` : '—';
const signed = (n, currency = 'USD') => valid(n) ? `${n > 0 ? '+' : ''}${money(n, currency)}` : '—';
const tone = n => valid(n) ? n > 0 ? 'up' : n < 0 ? 'down' : 'neutral' : '';
const stamp = t => valid(t) ? new Date(t * 1000).toLocaleString([], {month:'short', day:'numeric', hour:'numeric', minute:'2-digit'}) : 'Unavailable';
const empty = text => `<div class="empty">${esc(text)}</div>`;
const pending = text => `<div class="empty loading-state">${esc(text)}</div>`;
const stat = (label, value, detail = '') => `<div class="stat"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div>${detail ? `<div class="detail">${esc(detail)}</div>` : ''}</div>`;
const metric = (label, value, detail, cls = '') => `<article class="metric"><div class="label">${esc(label)}</div><div class="value ${cls}">${esc(value)}</div><div class="detail">${esc(detail)}</div></article>`;
function external(url, label) {
  try { if (new URL(url).protocol !== 'https:') return esc(label); } catch { return esc(label); }
  return `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(label)} ↗</a>`;
}
const colors = ['#e6c895','#8fb9f4','#7cddba','#c7a0ee','#eea783','#8dcbd7','#9caec4'];
let newsData;
let researchSymbols=[];
const studyQuotes=new Map();
const researchQuotes=()=>[...(state?.quotes||[]),...[...studyQuotes.values()].filter(q=>!state?.quotes.some(p=>p.symbol===q.symbol))];
let state, selected, portfolioRange = '1D', financialPeriod = 'annual', financialData, expectationsData, securityChartData;
let lastFingerprint, loading = false, graphID = 0, lastChartAt = 0, lastResearchAt = 0;
let researchGeneration = 0, researchController, chartGeneration = 0, chartController, comparisonGeneration = 0, comparisonController;
let tableFilter = 'all', tableSort = 'value', tableDirection = 'desc', favorites = [], compareSymbols = [], commandIndex = 0;
let workspaceReady = false, workspace = {notes:{}, preferences:{}}, preferenceTimer, noteTimer, savingNotes = false;
const dirtyNotes = new Map();
const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
const scrollTo = id => { if(window.ResearchDesk)window.ResearchDesk.reveal(id);else $(id).scrollIntoView({behavior:reducedMotion() ? 'auto' : 'smooth', block:'start'}); };
function toast(message) { $('toast').textContent = message; $('toast').hidden = false; clearTimeout(toast.timer); toast.timer = setTimeout(() => { $('toast').hidden = true; }, 3500); }

async function api(path, signal, body) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (signal?.aborted) controller.abort();
  signal?.addEventListener('abort', abort, {once:true});
  const timeout = setTimeout(abort, 25000);
  try {
    const response = await fetch(path, {cache:'no-store', signal:controller.signal, credentials:'omit',
      ...(body ? {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)} : {})});
    if (!response.ok) throw new Error(response.status === 403 ? 'This app session ended. Reopen research from the menu bar.' : `App connection returned ${response.status}`);
    return await response.json();
  } finally { clearTimeout(timeout); signal?.removeEventListener('abort', abort); }
}

// One SVG renderer for price, portfolio and rebased comparison series.
function graph(points, comparison = [], mini = false, ordinal = false, currency = 'USD', percent = false, overlays = [], primaryName = 'Value') {
  const clean = A.points(points);
  if (clean.length < 2) return mini ? '' : empty('A little more history is needed. This chart fills in as prices arrive.');
  const width = mini ? 90 : 720, height = mini ? 28 : 260, top = mini ? 3 : 24, bottom = mini ? 3 : 28, left = mini ? 0 : 3, right = mini ? 0 : 64;
  const compare = A.points(comparison).filter(p => p[0] >= clean[0][0] && p[0] <= clean.at(-1)[0]);
  const extra = overlays.map(s => ({...s, points:A.points(s.points)}));
  const allPoints = [...clean, ...compare, ...extra.flatMap(s => s.points)];
  const times = allPoints.map(p => p[0]), firstTime = Math.min(...times), lastTime = Math.max(...times);
  const values = allPoints.map(p => p[1]), low = Math.min(...values), high = Math.max(...values);
  const padding = (high - low || Math.max(Math.abs(high) * .01, 1)) * .12, min = low - padding, max = high + padding;
  const x = t => left + (t - firstTime) / (lastTime - firstTime || 1) * (width - left - right);
  const y = v => top + (max - v) / (max - min) * (height - top - bottom);
  const line = series => series.map((p, i) => `${i ? 'L' : 'M'}${x(p[0]).toFixed(2)},${y(p[1]).toFixed(2)}`).join(' ');
  const grid = mini ? '' : Array.from({length:4}, (_, i) => {
    const v = max - i * (max - min) / 3, py = y(v);
    return `<line class="grid-line" x1="0" y1="${py}" x2="${width-right+8}" y2="${py}"/><text x="${width-right+14}" y="${py+4}">${esc(percent ? v.toFixed(1)+'%' : compact(v))}</text>`;
  }).join('');
  const sameDay = new Date(firstTime * 1000).toDateString() === new Date(lastTime * 1000).toDateString();
  const label = t => new Date(t * 1000).toLocaleString([], sameDay ? {hour:'numeric', minute:'2-digit'} : {month:'short', day:'numeric'});
  const labels = mini ? '' : `<text x="0" y="${height-2}">${esc(ordinal ? 'Earlier' : label(firstTime))}</text><text text-anchor="end" x="${width-right}" y="${height-2}">${esc(ordinal ? 'Latest' : label(lastTime))}</text>`;
  const id = `chart-fill-${++graphID}`;
  const area = mini || extra.length ? '' : `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#e6c895" stop-opacity=".18"/><stop offset="100%" stop-color="#e6c895" stop-opacity="0"/></linearGradient></defs><path d="${line(clean)} L${x(clean.at(-1)[0])},${height-bottom} L${x(clean[0][0])},${height-bottom} Z" fill="url(#${id})"/>`;
  const series = [{name:primaryName, points:clean}, ...(compare.length ? [{name:'SPY', points:compare}] : []), ...extra];
  const interaction = mini ? '' : ` tabindex="0" data-points="${esc(JSON.stringify(clean))}" data-series="${esc(JSON.stringify(series))}" data-first="${firstTime}" data-last="${lastTime}" data-min="${min}" data-max="${max}" data-ordinal="${ordinal}" data-currency="${esc(currency)}" data-percent="${percent}"`;
  return `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="${esc(`Value from ${num(clean[0][1])} to ${num(clean.at(-1)[1])}${percent?' percent':''}. ${mini?'':'Use left and right arrow keys to inspect observations.'}`)}"${interaction}>${grid}${area}${compare.length > 1 ? `<path class="benchmark-line" d="${line(compare)}"/>` : ''}<path class="line ${mini ? tone(clean.at(-1)[1]-clean[0][1]) : ''}" d="${line(clean)}"/>${extra.map(s => `<path fill="none" stroke="${s.color}" stroke-width="2" vector-effect="non-scaling-stroke" d="${line(s.points)}"/>`).join('')}${labels}</svg>`;
}
function inspectChart(svg, index) {
  const points = JSON.parse(svg.dataset.points);
  index = Math.max(0, Math.min(points.length - 1, index)); svg.dataset.index = index;
  const p = points[index], x = 3 + (p[0]-Number(svg.dataset.first)) / (Number(svg.dataset.last)-Number(svg.dataset.first)||1) * 653;
  const y = 24 + (Number(svg.dataset.max)-p[1]) / (Number(svg.dataset.max)-Number(svg.dataset.min)) * 208;
  let guide = svg.querySelector('.chart-guide'), dot = svg.querySelector('.chart-dot');
  if (!guide) {
    guide = document.createElementNS('http://www.w3.org/2000/svg', 'line'); guide.setAttribute('class','chart-guide'); svg.append(guide);
    dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle'); dot.setAttribute('class','chart-dot'); dot.setAttribute('r','4'); svg.append(dot);
  }
  for (const [k,v] of Object.entries({x1:x,x2:x,y1:18,y2:232})) guide.setAttribute(k,v);
  dot.setAttribute('cx',x); dot.setAttribute('cy',y);
  let output = svg.parentElement.querySelector('.chart-inspector');
  if (!output) { output = document.createElement('output'); output.className = 'chart-inspector'; output.setAttribute('aria-live','polite'); svg.parentElement.append(output); }
  const formatter = v => svg.dataset.percent === 'true' ? pct(v) : money(v, svg.dataset.currency);
  const details = JSON.parse(svg.dataset.series).map(s => {
    // Do not invent observations in a series that has not started or has ended.
    if (!s.points.length || p[0] < s.points[0][0] || p[0] > s.points.at(-1)[0]) return `${s.name}: unavailable`;
    const nearest = s.points.reduce((best, next) => Math.abs(next[0]-p[0]) < Math.abs(best[0]-p[0]) ? next : best);
    return `${s.name}: ${formatter(nearest[1])}${nearest[0] !== p[0] ? ' (nearest observation)' : ''}`;
  });
  output.textContent = `${svg.dataset.ordinal === 'true' ? `Observation ${index+1}` : stamp(p[0])}\n${details.join(' · ')}`;
}
function mountChart(id, html) {
  const container = $(id), old = container.querySelector('svg[data-points]');
  const focused = old && document.activeElement === old;
  const oldPoints = old?.dataset.index !== undefined ? JSON.parse(old.dataset.points) : [];
  const time = oldPoints[Number(old?.dataset.index)]?.[0];
  container.innerHTML = html;
  const svg = container.querySelector('svg[data-points]');
  if (svg && time !== undefined) {
    const p = JSON.parse(svg.dataset.points); let index = 0;
    for (let i=1;i<p.length;i++) if (Math.abs(p[i][0]-time)<Math.abs(p[index][0]-time)) index=i;
    inspectChart(svg,index);
  }
  if (focused && svg) svg.focus({preventScroll:true});
}
function chartStats(points, currency = 'USD', prefix = '') {
  const p = A.points(points); if (p.length < 2) return '';
  const first = p[0][1], last = p.at(-1)[1];
  return `<span>${esc(prefix)}Change <strong class="${tone(last-first)}">${signed(last-first,currency)} · ${first>0?pct((last/first-1)*100):'—'}</strong></span><span>Low <strong>${money(Math.min(...p.map(p=>p[1])),currency)}</strong></span><span>High <strong>${money(Math.max(...p.map(p=>p[1])),currency)}</strong></span><span>Observations <strong>${p.length}</strong></span>`;
}
function chooseSegment(id, value, key) {
  for (const button of $(id).querySelectorAll('button')) {
    const on = button.dataset[key] === value; button.classList.toggle('selected',on); button.setAttribute('aria-pressed',String(on));
  }
}

function render() {
  const s = state.summary;
  $('workspace-date').textContent = new Date().toLocaleDateString([], {weekday:'short',month:'short',day:'numeric',year:'numeric'});
  $('brand').textContent = state.app; $('portfolio-name').textContent = state.portfolioName;
  document.title = `${state.portfolioName} · ${state.app} Research`;
  $('portfolio-note').textContent = `${s.positions} priced positions · ${state.portfolios.length} portfolio${state.portfolios.length===1?'':'s'} · ${state.combinedPortfolio?'Automatically combined from all portfolios · ':''}${state.standalone?'Independent research service · app can be closed.':'Following your active portfolio in the menu bar.'}`;
  $('summary').innerHTML = metric('Live portfolio value',money(s.liveTotal),s.currencyComparable ? `Cash ${money(s.cash)} · Includes available extended hours` : 'Mixed quote currencies · total withheld') +
    metric('Regular-session move',signed(s.dayPL),pct(s.dayPercent),tone(s.dayPL)) +
    metric('Unrealized gain / loss',signed(s.unrealizedPL),`${pct(s.unrealizedPercent)} · ${s.missingCostCount ? `${s.missingCostCount} positions without cost basis` : 'On positions with cost basis'}`,tone(s.unrealizedPL)) +
    metric(valid(s.extendedPL)?s.extendedLabel:'Realized gain / loss',signed(s.currencyComparable?(valid(s.extendedPL)?s.extendedPL:s.realizedPL):null),valid(s.extendedPL)?'Since regular close · separate from session P/L':'From recorded sales in your ledger',tone(valid(s.extendedPL)?s.extendedPL:s.realizedPL));
  $('indices').innerHTML = state.indices.map(q => `<div class="index-tile"><b>${esc(q.symbol)}</b><span class="index-price">${money(q.price,q.currency)}</span><span class="${tone(q.change)}">${pct(q.change)}</span><span class="mini-chart">${graph((q.sparkline||[]).map((v,i)=>[i,v]),[],true)}</span></div>`).join('');
  renderBriefing(); renderExposure(); renderHoldings(); renderPortfolioChart(); renderEarnings(); renderTrades();
  const available = new Set(researchQuotes().map(q=>q.symbol));
  const remaining = compareSymbols.filter(symbol=>available.has(symbol));
  if (remaining.length !== compareSymbols.length) { compareSymbols=remaining; renderComparison(); }
  if (!available.has(selected)) {
    const held = state.quotes.filter(q=>q.quantity>0).sort((a,b)=>(b.value||0)-(a.value||0));
    selectSecurity(held[0]?.symbol || state.quotes[0]?.symbol, false);
  } else renderSecurity();
  renderPinned(); window.ResearchDesk?.render();
}
function renderBriefing() {
  const held = state.quotes.filter(q=>q.quantity>0), s=state.summary;
  const comparable = s.currencyComparable;
  const priced = held.filter(q=>valid(q.value));
  const best = [...held].filter(q=>valid(q.dayPL)&&q.dayPL>0).sort((a,b)=>b.dayPL-a.dayPL)[0];
  const worst = [...held].filter(q=>valid(q.dayPL)&&q.dayPL<0).sort((a,b)=>a.dayPL-b.dayPL)[0];
  const next = held.filter(q=>q.earnings && q.earnings.date>=Date.now()/1000-86400).sort((a,b)=>a.earnings.date-b.earnings.date)[0];
  const item = (icon,title,text) => `<div class="brief-item"><span class="brief-icon">${icon}</span><div><strong>${esc(title)}</strong><p>${esc(text)}</p></div></div>`;
  $('briefing').innerHTML = (comparable && best ? item('↗',`${best.symbol} leads the session`,`${signed(best.dayPL)} contributed by this position.`) : item('↗','Session drivers',comparable?'No positive position contribution recorded.':'Dollar contribution ranks require comparable currencies.')) +
    (comparable && worst ? item('↘',`${worst.symbol} is the main detractor`,`${signed(worst.dayPL)} contributed by this position.`) : item('◈','Portfolio breadth',`${s.winners} positions up · ${s.losers} down.`)) +
    (next ? item('◷',`${next.symbol} earnings ahead`,`${stamp(next.earnings.date)} · ${next.earnings.session || 'Session unspecified'}`) : item('◷','Catalyst coverage','No upcoming held-position dates returned. Check the earnings radar for watchlist events.'));
  const missing = state.missingSymbols.length, total = priced.length+missing;
  $('coverage').innerHTML = `<div class="coverage-line"><strong>${priced.length} / ${total} holdings priced</strong><span>${missing?'Partial coverage':'Available coverage'}</span></div><div class="coverage-bar"><svg viewBox="0 0 100 5" preserveAspectRatio="none"><rect width="${total?priced.length/total*100:0}" height="5" rx="2.5" fill="#7cddba"/></svg></div><p>${esc(missing ? 'Unpriced: '+state.missingSymbols.join(', ') : 'Missing prices and cost basis remain explicit.')}</p>`;
  $('insights').innerHTML = comparable ? `<p>Cash is <strong>${s.liveTotal>0?(s.cash/s.liveTotal*100).toFixed(1):'0.0'}%</strong> of the priced portfolio. ${s.missingCostCount||0} held positions lack cost basis.</p>` : '<p>Cash, allocation, and totals are withheld because quote currencies differ.</p>';
}
function renderExposure() {
  const exposure = A.exposure(state);
  if (!exposure) {
    $('allocation').innerHTML = empty(state.summary.currencyComparable?(state.summary.liveTotal===0?'Net value is zero; exposure percentages are unavailable.':'Add holdings to see your allocation.'):'Allocation unavailable across different quote currencies.');
    if(state.summary.cash<0)$('allocation').innerHTML+=`<div class="allocation-row"><span>Cash shortfall</span><span class="down">${money(state.summary.cash)}</span></div>`;
    $('allocation-donut').innerHTML=''; $('concentration').innerHTML='';
  } else {
    const rows = exposure.held.slice(0,6), others=exposure.held.slice(6).reduce((sum,q)=>sum+q.weight,0);
    const slices = [...rows, ...(others!==0?[{symbol:'Other holdings',weight:others}]:[]), ...(state.summary.cash>0?[{symbol:'Cash',weight:exposure.cashWeight}]:[])];
    const grossWeight=slices.reduce((sum,q)=>sum+Math.abs(q.weight),0);
    let offset=0;
    const arcs=slices.map((q,i)=>{const len=(grossWeight?Math.abs(q.weight)/grossWeight:0)*301.59, segment=`<circle cx="58" cy="58" r="48" fill="none" stroke="${q.symbol==='Cash'?'#394b5e':colors[i%colors.length]}" stroke-width="10" stroke-dasharray="${len} ${301.59-len}" stroke-dashoffset="${-offset}"/>`;offset+=len;return segment;}).join('');
    $('allocation-donut').innerHTML=`<div class="donut"><svg viewBox="0 0 116 116" role="img" aria-label="Asset distribution; cash shortfall is shown separately."><circle cx="58" cy="58" r="48" fill="none" stroke="#25313d" stroke-width="10"/>${arcs}</svg><div class="donut-label"><b>${exposure.held.length}</b><span>priced positions</span></div></div>`;
    $('allocation').innerHTML=slices.map((q,i)=>`<div class="allocation-row"><svg class="swatch" viewBox="0 0 8 8" aria-hidden="true"><rect width="8" height="8" rx="2" fill="${q.symbol==='Cash'?'#394b5e':colors[i%colors.length]}"/></svg>${state.quotes.some(s=>s.symbol===q.symbol)?`<button data-open-symbol="${esc(q.symbol)}">${esc(q.symbol)}</button>`:`<span>${esc(q.symbol)}</span>`}<span>${q.weight.toFixed(1)}%</span></div>`).join('');
    if(state.summary.cash<0)$('allocation').innerHTML+=`<div class="allocation-row"><span>Cash shortfall</span><span class="down">${money(state.summary.cash)}</span></div>`;
    $('concentration').innerHTML=stat('Largest position',exposure.held[0]?exposure.held[0].weight.toFixed(1)+'%':'—',exposure.held[0]?.symbol||'No held positions')+stat('Top 3 concentration',exposure.topThree.toFixed(1)+'%','Of priced portfolio + cash')+stat('Effective positions',exposure.effectivePositions.toFixed(1),'Inverse holding concentration; excludes cash');
  }
  const contributors=state.quotes.filter(q=>q.quantity>0&&valid(q.dayPL)).sort((a,b)=>Math.abs(b.dayPL)-Math.abs(a.dayPL)).slice(0,7);
  const largest=Math.max(1,...contributors.map(q=>Math.abs(q.dayPL)));
  $('contributors').innerHTML=!state.summary.currencyComparable?empty('Dollar contributions cannot be compared across different quote currencies.'):contributors.map(q=>{const width=Math.abs(q.dayPL)/largest*49;return `<div class="contributor"><button data-open-symbol="${esc(q.symbol)}">${esc(q.symbol)}</button><svg viewBox="0 0 100 14" preserveAspectRatio="none" aria-label="${esc(signed(q.dayPL))}"><line x1="50" x2="50" y1="0" y2="14" stroke="#526478"/><rect x="${q.dayPL<0?50-width:50}" y="3" width="${width}" height="8" rx="2" fill="${q.dayPL<0?'#f28f9d':'#7cddba'}"/></svg><span class="${tone(q.dayPL)}">${signed(q.dayPL)}</span></div>`;}).join('')||empty('Add held positions to see session contributions.');
  const current=$('scenario-symbol').value||'all';
  $('scenario-symbol').innerHTML='<option value="all">All priced holdings</option>'+state.quotes.filter(q=>q.quantity>0).map(q=>`<option value="${esc(q.symbol)}">${esc(q.symbol)}</option>`).join('');
  $('scenario-symbol').value=current==='all'||state.quotes.some(q=>q.symbol===current&&q.quantity>0)?current:'all';
  renderScenario();
}
function renderScenario() {
  if(!state)return;
  const shock=Number($('scenario-shock').value), result=A.scenario(state,shock,$('scenario-symbol').value||'all');
  $('scenario-label').textContent=pct(shock);
  $('scenario-result').innerHTML=result?`<strong class="${tone(result.delta)}">${signed(result.delta)}</strong><p>${money(result.total)} hypothetical value · ${pct(result.percent)} portfolio impact</p><p>Based on ${money(result.exposed)} priced exposure. Cash unchanged.${state.missingSymbols.length?' Unpriced holdings excluded.':''}</p>`:empty('Scenario unavailable without comparable, priced exposure.');
}
function renderHoldings() {
  if(!state)return;
  const quotes=A.sortedQuotes(researchQuotes(),{search:$('search').value,filter:tableFilter,sort:tableSort,direction:tableDirection,favorites});
  const active=document.activeElement;
  const focusSymbol=active?.dataset?.symbol, focusCompare=active?.dataset?.compare;
  $('holdings').innerHTML=quotes.map(q=>`<tr class="${q.symbol===selected?'active':''}"><td><input type="checkbox" data-compare="${esc(q.symbol)}" aria-label="Compare ${esc(q.symbol)}" ${compareSymbols.includes(q.symbol)?'checked':''} ${q.kind!=='stock'?'disabled':''}></td><td><button class="symbol" data-symbol="${esc(q.symbol)}">${favorites.includes(q.symbol)?'★ ':''}${esc(q.symbol)}</button><small>${esc(q.kind)} · ${q.quantity>0?'Holding':q.researchOnly?'Research universe':'Watchlist'}</small></td><td>${money(q.price,q.currency)}<small>${esc(q.extendedLabel||q.session)} · ${esc(q.currency||'USD')}</small><small>Received ${esc(stamp(q.receivedAt))}</small></td><td class="${tone(q.change)}">${pct(q.change)}</td><td>${q.quantity>0?num(q.quantity):'—'}</td><td>${money(q.value,q.currency)}</td><td>${valid(q.weight)?q.weight.toFixed(1)+'%':'—'}</td><td class="${tone(q.dayPL)}">${signed(q.dayPL,q.currency)}</td><td class="${tone(q.unrealizedPL)}">${signed(q.unrealizedPL,q.currency)}<small>${pct(q.unrealizedPercent)}</small></td><td><span class="mini-chart">${graph((q.sparkline||[]).map((v,i)=>[i,v]),[],true)}</span></td></tr>`).join('')||'<tr><td colspan="10" class="empty">No matching symbols. Try another filter or add securities in the menu bar.</td></tr>';
  if(focusSymbol||focusCompare)for(const node of $('holdings').querySelectorAll('button,input'))if(node.dataset.symbol===focusSymbol&&focusSymbol||node.dataset.compare===focusCompare&&focusCompare)node.focus({preventScroll:true});
  for(const th of $('positions-table').querySelectorAll('th[data-column]'))th.setAttribute('aria-sort',th.dataset.column===tableSort?(tableDirection==='asc'?'ascending':'descending'):'none');
  $('position-count').textContent=`${quotes.length} / ${researchQuotes().length}`;
  $('comparison-count').textContent=`${compareSymbols.length} / 4`;
}
function renderPortfolioChart() {
  if(!state.summary.currencyComparable){mountChart('portfolio-chart',empty('Portfolio chart unavailable across different quote currencies.'));$('chart-summary').textContent='Currency conversion needed';$('chart-stats').innerHTML='';$('chart-note').textContent='Individual security charts remain available in their quote currencies.';return;}
  const cutoff=Date.now()/1000-(portfolioRange==='1W'?7:30)*86400;
  const points=A.points(portfolioRange==='1D'?state.intraday:state.history.filter(p=>portfolioRange==='ALL'||p[0]>=cutoff));
  const comparison=portfolioRange==='1D'&&$('benchmark').checked?state.benchmark:[];
  const percent=$('portfolio-unit').value==='percent';
  $('benchmark').disabled=portfolioRange!=='1D';
  mountChart('portfolio-chart',graph(percent?A.normalize(points):points,percent?A.normalize(comparison):comparison,false,false,'USD',percent));
  $('chart-summary').textContent=points.length>1?`${money(points.at(-1)[1])} · ${signed(points.at(-1)[1]-points[0][1])} over displayed observations`:'History is building';
  $('chart-stats').innerHTML=chartStats(points);
  $('chart-note').textContent=portfolioRange==='1D'?'Intraday estimate using current holdings and minute bars. Gold: portfolio. Dashed blue: SPY rebased to the first portfolio value. Not a time-weighted investment return.':'Recorded values include holding and cash changes. Up to 120 days retained. Percentage change is not deposit-adjusted investment performance.';
}
function renderEarnings() {
  const events=state.quotes.filter(q=>q.earnings).sort((a,b)=>a.earnings.date-b.earnings.date);
  $('earnings').innerHTML=events.map(q=>{const days=Math.ceil((q.earnings.date-Date.now()/1000)/86400);return `<div class="event"><div><button data-open-symbol="${esc(q.symbol)}">${esc(q.symbol)}</button><small>${q.quantity>0?'Held position':'Watchlist'} · EPS ${esc(q.earnings.epsForecast??'Unavailable')}</small></div><div>${esc(new Date(q.earnings.date*1000).toLocaleDateString([],{month:'short',day:'numeric'}))}<small>${esc(q.earnings.session||'Unspecified')}</small><span class="days">${days<0?'Recent':days===0?'Today':days===1?'Tomorrow':`In ${days} days`}</span></div></div>`;}).join('')||empty('No upcoming dates returned for this watchlist.');
}
function renderTrades() {
  const trades=state.trades;
  const buys=trades.filter(t=>t.side==='Buy'), sells=trades.filter(t=>t.side==='Sell');
  $('activity-summary').innerHTML=stat('Recorded trades',num(trades.length),'Latest 100 ledger entries')+stat('Buys / sells',`${buys.length} / ${sells.length}`)+stat('Realized gain / loss',money(state.summary.currencyComparable?state.summary.realizedPL:null),'From recorded sales; basis-dependent');
  $('trades').innerHTML=trades.length?`<table><thead><tr><th>Date</th><th>Security</th><th>Action</th><th>Quantity</th><th>Price</th><th>Notional</th><th>Note</th></tr></thead><tbody>${trades.map(t=>`<tr><td>${esc(stamp(t.date))}</td><td><button data-open-symbol="${esc(t.symbol)}" class="symbol">${esc(t.symbol)}</button></td><td class="${t.side==='Buy'?'up':t.side==='Sell'?'down':''}">${esc(t.side)}</td><td>${num(t.quantity)}</td><td>${money(t.price,quoteFor(t.symbol)?.currency)}</td><td>${money(t.quantity*t.price,quoteFor(t.symbol)?.currency)}</td><td>${esc(t.note||'—')}</td></tr>`).join('')}</tbody></table>`:empty('No trades recorded in this portfolio. Log buys and sells in the menu bar app.');
}
const quoteFor = symbol => state?.quotes.find(q=>q.symbol===symbol)||studyQuotes.get(symbol);
function selectSecurity(symbol, shouldScroll=true) {
  if(symbol && !quoteFor(symbol)) {toast('This security is not in the current watchlist.');return;}
  if(symbol && symbol===selected){if(shouldScroll)scrollTo('research');return;}
  selected=symbol; financialData=null; expectationsData=null; securityChartData=null; newsData=null;
  renderHoldings(); renderSecurity(); renderNotebook(); loadResearch(); savePreferences();
  window.ResearchDesk?.selected();
  if(shouldScroll)scrollTo('research');
}
function renderSecurity() {
  const q=quoteFor(selected);
  $('security-select').innerHTML=researchQuotes().map(s=>`<option value="${esc(s.symbol)}">${esc(s.symbol)}${s.quantity>0?' · held':''}</option>`).join('');
  $('security-select').value=selected||'';
  $('pin-security').disabled=!q;
  $('previous-security').disabled=!q; $('next-security').disabled=!q;
  if(!q){$('security-name').textContent='Select a symbol';$('security-price').innerHTML='';$('security-kind').textContent='SECURITY DEEP DIVE';$('security-company').textContent='';$('position-context').innerHTML='';$('security-stats').innerHTML='';$('price-ranges').innerHTML='';$('research-links').innerHTML='';$('security-chart-stats').innerHTML='';return;}
  const pinned=favorites.includes(q.symbol);
  $('pin-security').textContent=pinned?'★ Pinned':'☆ Pin'; $('pin-security').setAttribute('aria-pressed',String(pinned));
  $('security-name').textContent=q.symbol; $('security-kind').textContent=`${q.kind==='stock'?'EQUITY':'CRYPTO'} · ${q.currency||'USD'} · ${q.extendedLabel||q.session||'Session unknown'}`;
  $('security-company').textContent=financialData?.company||q.company||'Price and research from independent public sources';
  $('security-price').innerHTML=`<strong>${money(q.price,q.currency)}</strong><span class="${tone(q.change)}">${pct(q.change)} ${q.researchOnly?'observed bar change':'live move'}</span><small>${q.researchOnly?'Observed '+esc(stamp(q.observedAt)):'Received '+esc(stamp(q.receivedAt))}</small>`;
  const chip=(label,value)=>`<span class="context-chip">${esc(label)}<b>${esc(value)}</b></span>`;
  $('position-context').innerHTML=q.quantity>0?chip('Held',num(q.quantity)+' shares')+chip('Live exposure',money(q.value,q.currency))+chip('Portfolio weight',valid(q.weight)?q.weight.toFixed(1)+'%':'—')+chip('Unrealized',signed(q.unrealizedPL,q.currency)):chip(q.researchOnly?'Research universe':'Watchlist','No held position');
  $('security-stats').innerHTML=stat('Previous close',money(q.previousClose,q.currency))+stat('Regular close / price',money(q.regularPrice,q.currency))+stat('Session move',pct(q.regularChange))+stat('Volume',compact(q.volume))+stat('Market capitalization',compact(q.marketCap))+stat('P/E · trailing',num(q.pe))+stat('Your average cost',money(q.averageCost,q.currency))+stat('Session contribution',signed(q.dayPL,q.currency));
  const range=(name,low,high)=>{const p=A.rangePosition(q.price,low,high);return `<div><div class="range-label"><span>${name}</span><span>${p===null?'Unavailable':p.toFixed(0)+'% of range'}</span></div><div class="range-bar"><svg viewBox="0 0 100 14" preserveAspectRatio="none" role="img" aria-label="${esc(name+' '+money(low,q.currency)+' to '+money(high,q.currency))}"><rect x="0" y="5" width="100" height="4" rx="2" fill="#2a3949"/>${p!==null?`<circle cx="${p}" cy="7" r="4" fill="#e6c895"/>`:''}</svg></div><div class="range-values"><span>${money(low,q.currency)}</span><span>${money(high,q.currency)}</span></div></div>`;};
  $('price-ranges').innerHTML=range('Day range',q.dayLow,q.dayHigh)+range('52-week range',q.yearLow,q.yearHigh);
  const symbol=encodeURIComponent(q.symbol);
  $('research-links').innerHTML=(q.kind==='stock'?[['https://finance.yahoo.com/quote/'+symbol+'/','Quote & profile'],['https://www.sec.gov/edgar/search/#/q='+symbol+'&dateRange=all','SEC filings'],['https://finance.yahoo.com/quote/'+symbol+'/analysis/','Estimates'],['https://finance.yahoo.com/quote/'+symbol+'/holders/','Ownership']]:[['https://www.coingecko.com/','CoinGecko']]).map(([url,label])=>external(url,label)).join('');
  if(expectationsData)renderExpectations(expectationsData);
  if(q.kind==='crypto') {
    const points=(q.sparkline||[]).map((v,i)=>[i,v]), percent=$('security-unit').value==='percent';
    mountChart('security-chart',graph(percent?A.normalize(points):points,[],false,true,q.currency,percent));
    $('security-chart-stats').innerHTML=chartStats(points,q.currency);
    $('security-chart-note').textContent='CoinGecko seven-day trend. Exact point timestamps are not supplied. Range controls apply to equity price history.';
  }
  for(const b of $('security-ranges').querySelectorAll('button'))b.disabled=q.kind!=='stock';
}
function renderSecurityChart() {
  if(!securityChartData)return;
  const data=securityChartData, percent=$('security-unit').value==='percent';
  mountChart('security-chart',data.error?empty(data.error):graph(percent?A.normalize(data.points):data.points,[],false,false,data.currency,percent));
  $('security-chart-stats').innerHTML=data.error?'':chartStats(data.points,data.currency);
  $('security-chart-note').textContent=data.error?'Price history unavailable.':`Yahoo Finance · ${data.currency} · Retrieved ${stamp(data.updatedAt)} · ${$('security-range').value==='1D'?'One-minute bars including extended hours':'Unadjusted historical close prices; excludes dividends'}`;
}
async function loadSecurityChart(background=false) {
  chartController?.abort(); const controller=new AbortController();chartController=controller;
  const generation=++chartGeneration, symbol=selected, range=$('security-range').value;
  lastChartAt=Date.now(); if(quoteFor(symbol)?.kind!=='stock')return;
  if(!background){securityChartData=null;mountChart('security-chart',pending('Loading price history…'));$('security-chart-stats').innerHTML='';}
  try {
    const data=await api(`chart?symbol=${encodeURIComponent(symbol)}&range=${range}`,controller.signal);
    if(generation!==chartGeneration||symbol!==selected)return;
    securityChartData=data;renderSecurityChart();
  } catch(error) {if(generation===chartGeneration&&!controller.signal.aborted)mountChart('security-chart',empty(`Chart unavailable. ${error.message}`));}
}
async function loadResearch() {
  lastResearchAt=Date.now(); researchController?.abort();chartController?.abort();
  const controller=new AbortController();researchController=controller;const generation=++researchGeneration;
  $('expectations-symbol').textContent=selected||'';$('fundamentals-symbol').textContent=selected||'';$('news-symbol').textContent=selected?`· ${selected}`:'';
  $('financial-source').textContent='SEC-reported figures, with fiscal periods and filing dates.';
  for(const id of ['ratios','financial-highlights','financial-chart'])$(id).innerHTML='';
  $('financial-metric').innerHTML='';
  const q=quoteFor(selected);
  if(!q||q.kind!=='stock'){
    $('analyst-content').innerHTML=empty('Analyst company estimates apply to equities.');$('financials').innerHTML=empty('SEC company fundamentals apply to equities. Use source links for crypto research.');$('news').innerHTML=empty('Company headlines are available for equities.');
    if(!q){mountChart('security-chart',empty('Add a security in Marketbar to begin researching.'));$('security-chart-note').textContent='';}return;
  }
  $('analyst-content').innerHTML=pending('Loading analyst expectations…');$('financials').innerHTML=pending('Loading SEC filings…');$('news').innerHTML=pending('Loading headlines…');
  loadSecurityChart();const query=`?symbol=${encodeURIComponent(selected)}`;
  await Promise.allSettled([
    api('expectations'+query,controller.signal).then(data=>{if(generation===researchGeneration){expectationsData=data;renderExpectations(data);window.ResearchDesk?.research();}}).catch(error=>{if(generation===researchGeneration)$('analyst-content').innerHTML=empty(`Analyst feed unavailable. ${error.message}`);}),
    api('research'+query,controller.signal).then(data=>{if(generation===researchGeneration){financialData=data;renderFinancials();renderSecurity();window.ResearchDesk?.research();}}).catch(error=>{if(generation===researchGeneration)$('financials').innerHTML=empty(`Company data unavailable. ${error.message}`);}),
    api('news'+query,controller.signal).then(data=>{if(generation===researchGeneration){newsData=data;$('news').innerHTML=data.error?empty(data.error):(data.items||[]).map(item=>`<article class="headline">${external(item.link,item.title)}<small>${esc(item.source||'Yahoo Finance feed')} · ${esc(item.pubDate||'Publication time unavailable')}</small></article>`).join('')||empty('No headlines returned.');window.ResearchDesk?.research();}}).catch(error=>{if(generation===researchGeneration)$('news').innerHTML=empty(`Headlines unavailable. ${error.message}`);})
  ]);
}
function renderFinancials() {
  const data=financialData;if(!data)return;
  if(data.error){$('financials').innerHTML=empty(data.error);return;}
  $('financial-source').textContent=`${data.company} · SEC EDGAR CIK ${data.cik} · Retrieved ${stamp(data.updatedAt)}. Periods can differ between metrics; compare labels and filing dates. USD unless otherwise labeled.`;
  $('ratios').innerHTML=(data.ratios||[]).map(r=>stat(r.label,r.display,r.detail)).join('');
  const metrics=data[financialPeriod]||[], chosen=$('financial-metric').value;
  $('financial-metric').innerHTML=metrics.map(m=>`<option value="${esc(m.id)}">${esc(m.label)} · ${esc(m.unit)}</option>`).join('');
  $('financial-metric').value=metrics.some(m=>m.id===chosen)?chosen:metrics.find(m=>m.id==='revenue')?.id||metrics[0]?.id||'';
  $('financial-highlights').innerHTML=['revenue','net_income','operating_cash_flow','free_cash_flow'].map(id=>{
    const m=metrics.find(m=>m.id===id);if(!m)return '';const latest=m.points.at(-1), change=A.financialChange(m);
    return `<div class="financial-highlight"><p>${esc(m.label)}</p><div class="value">${latest?compact(latest.value):'—'}</div><p>${esc(latest?.label||'No observations')} · ${esc(m.unit)}</p><p>${change?`${pct(change.percent)} vs ${esc(change.previous.label)}${change.percent===null?' · percentage unavailable for a nonpositive baseline':''}`:'More history needed for comparison'}</p></div>`;
  }).join('');
  renderFinancialChart();
  $('financials').innerHTML=metrics.length?`<table><thead><tr><th>Reported metric</th><th>Earlier</th><th>Earlier</th><th>Previous</th><th>Latest reported</th><th>Change vs previous</th></tr></thead><tbody>${metrics.map(m=>{const points=m.points.slice(-4);while(points.length<4)points.unshift(null);const change=A.financialChange(m);return `<tr><td class="financials-label">${esc(m.label)}<small>${esc(m.statement)} · ${esc(m.unit)}</small></td>${points.map(p=>`<td class="financial-value">${p?compact(p.value):'—'}<small>${p?esc(p.label):''}</small><small>${p?`Filed ${esc(p.filed)}`:''}</small></td>`).join('')}<td>${change?pct(change.percent):'—'}<small>${change?compact(change.delta)+' '+esc(m.unit):''}</small></td></tr>`;}).join('')}</tbody></table>`:empty('No reported metrics available for this period.');
  window.ResearchDesk?.research();
}
function renderFinancialChart() {
  const m=(financialData?.[financialPeriod]||[]).find(m=>m.id===$('financial-metric').value);
  $('financial-chart').innerHTML=m?estimateBars(m.points.slice(-10).map(p=>({label:p.label,value:p.value})),m.unit):empty('No reported metric available for this period.');
}
function estimateBars(rows, unit) {
  const clean=rows.filter(r=>valid(r.value));if(!clean.length)return empty('No observations returned.');
  const low=Math.min(0,...clean.map(r=>valid(r.low)?Math.min(r.low,r.value):r.value)), high=Math.max(0,...clean.map(r=>valid(r.high)?Math.max(r.high,r.value):r.value)), span=high-low||1;
  const y=v=>24+(high-v)/span*170, width=720/clean.length;
  return `<svg viewBox="0 0 720 260" role="img" aria-label="${esc(unit+' observations: '+clean.map(r=>r.label+' '+num(r.value)).join(', '))}"><line class="grid-line" x1="0" x2="720" y1="${y(0)}" y2="${y(0)}"/>${clean.map((r,i)=>{const x=width*(i+.5);return `<rect x="${x-width*.24}" y="${Math.min(y(0),y(r.value))}" width="${width*.48}" height="${Math.max(1,Math.abs(y(0)-y(r.value)))}" fill="${r.value<0?'#f28f9d':'#e6c895'}" opacity=".8"/>${valid(r.low)&&valid(r.high)?`<path d="M${x},${y(r.low)}V${y(r.high)}M${x-5},${y(r.low)}h10M${x-5},${y(r.high)}h10" stroke="#edf1f5" fill="none"/>`:''}<text x="${x}" y="219" text-anchor="middle">${esc(compact(r.value))}</text><text x="${x}" y="243" text-anchor="middle">${esc(r.label)}</text>`;}).join('')}</svg>`;
}
function renderExpectations(data) {
  const t=data.targets?.consensusOverview||{},q=quoteFor(selected),current=q?.price;
  const upside=valid(t.priceTarget)&&valid(current)&&current>0&&q.currency==='USD'?(t.priceTarget/current-1)*100:null;
  const targets=[t.lowPriceTarget,t.priceTarget,t.highPriceTarget,current].filter(valid);
  let range='';
  if(valid(t.lowPriceTarget)&&valid(t.highPriceTarget)&&t.highPriceTarget>t.lowPriceTarget&&q?.currency==='USD'){
    const min=Math.min(...targets)*.96,max=Math.max(...targets)*1.04,x=v=>25+(v-min)/(max-min||1)*650;
    range=`<div class="target-range"><svg viewBox="0 0 720 72" role="img" aria-label="${esc(`Analyst targets from ${money(t.lowPriceTarget)} to ${money(t.highPriceTarget)}. Current ${money(current)}.`)}"><line x1="${x(t.lowPriceTarget)}" x2="${x(t.highPriceTarget)}" y1="28" y2="28" stroke="#526b83" stroke-width="5" stroke-linecap="round"/>${[t.lowPriceTarget,t.priceTarget,t.highPriceTarget].filter(valid).map(v=>`<circle cx="${x(v)}" cy="28" r="5" fill="#e6c895"/>`).join('')}${valid(current)?`<path d="M${x(current)},8V42" stroke="#7cddba" stroke-dasharray="3 3"/><text x="${x(current)}" y="62" text-anchor="middle">Now ${money(current)}</text>`:''}<text x="${x(t.lowPriceTarget)}" y="13" text-anchor="middle">Low</text><text x="${x(t.highPriceTarget)}" y="13" text-anchor="middle">High</text></svg></div>`;
  }
  const table=rows=>rows.length?`<table><thead><tr><th>Fiscal end</th><th>Consensus EPS</th><th>Low / High</th><th>Analysts</th><th>4-week ↑ / ↓</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.fiscalEnd)}</td><td>${num(r.consensusEPSForecast)}</td><td>${num(r.lowEPSForecast)} / ${num(r.highEPSForecast)}</td><td>${num(r.noOfEstimates)}</td><td><span class="up">${num(r.up)}</span> / <span class="down">${num(r.down)}</span></td></tr>`).join('')}</tbody></table>`:empty('No EPS coverage returned.');
  const annual=data.eps?.yearlyForecast?.rows||[], quarterly=data.eps?.quarterlyForecast?.rows||[];
  $('analyst-content').innerHTML=`<div class="stat-grid">${stat('Low target · USD',money(t.lowPriceTarget))}${stat('Average target · USD',money(t.priceTarget))}${stat('High target · USD',money(t.highPriceTarget))}${stat('Implied upside to average',pct(upside),q?.currency!=='USD'?'Requires a USD quote':'Relative to current quote')}</div>${range}<div class="analyst-ratings">${['buy','hold','sell'].filter(k=>valid(t[k])).map(k=>`<span class="rating rating-${k}">${esc(k.toUpperCase())} <b>${num(t[k])}</b></span>`).join('')}</div><p class="footnote">12-month targets are analyst opinions. Targets retrieved ${stamp(data.targetsRetrievedAt)}; provider publication timestamp not supplied. Recommendation counts and EPS coverage can differ.</p><h3>Annual earnings expectations · USD/share</h3><p class="footnote">Gold bars: consensus EPS. White ranges: lowest to highest analyst estimate.</p><div class="chart small">${estimateBars(annual.map(r=>({label:r.fiscalEnd,value:r.consensusEPSForecast,low:r.lowEPSForecast,high:r.highEPSForecast})),'USD/share')}</div><div class="table-scroll">${table(annual)}</div><h3>Quarterly estimates & revisions</h3><div class="table-scroll">${table(quarterly)}</div><p class="footnote">Nasdaq analyst feeds · EPS retrieved ${stamp(data.epsRetrievedAt)} · Revisions over four weeks. Adjusted analyst EPS may not be comparable to SEC GAAP EPS.</p>${(data.errors||[]).map(empty).join('')}`;
}

async function renderComparison() {
  comparisonController?.abort();const controller=new AbortController();comparisonController=controller;
  const generation=++comparisonGeneration;
  $('comparison').hidden=!compareSymbols.length;$('comparison-count').textContent=`${compareSymbols.length} / 4`;
  if(!compareSymbols.length)return;
  if(compareSymbols.length<2){$('compare-chart').innerHTML=empty('Select another equity in the positions table to compare.');$('compare-legend').innerHTML='';$('compare-note').textContent='Up to four equities, rebased to their first observation in the shared time window.';return;}
  const symbols=[...compareSymbols],range=$('compare-range').value;
  const currencies=new Set(symbols.map(s=>quoteFor(s)?.currency||'USD'));
  if(currencies.size>1){$('compare-chart').innerHTML=empty('Choose securities in the same quote currency for a comparable price chart.');$('compare-legend').innerHTML='';$('compare-note').textContent='FX conversion is not available.';return;}
  $('compare-chart').innerHTML=pending('Aligning price histories…');
  const results=await Promise.allSettled(symbols.map(symbol=>api(`chart?symbol=${encodeURIComponent(symbol)}&range=${range}`,controller.signal)));
  if(generation!==comparisonGeneration)return;
  const successful=[],failed=[];
  results.forEach((r,i)=>{const clean=r.status==='fulfilled'&&!r.value.error?A.points(r.value.points):[];
    if(clean.length>1)successful.push({name:symbols[i],points:clean,color:colors[successful.length]});else failed.push(symbols[i]);});
  if(successful.length<2){$('compare-chart').innerHTML=empty('Two available price histories are needed for comparison.');$('compare-legend').innerHTML='';$('compare-note').textContent=`Unavailable: ${failed.join(', ')}. Try another range or security.`;return;}
  const start=Math.max(...successful.map(s=>s.points[0][0])),end=Math.min(...successful.map(s=>s.points.at(-1)[0]));
  const series=successful.map(s=>({...s,points:A.normalize(s.points.filter(p=>p[0]>=start&&p[0]<=end))}));
  if(series.some(s=>s.points.length<2)){$('compare-chart').innerHTML=empty('These histories do not share enough observations.');$('compare-legend').innerHTML='';return;}
  $('compare-legend').innerHTML=series.map(s=>`<span><svg class="swatch" viewBox="0 0 8 8"><rect width="8" height="8" rx="2" fill="${s.color}"/></svg>${esc(s.name)} <b class="${tone(s.points.at(-1)[1])}">${pct(s.points.at(-1)[1])}</b></span>`).join('');
  mountChart('compare-chart',graph(series[0].points,[],false,false,'USD',true,series.slice(1),series[0].name));
  $('compare-note').textContent=`${range} · Rebased to each security’s first available close in the shared window. Price changes exclude dividends and FX.${failed.length?' Unavailable: '+failed.join(', ')+'.':''}`;
}
function renderPinned() {
  $('pinned').innerHTML=favorites.filter(s=>quoteFor(s)).map(s=>{const q=quoteFor(s);return `<button class="pinned-row" data-open-symbol="${esc(s)}"><b>${esc(s)}</b><span class="${tone(q.change)}">${pct(q.change)}</span></button>`;}).join('')||'<p>Pin a security from its research view.</p>';
}
function renderNotebook() {
  $('notebook-symbol').textContent=selected||'';
  const note=dirtyNotes.get(selected)||workspace.notes?.[selected]||{};
  for(const field of ['thesis','risks','catalysts']){const node=$('note-'+field);node.value=note[field]||'';node.disabled=!selected||!workspaceReady;}
  $('note-status').textContent=!workspaceReady?'Notebook storage unavailable. Use Refresh to reconnect.':!selected?'Select a security to begin.':dirtyNotes.has(selected)?'Unsaved changes retained in this browser.':note.updatedAt?`Saved on this Mac · ${stamp(note.updatedAt)}`:'Ready for your research. Notes autosave on this Mac.';
}
function keepDrafts() {
  try { localStorage.setItem('marketbar.pendingNotes',JSON.stringify(Object.fromEntries(dirtyNotes))); } catch { /* Native persistence remains authoritative. */ }
}
async function drainNotes() {
  if(savingNotes||!workspaceReady||!dirtyNotes.size)return;
  savingNotes=true;
  try {
    while(dirtyNotes.size){
      const [symbol,note]=dirtyNotes.entries().next().value;
      if(symbol===selected)$('note-status').textContent='Saving on this Mac…';
      await api('workspace',undefined,{symbol,note});
      workspace.notes[symbol]={...note,updatedAt:Date.now()/1000};
      // A newer draft must survive an older request finishing.
      if(dirtyNotes.get(symbol)===note)dirtyNotes.delete(symbol);
      keepDrafts();
      if(symbol===selected)$('note-status').textContent=dirtyNotes.has(symbol)?'Saving newer changes…':'Saved on this Mac.';
      window.ResearchDesk?.notesChanged();
    }
  } catch(error) {
    $('note-status').textContent='Save failed; your draft is retained. Use Refresh to retry.';
    toast('Notebook save failed. Your draft is retained in this browser.');
  } finally {savingNotes=false;}
}
function editNote() {
  if(!selected||!workspaceReady)return;
  const prior=dirtyNotes.get(selected)||workspace.notes?.[selected]||{};
  const note={...prior,...Object.fromEntries(['thesis','risks','catalysts'].map(field=>[field,$('note-'+field).value]))};delete note.updatedAt;
  dirtyNotes.set(selected,note);keepDrafts();$('note-status').textContent='Unsaved changes · autosaving…';
  clearTimeout(noteTimer);noteTimer=setTimeout(drainNotes,600);window.ResearchDesk?.notesChanged();
}
function preferences() {
  return {compact:document.body.classList.contains('dense'),portfolioRange,portfolioUnit:$('portfolio-unit').value,financialPeriod,
    securityRange:$('security-range').value,securityUnit:$('security-unit').value,favorites,selected:selected||'',benchmark:$('benchmark').checked,researchSymbols};
}
function savePreferences() {
  if(!workspaceReady)return;
  clearTimeout(preferenceTimer);preferenceTimer=setTimeout(async()=>{
    try{await api('workspace',undefined,{preferences:preferences()});}
    catch{toast('View preferences could not be saved. Use Refresh to reconnect.');}
  },500);
}
async function loadWorkspace() {
  try {
    const data=await api('workspace');
    if(!data.notes||!data.preferences)throw new Error('Workspace storage unavailable');
    workspace={notes:Object.assign(Object.create(null),data.notes),preferences:data.preferences};workspaceReady=true;
    try{
      const recovered=JSON.parse(localStorage.getItem('marketbar.pendingNotes')||'{}');
      for(const [symbol,note] of Object.entries(recovered))if(symbol.length<=100&&note&&['thesis','risks','catalysts'].every(k=>typeof note[k]==='string'&&note[k].length<=12000))dirtyNotes.set(symbol,note);
    }catch{}
    const p=workspace.preferences;
    researchSymbols=Array.isArray(p.researchSymbols)?p.researchSymbols:[];
    favorites=Array.isArray(p.favorites)?p.favorites.filter(s=>typeof s==='string'):[];
    selected=typeof p.selected==='string'?p.selected:undefined;
    portfolioRange=p.portfolioRange||'1D';financialPeriod=p.financialPeriod||'annual';
    $('portfolio-unit').value=p.portfolioUnit||'value';$('security-range').value=p.securityRange||'1D';$('security-unit').value=p.securityUnit||'value';$('benchmark').checked=p.benchmark===true;
    document.body.classList.toggle('dense',p.compact===true);$('density').setAttribute('aria-pressed',String(p.compact===true));
    chooseSegment('portfolio-ranges',portfolioRange,'range');chooseSegment('financial-period',financialPeriod,'period');chooseSegment('security-ranges',$('security-range').value,'securityRange');
  } catch {workspaceReady=false;}
  renderNotebook();window.ResearchDesk?.loaded();
}
function download(name,text,type='text/csv;charset=utf-8') {
  const url=URL.createObjectURL(new Blob([text],{type})),link=document.createElement('a');
  link.href=url;link.download=name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
const filename = text => String(text||'portfolio').replace(/[^a-z0-9_-]/gi,'-').slice(0,80);
function exportPositions() {
  if(!state){toast('Waiting for portfolio data.');return;}
  const header=['Symbol','Kind','Currency','Live price','Regular price','Live move %','Shares','Live value','Weight %','Session P/L','Unrealized P/L','Cost per share','Received at'];
  const rows=state.quotes.map(q=>[q.symbol,q.kind,q.currency||'USD',q.price,q.regularPrice,q.change,q.quantity,q.value,q.weight,q.dayPL,q.unrealizedPL,q.averageCost,valid(q.receivedAt)?new Date(q.receivedAt*1000).toISOString():'']);
  download(filename(state.portfolioName)+'-positions.csv',A.csv([header,...rows]));toast('Positions exported.');
}
function exportTrades() {
  if(!state){toast('Waiting for ledger data.');return;}
  download(filename(state.portfolioName)+'-ledger.csv',A.csv([['Date','Symbol','Side','Quantity','Price','Currency','Notional','Note'],...state.trades.map(t=>[new Date(t.date*1000).toISOString(),t.symbol,t.side,t.quantity,t.price,quoteFor(t.symbol)?.currency||'App reporting currency',t.quantity*t.price,t.note])]));
  toast('Ledger exported.');
}
function exportNotes() {
  const notes={...workspace.notes,...Object.fromEntries(dirtyNotes)};
  const text='# Marketbar research notebook\n\nExported '+new Date().toLocaleString()+'\n\n'+Object.entries(notes).sort(([a],[b])=>a.localeCompare(b)).map(([symbol,note])=>`## ${symbol}\n\n### Investment thesis\n${note.thesis||'—'}\n\n### Risks & invalidation\n${note.risks||'—'}\n\n### Catalysts & next questions\n${note.catalysts||'—'}\n`).join('\n');
  download('marketbar-research-notebook.md',text,'text/markdown;charset=utf-8');toast('Notebook exported, including unsaved drafts.');
}
function renderCommand() {
  const query=$('command-search').value.trim().toUpperCase();
  const quotes=researchQuotes().filter(q=>q.symbol.toUpperCase().includes(query)).slice(0,30);
  commandIndex=Math.max(0,Math.min(commandIndex,quotes.length-1));
  $('command-results').innerHTML=quotes.map((q,i)=>`<button class="command-result ${i===commandIndex?'active':''}" data-open-symbol="${esc(q.symbol)}"><b>${esc(q.symbol)}${favorites.includes(q.symbol)?' ★':''}</b><small>${q.quantity>0?'Held':'Watchlist'} · ${money(q.price,q.currency)} <span class="${tone(q.change)}">${pct(q.change)}</span></small></button>`).join('')||empty('No matching security in your holdings or watchlist.');
  $('command-results').querySelector('.active')?.scrollIntoView({block:'nearest'});
}
function openCommand() {if(!$('command-dialog').open){$('command-search').value='';$('command-add').hidden=true;commandIndex=0;renderCommand();$('command-dialog').showModal();$('command-search').focus();}}

async function sync() {
  if(loading||document.hidden)return;
  loading=true;
  try {
    const next=await api('snapshot');if(next.error)throw new Error(next.error);
    state=next;
    const fingerprint=JSON.stringify([next.portfolioID,next.portfolioName,next.portfolios,next.quotes,next.indices,next.summary,next.trades,next.intraday,next.history,next.benchmark,next.missingSymbols]);
    if(fingerprint!==lastFingerprint){lastFingerprint=fingerprint;render();}
    $('status').textContent=next.stale?`● ${next.status} · prices may be stale`:`● ${next.status}`;
    $('status').className=next.stale?'down':'up';$('updated').textContent=`Newest successful refresh ${stamp(next.updatedAt)}`;
    const warnings=[];
    if(next.failedSymbols?.length)warnings.push(`Refresh failed for ${next.failedSymbols.join(', ')}; last known prices shown.`);
    const foreign=next.quotes.filter(q=>q.quantity>0&&q.currency&&q.currency!=='USD');
    if(foreign.length)warnings.push(`Currency limitation: ${foreign.map(q=>q.symbol+' '+q.currency).join(', ')}. The app does not convert FX; mixed-currency portfolio totals and weights are withheld.`);
    if(next.missingSymbols.length)warnings.push(`Missing prices for ${next.missingSymbols.join(', ')}. Totals cover priced positions only.`);
    if(next.backoffSeconds>0)warnings.push(`Provider rate limit: backing off for ${Math.ceil(next.backoffSeconds)} seconds.`);
    if(next.stale)warnings.push('Last known prices retained. Check timestamps before relying on these values.');
    $('warning').hidden=!warnings.length;$('warning').textContent=warnings.join(' ');
    $('cadence').textContent=`Workspace sync: 1 second · Quote polling cadence: ${next.pollSeconds}s. Equities can poll every 2s in regular hours while visible; extended hours ≥15s, closed equities ≥300s, crypto ≥10s. Public feeds may delay quotes; this is polling, not exchange streaming.`;
    window.ResearchDesk?.poll();
    if(selected&&Date.now()-lastChartAt>60000&&$('security-range').value==='1D')loadSecurityChart(true);
    if(selected&&Date.now()-lastResearchAt>300000)loadResearch();
  } catch(error) {
    $('status').textContent='● Disconnected';$('status').className='down';$('warning').hidden=false;
    $('warning').textContent=`${error.message}. Last displayed values may be stale. Reopen the research launcher to restart the background service, then reload this page.`;
  } finally {loading=false;}
}

// Delegated security selection works from tables, exposure, radar and the palette.
document.addEventListener('click',event=>{
  const button=event.target.closest('[data-open-symbol],[data-symbol]');if(!button)return;
  if($('command-dialog').open)$('command-dialog').close();
  selectSecurity(button.dataset.openSymbol||button.dataset.symbol);
});
$('holdings').addEventListener('change',event=>{
  const input=event.target.closest('[data-compare]');if(!input)return;
  const symbol=input.dataset.compare;
  if(input.checked){if(compareSymbols.length>=4){input.checked=false;toast('Compare up to four equities at a time.');return;}compareSymbols.push(symbol);}
  else compareSymbols=compareSymbols.filter(s=>s!==symbol);
  renderComparison();
});
$('search').addEventListener('input',()=>state&&renderHoldings());
$('position-filters').addEventListener('click',event=>{const button=event.target.closest('[data-filter]');if(!button)return;tableFilter=button.dataset.filter;chooseSegment('position-filters',tableFilter,'filter');renderHoldings();});
$('positions-table').addEventListener('click',event=>{const button=event.target.closest('[data-sort]');if(!button)return;tableDirection=tableSort===button.dataset.sort?(tableDirection==='desc'?'asc':'desc'):(button.dataset.sort==='symbol'?'asc':'desc');tableSort=button.dataset.sort;renderHoldings();});
$('portfolio-ranges').addEventListener('click',event=>{const button=event.target.closest('[data-range]');if(!button||!state)return;portfolioRange=button.dataset.range;chooseSegment('portfolio-ranges',portfolioRange,'range');renderPortfolioChart();savePreferences();});
for(const id of ['benchmark','portfolio-unit'])$(id).addEventListener('change',()=>{if(state)renderPortfolioChart();savePreferences();});
for(const id of ['scenario-symbol','scenario-shock'])$(id).addEventListener('input',renderScenario);
$('security-ranges').addEventListener('click',event=>{const button=event.target.closest('[data-security-range]');if(!button)return;$('security-range').value=button.dataset.securityRange;chooseSegment('security-ranges',button.dataset.securityRange,'securityRange');loadSecurityChart();savePreferences();});
$('security-range').addEventListener('change',()=>{loadSecurityChart();savePreferences();});
$('security-unit').addEventListener('change',()=>{if(quoteFor(selected)?.kind==='crypto')renderSecurity();else renderSecurityChart();savePreferences();});
$('security-select').addEventListener('change',()=>selectSecurity($('security-select').value,false));
for(const [id,step] of [['previous-security',-1],['next-security',1]])$(id).addEventListener('click',()=>{const quotes=researchQuotes();if(!quotes.length)return;const i=quotes.findIndex(q=>q.symbol===selected);selectSecurity(quotes[(i+step+quotes.length)%quotes.length].symbol,false);});
$('pin-security').addEventListener('click',()=>{if(!selected)return;favorites=favorites.includes(selected)?favorites.filter(s=>s!==selected):[...favorites,selected].slice(-200);renderPinned();renderSecurity();renderHoldings();savePreferences();});
$('financial-period').addEventListener('click',event=>{const button=event.target.closest('[data-period]');if(!button)return;financialPeriod=button.dataset.period;chooseSegment('financial-period',financialPeriod,'period');renderFinancials();savePreferences();});
$('financial-metric').addEventListener('change',renderFinancialChart);
$('compare-range').addEventListener('change',renderComparison);
$('clear-comparison').addEventListener('click',()=>{compareSymbols=[];renderComparison();renderHoldings();});
$('density').addEventListener('click',()=>{const compact=document.body.classList.toggle('dense');$('density').setAttribute('aria-pressed',String(compact));savePreferences();});
$('refresh').addEventListener('click',async()=>{if(!workspaceReady)await loadWorkspace();await sync();if(selected){loadResearch();renderNotebook();}window.ResearchDesk?.refreshStudy();drainNotes();savePreferences();if(compareSymbols.length>1)renderComparison();toast('Workspace refreshed from the app.');});
$('export').addEventListener('click',exportPositions);$('export-trades').addEventListener('click',exportTrades);$('export-notes').addEventListener('click',exportNotes);
for(const field of ['thesis','risks','catalysts'])$('note-'+field).addEventListener('input',editNote);
$('open-command').addEventListener('click',openCommand);$('close-command').addEventListener('click',()=>$('command-dialog').close());
$('command-search').addEventListener('input',()=>{commandIndex=0;renderCommand();});
$('command-search').addEventListener('keydown',event=>{
  if(!['ArrowDown','ArrowUp','Enter'].includes(event.key))return;event.preventDefault();
  const results=[...$('command-results').querySelectorAll('[data-open-symbol]')];
  if(event.key==='Enter'){results[commandIndex]?.click();return;}
  commandIndex=Math.max(0,Math.min(results.length-1,commandIndex+(event.key==='ArrowDown'?1:-1)));renderCommand();
});
$('command-dialog').addEventListener('click',event=>{if(event.target===$('command-dialog')){const box=$('command-dialog').getBoundingClientRect();if(event.clientX<box.left||event.clientX>box.right||event.clientY<box.top||event.clientY>box.bottom)$('command-dialog').close();}});
document.addEventListener('keydown',event=>{
  const editing=event.target.closest('input,textarea,select,[contenteditable="true"]');
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();openCommand();}
  else if(event.key==='/'&&!editing&&!event.metaKey&&!event.ctrlKey){event.preventDefault();scrollTo('positions');$('search').focus();}
});
document.addEventListener('visibilitychange',()=>{if(!document.hidden){sync();drainNotes();}else drainNotes();});
window.addEventListener('beforeunload',event=>{if(dirtyNotes.size){event.preventDefault();event.returnValue='';}});

// Delegation also covers newly rendered analyst charts.
document.addEventListener('pointermove',event=>{
  const chart=event.target.closest('.chart'),svg=chart?.querySelector('svg[data-points]');if(!svg)return;
  const points=JSON.parse(svg.dataset.points),box=svg.getBoundingClientRect(),fraction=Math.max(0,Math.min(1,((event.clientX-box.left)/box.width*720-3)/653));
  const target=Number(svg.dataset.first)+fraction*(Number(svg.dataset.last)-Number(svg.dataset.first));
  let index=0;for(let i=1;i<points.length;i++)if(Math.abs(points[i][0]-target)<Math.abs(points[index][0]-target))index=i;
  inspectChart(svg,index);
});
for(const chart of document.querySelectorAll('.chart')){
  const clear=()=>{chart.querySelectorAll('.chart-guide,.chart-dot,.chart-inspector').forEach(el=>el.remove());chart.querySelector('svg[data-points]')?.removeAttribute('data-index');};
  chart.addEventListener('pointerleave',clear);chart.addEventListener('focusout',clear);
}
document.addEventListener('keydown',event=>{
  const svg=event.target.closest('svg[data-points]');if(!svg||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
  event.preventDefault();const count=JSON.parse(svg.dataset.points).length;let index=Number(svg.dataset.index??count-1);
  index=event.key==='Home'?0:event.key==='End'?count-1:index+(event.key==='ArrowRight'?1:-1);inspectChart(svg,index);
});
const navLinks=[...document.querySelectorAll('nav a')];
function updateNavigation(){if(window.ResearchDesk)return;let current='overview';for(const id of ['overview','exposure','positions','research','expectations','fundamentals','notebook','activity'])if($(id).getBoundingClientRect().top<window.innerHeight*.35)current=id;for(const link of navLinks){if(link.hash==='#'+current)link.setAttribute('aria-current','location');else link.removeAttribute('aria-current');}}
window.addEventListener('scroll',updateNavigation,{passive:true});
async function initialize(){await loadWorkspace();await sync();if(selected){renderNotebook();if(!lastResearchAt)loadResearch();}drainNotes();}
initialize();setInterval(sync,1000);

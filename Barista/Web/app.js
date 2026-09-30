'use strict';
const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const valid = n => typeof n === 'number' && Number.isFinite(n);
const money = (n,currency='USD') => valid(n) ? new Intl.NumberFormat('en-US',{style:'currency',currency:/^[A-Z]{3}$/.test(currency)?currency:'USD',maximumFractionDigits:2}).format(n) : '—';
const num = n => valid(n) ? new Intl.NumberFormat('en-US',{maximumFractionDigits:4}).format(n) : '—';
const compact = n => valid(n) ? new Intl.NumberFormat('en-US',{notation:'compact',maximumFractionDigits:2}).format(n) : '—';
const pct = n => valid(n) ? `${n > 0 ? '+' : ''}${n.toFixed(2)}%` : '—';
const signed = (n,currency='USD') => valid(n) ? `${n > 0 ? '+' : ''}${money(n,currency)}` : '—';
const tone = n => valid(n) ? n >= 0 ? 'up' : 'down' : '';
const stamp = t => t ? new Date(t * 1000).toLocaleString([], {month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}) : 'Unavailable';
const empty = text => `<div class="empty">${esc(text)}</div>`;
const stat = (label,value) => `<div class="stat"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div></div>`;
const external = (url,label) => `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(label)} ↗</a>`;
let state, selected, portfolioRange = '1D', financialPeriod = 'annual', financialData, lastFingerprint, loading = false;
let researchGeneration = 0, researchController, chartController, chartGeneration = 0, lastChartAt = 0, lastResearchAt = 0, graphID = 0;
async function api(path, signal) {
  const response = await fetch(path, {cache:'no-store',signal:signal || AbortSignal.timeout(25000),credentials:'omit'});
  if (!response.ok) throw new Error(response.status === 403 ? 'This app session ended. Reopen research from the menu bar.' : `App connection returned ${response.status}`);
  return response.json();
}
function graph(points, comparison = [], mini = false, ordinal = false, currency = 'USD') {
  const clean = points.filter(p => Array.isArray(p) && valid(p[0]) && valid(p[1])).sort((a,b)=>a[0]-b[0]);
  if (clean.length < 2) return mini ? '' : empty('A little more history is needed. This chart fills in as prices arrive.');
  const w=mini?90:720, h=mini?28:260, top=mini?3:24, bottom=mini?3:28, left=mini?0:3, right=mini?0:64;
  const compare=comparison.filter(p=>valid(p[0])&&valid(p[1])&&p[0]>=clean[0][0]&&p[0]<=clean.at(-1)[0]);
  const values=[...clean,...compare].map(p=>p[1]), low=Math.min(...values), high=Math.max(...values);
  const padding=(high-low||Math.max(Math.abs(high)*.01,1))*.1, min=low-padding, max=high+padding, span=max-min;
  const x=t=>left+(t-clean[0][0])/(clean.at(-1)[0]-clean[0][0]||1)*(w-left-right);
  const y=v=>top+(max-v)/span*(h-top-bottom);
  const line=p=>p.map((point,i)=>`${i?'L':'M'}${x(point[0]).toFixed(2)},${y(point[1]).toFixed(2)}`).join(' ');
  const grid=mini?'':Array.from({length:4},(_,i)=>{const v=high-i*(high-low||span)/3,py=y(v);return `<line class="grid-line" x1="0" y1="${py}" x2="${w-right+8}" y2="${py}"/><text x="${w-right+15}" y="${py+4}">${esc(compact(v))}</text>`;}).join('');
  const sameDay=new Date(clean[0][0]*1000).toDateString()===new Date(clean.at(-1)[0]*1000).toDateString();
  const label=t=>new Date(t*1000).toLocaleString([],sameDay?{hour:'numeric',minute:'2-digit'}:{month:'short',day:'numeric'});
  const labels=mini?'':`<text x="0" y="${h-2}">${esc(ordinal?'Earlier':label(clean[0][0]))}</text><text text-anchor="end" x="${w-right}" y="${h-2}">${esc(ordinal?'Latest':label(clean.at(-1)[0]))}</text>`;
  const id=`chart-fill-${++graphID}`;
  const area=mini?'':`<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#e0c392" stop-opacity=".16"/><stop offset="100%" stop-color="#e0c392" stop-opacity="0"/></linearGradient></defs><path d="${line(clean)} L${x(clean.at(-1)[0])},${h-bottom} L${x(clean[0][0])},${h-bottom} Z" fill="url(#${id})"/>`;
  const interaction=mini?'':` tabindex="0" data-points="${esc(JSON.stringify(clean))}" data-min="${min}" data-max="${max}" data-ordinal="${ordinal}" data-currency="${esc(currency)}"`;
  return `<svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" role="img" aria-label="${esc(`Value from ${num(clean[0][1])} to ${num(clean.at(-1)[1])}. ${mini?'':'Use left and right arrow keys to inspect observations.'}`)}"${interaction}>${grid}${area}${compare.length>1?`<path class="benchmark-line" d="${line(compare)}"/>`:''}<path class="line ${mini?tone(clean.at(-1)[1]-clean[0][1]):''}" d="${line(clean)}"/>${labels}</svg>`;
}
function inspectChart(svg,index) {
  const points=JSON.parse(svg.dataset.points);index=Math.max(0,Math.min(points.length-1,index));svg.dataset.index=index;
  const point=points[index],x=3+(point[0]-points[0][0])/(points.at(-1)[0]-points[0][0]||1)*653;
  const y=24+(Number(svg.dataset.max)-point[1])/(Number(svg.dataset.max)-Number(svg.dataset.min))*208;
  let guide=svg.querySelector('.chart-guide'),dot=svg.querySelector('.chart-dot');
  if(!guide){guide=document.createElementNS('http://www.w3.org/2000/svg','line');guide.setAttribute('class','chart-guide');svg.append(guide);dot=document.createElementNS('http://www.w3.org/2000/svg','circle');dot.setAttribute('class','chart-dot');dot.setAttribute('r','4');svg.append(dot);}
  guide.setAttribute('x1',x);guide.setAttribute('x2',x);guide.setAttribute('y1','18');guide.setAttribute('y2','232');dot.setAttribute('cx',x);dot.setAttribute('cy',y);
  let output=svg.parentElement.querySelector('.chart-inspector');if(!output){output=document.createElement('output');output.className='chart-inspector';svg.parentElement.append(output);}
  output.textContent=`${svg.dataset.ordinal==='true'?`Observation ${index+1}`:stamp(point[0])} · ${money(point[1],svg.dataset.currency)}`;
}
function clearInspection(chart){chart.querySelectorAll('.chart-guide,.chart-dot,.chart-inspector').forEach(el=>el.remove());}

function metric(label,value,detail,cls='') { return `<article class="metric"><div class="label">${esc(label)}</div><div class="value ${cls}">${esc(value)}</div><div class="detail">${esc(detail)}</div></article>`; }
function render() {
  const s = state.summary;
  $('workspace-date').textContent=new Date().toLocaleDateString([], {weekday:'short',month:'short',day:'numeric',year:'numeric'});
  $('brand').textContent = state.app;
  $('portfolio-name').textContent = state.portfolioName;
  document.title = `${state.portfolioName} · ${state.app} Research`;
  $('portfolio-note').textContent = `${s.positions} priced positions · ${state.portfolios.length} portfolio${state.portfolios.length===1?'':'s'} in ${state.app} · Switch portfolios in the menu bar to follow along here.`;
  $('summary').innerHTML = metric('Live portfolio value',money(s.liveTotal),s.currencyComparable?`Cash ${money(s.cash)} · Includes available extended hours`:'Mixed quote currencies · total withheld') +
    metric('Regular-session move',signed(s.dayPL),pct(s.dayPercent),tone(s.dayPL)) +
    metric('Unrealized gain / loss',signed(s.unrealizedPL),`${pct(s.unrealizedPercent)} · ${s.missingCostCount ? `${s.missingCostCount} positions without cost basis` : 'On positions with cost basis'}`,tone(s.unrealizedPL)) +
    metric(valid(s.extendedPL)?s.extendedLabel:'Realized gain / loss',signed(s.currencyComparable?(valid(s.extendedPL)?s.extendedPL:s.realizedPL):null),valid(s.extendedPL)?'Since regular close · separate from session P/L':'From recorded sales in your ledger',tone(valid(s.extendedPL)?s.extendedPL:s.realizedPL));
  $('indices').innerHTML = state.indices.map(q=>`<span><b>${esc(q.symbol)}</b>${money(q.price)} <span class="${tone(q.change)}">${pct(q.change)}</span></span>`).join('');
  const holdings = state.quotes.filter(q=>q.quantity>0).sort((a,b)=>(b.value||0)-(a.value||0));
  $('allocation').innerHTML = holdings.slice(0,6).map(q=>`<div class="allocation-row"><strong>${esc(q.symbol)}</strong><svg viewBox="0 0 100 6" preserveAspectRatio="none"><rect width="100" height="6" rx="3" fill="#25303a"/><rect width="${Math.max(0,Math.min(100,q.weight||0))}" height="6" rx="3" fill="#d6b77b"/></svg><span>${valid(q.weight)?q.weight.toFixed(1)+'%':'—'}</span></div>`).join('') || empty('Add holdings in the menu bar to see your allocation.');
  const top = holdings[0], best = [...holdings].sort((a,b)=>(b.dayPL||0)-(a.dayPL||0))[0], worst = [...holdings].sort((a,b)=>(a.dayPL||0)-(b.dayPL||0))[0];
  const insights = [];
  if(top && s.currencyComparable) insights.push(`<strong>${esc(top.symbol)}</strong> is your largest priced position${valid(top.weight)?` at ${top.weight.toFixed(1)}%`:''}. A 1% move changes its value by approximately ${money((top.value||0)*.01,top.currency||'USD')}.`);
  if(s.currencyComparable && best && best.dayPL>0) insights.push(`<strong>${esc(best.symbol)}</strong> contributed ${signed(best.dayPL)} this session.`);
  if(s.currencyComparable && worst && worst.dayPL<0) insights.push(`<strong>${esc(worst.symbol)}</strong> detracted ${money(Math.abs(worst.dayPL))} this session.`);
  insights.push(s.currencyComparable?`Cash is ${s.liveTotal>0?(s.cash/s.liveTotal*100).toFixed(1):'0.0'}% of the priced portfolio. ${s.winners} positions up / ${s.losers} down.`:`${s.winners} positions up / ${s.losers} down. Cash and totals are withheld because currencies differ.`);
  $('insights').innerHTML = insights.map(i=>`<p>${i}</p>`).join('');
  renderHoldings(); renderPortfolioChart();
  const events=state.quotes.filter(q=>q.earnings).sort((a,b)=>a.earnings.date-b.earnings.date);
  $('earnings').innerHTML = events.map(q=>`<div class="event"><div><b>${esc(q.symbol)}</b><small>${q.quantity>0?'Held position':'Watchlist'} · EPS estimate ${esc(q.earnings.epsForecast)}</small></div><div>${esc(new Date(q.earnings.date*1000).toLocaleDateString([], {month:'short',day:'numeric'}))}<small>${esc(q.earnings.session)}</small></div></div>`).join('') || empty('No upcoming dates returned for this watchlist.');
  $('trades').innerHTML = state.trades.length ? `<table><thead><tr><th>Date</th><th>Symbol</th><th>Action</th><th>Quantity</th><th>Price</th><th>Notional</th></tr></thead><tbody>${state.trades.map(t=>`<tr><td>${esc(stamp(t.date))}</td><td>${esc(t.symbol)}</td><td>${esc(t.side)}</td><td>${num(t.quantity)}</td><td>${money(t.price)}</td><td>${money(t.quantity*t.price)}</td></tr>`).join('')}</tbody></table>` : empty('No trades recorded in this portfolio. Log buys and sells in the menu bar app.');
  if(!state.quotes.some(q=>q.symbol===selected)) { selected = holdings[0]?.symbol || state.quotes[0]?.symbol; loadResearch(); }
  renderSecurity();
}
function renderHoldings() {
  const filter = $('search').value.trim().toUpperCase();
  const quotes = [...state.quotes].filter(q=>q.symbol.includes(filter)).sort((a,b)=>Number(b.quantity>0)-Number(a.quantity>0)||(b.value||0)-(a.value||0));
  $('holdings').innerHTML = quotes.map(q=>`<tr class="${q.symbol===selected?'active':''}"><td><button class="symbol" data-symbol="${esc(q.symbol)}">${esc(q.symbol)}</button><small>${esc(q.kind)} · ${q.quantity>0?'Holding':'Watchlist'}</small></td><td>${money(q.price,q.currency)}<small>${esc(q.extendedLabel || q.session)} · ${esc(q.currency || 'USD')}</small><small>Received ${esc(stamp(q.receivedAt))}</small></td><td class="${tone(q.change)}">${pct(q.change)}</td><td>${q.quantity?num(q.quantity):'—'}</td><td>${money(q.value,q.currency)}</td><td>${valid(q.weight)?q.weight.toFixed(1)+'%':'—'}</td><td class="${tone(q.dayPL)}">${signed(q.dayPL,q.currency)}</td><td class="${tone(q.unrealizedPL)}">${signed(q.unrealizedPL,q.currency)}<small>${pct(q.unrealizedPercent)}</small></td><td><span class="mini-chart">${graph(q.sparkline.map((v,i)=>[i,v]),[],true)}</span></td></tr>`).join('') || '<tr><td colspan="9" class="empty">No matching symbols.</td></tr>';
}
function renderPortfolioChart() {
  if(!state.summary.currencyComparable){$('portfolio-chart').innerHTML=empty('Portfolio chart unavailable across different quote currencies.');$('chart-summary').textContent='Currency conversion needed';$('chart-note').textContent='Individual security charts remain available in their quote currencies.';return;}
  const cutoff=Date.now()/1000-(portfolioRange==='1W'?7:30)*86400;
  const points = portfolioRange==='1D'?state.intraday:state.history.filter(p=>portfolioRange==='ALL'||p[0]>=cutoff);
  const benchmark = portfolioRange==='1D' && $('benchmark').checked ? state.benchmark : [];
  $('benchmark').disabled=portfolioRange!=='1D';
  $('portfolio-chart').innerHTML=graph(points,benchmark);
  $('chart-summary').textContent=points.length>1?`${money(points.at(-1)[1])} · ${signed(points.at(-1)[1]-points[0][1])} over displayed observations`:'History is building';
  $('chart-note').textContent=portfolioRange==='1D'?'Intraday estimate using current holdings and minute bars. Gold: portfolio. Dashed blue: SPY rebased to the first portfolio value. Not a time-weighted investment return.':'Recorded portfolio values, including changes to holdings and cash. Up to 120 days retained by the app; this is not deposit-adjusted performance.';
}
function renderSecurity() {
  const q=state.quotes.find(q=>q.symbol===selected); if(!q) return;
  $('security-name').textContent=q.symbol;
  $('security-price').innerHTML=`<strong>${money(q.price,q.currency)}</strong> <span class="${tone(q.change)}">${pct(q.change)}</span>`;
  $('security-stats').innerHTML=stat('Previous close',money(q.previousClose,q.currency))+stat('Open',money(q.open,q.currency))+stat('Day low / high',`${money(q.dayLow,q.currency)} / ${money(q.dayHigh,q.currency)}`)+stat('52-week low / high',`${money(q.yearLow,q.currency)} / ${money(q.yearHigh,q.currency)}`)+stat('Volume',compact(q.volume))+stat('Market cap',compact(q.marketCap))+stat('P/E',num(q.pe))+stat('Your average cost',money(q.averageCost,q.currency));
  const symbol=encodeURIComponent(q.symbol);
  $('research-links').innerHTML=(q.kind==='stock'?[['https://finance.yahoo.com/quote/'+symbol+'/','Quote & profile'],['https://www.sec.gov/edgar/search/#/q='+symbol+'&dateRange=all','SEC filings'],['https://finance.yahoo.com/quote/'+symbol+'/analysis/','Analyst estimates'],['https://finance.yahoo.com/quote/'+symbol+'/holders/','Ownership']]:[['https://www.coingecko.com/','CoinGecko']]).map(([url,label])=>external(url,label)).join('');
  if(q.kind==='crypto') { $('security-chart').innerHTML=graph(q.sparkline.map((v,i)=>[i,v]),[],false,true,q.currency); $('security-chart-note').textContent='CoinGecko seven-day trend. Sample positions shown; exact point timestamps are not supplied by this feed.'; }
}
async function loadResearch() {
  lastResearchAt=Date.now();
  researchController?.abort(); chartController?.abort();
  const controller=new AbortController(); researchController=controller;
  const generation=++researchGeneration;
  financialData=null;
  $('analyst-content').innerHTML=empty('Loading analyst expectations…');
  $('financial-chart').innerHTML='';
  $('expectations-symbol').textContent=selected||'';
  $('financials').innerHTML=empty('Loading company filings…'); $('ratios').innerHTML='';
  $('news').innerHTML=empty('Loading headlines…');
  $('fundamentals-symbol').textContent=selected||''; $('news-symbol').textContent=selected?`· ${selected}`:'';
  $('financial-source').textContent='SEC-reported figures, with fiscal periods and filing dates.';
  const q=state?.quotes.find(q=>q.symbol===selected);
  if(!q || q.kind!=='stock') { $('analyst-content').innerHTML=empty('Analyst company estimates apply to equities.'); $('financials').innerHTML=empty('SEC company fundamentals apply to equities. Use the source links for crypto research.');$('news').innerHTML=empty('Company headlines are available for equities.');return; }
  loadSecurityChart();
  const query=`?symbol=${encodeURIComponent(selected)}`;
  const deadline=setTimeout(()=>controller.abort(),25000);
  await Promise.allSettled([
    api('expectations'+query,controller.signal).then(data=>{if(generation===researchGeneration)renderExpectations(data);}).catch(error=>{if(generation===researchGeneration)$('analyst-content').innerHTML=empty(`Analyst feed unavailable. ${error.message}`);}),
    api('research'+query,controller.signal).then(data=>{if(generation!==researchGeneration)return; financialData=data;renderFinancials();}).catch(error=>{if(generation===researchGeneration)$('financials').innerHTML=empty(`Company data unavailable. ${error.message}`);}),
    api('news'+query,controller.signal).then(data=>{if(generation!==researchGeneration)return;$('news').innerHTML=data.error?empty(data.error):(data.items||[]).map(item=>`<article class="headline">${external(item.link,item.title)}<small>${esc(item.source||'Yahoo Finance feed')} · ${esc(item.pubDate||'Publication time unavailable')}</small></article>`).join('')||empty('No headlines returned.');}).catch(error=>{if(generation===researchGeneration)$('news').innerHTML=empty(`Headlines unavailable. ${error.message}`);})
  ]);
  clearTimeout(deadline);
}
function renderFinancials() {
  const data=financialData;if(!data)return;
  if(data.error){$('financials').innerHTML=empty(data.error);return;}
  $('financial-source').textContent=`${data.company} · SEC EDGAR CIK ${data.cik} · Retrieved ${stamp(data.updatedAt)}. Reported periods may differ between metrics; compare the period labels. USD unless otherwise labeled.`;
  $('ratios').innerHTML=(data.ratios||[]).map(r=>`<div class="stat"><div class="label">${esc(r.label)}</div><div class="value" title="${esc(r.detail)}">${esc(r.display)}</div></div>`).join('');
  const metrics=data[financialPeriod]||[];
  const chosen=$('financial-metric').value;
  $('financial-metric').innerHTML=metrics.map(m=>`<option value="${esc(m.id)}">${esc(m.label)} · ${esc(m.unit)}</option>`).join('');
  if(metrics.some(m=>m.id===chosen))$('financial-metric').value=chosen;
  renderFinancialChart();
  $('financials').innerHTML=metrics.length?`<table><thead><tr><th>Reported metric</th><th>Previous</th><th>Previous</th><th>Previous</th><th>Latest reported</th></tr></thead><tbody>${metrics.map(m=>{const points=m.points.slice(-4);while(points.length<4)points.unshift(null);return `<tr><td class="financials-label">${esc(m.label)}<small>${esc(m.statement)} · ${esc(m.unit)}</small></td>${points.map(p=>`<td class="financial-value">${p?compact(p.value):'—'}<small>${p?esc(p.label):''}</small><small>${p?`Filed ${esc(p.filed)}`:''}</small></td>`).join('')}</tr>`;}).join('')}</tbody></table>`:empty('No reported metrics available for this period.');
}
async function loadSecurityChart(background=false) {
  chartController?.abort(); const controller=new AbortController(); chartController=controller;
  const generation=++chartGeneration, symbol=selected, range=$('security-range').value;
  lastChartAt=Date.now();
  if(state?.quotes.find(q=>q.symbol===symbol)?.kind!=='stock')return;
  if(!background)$('security-chart').innerHTML=empty('Loading price history…');
  $('security-chart-note').textContent='';
  try {
    const deadline=setTimeout(()=>controller.abort(),25000);
    let data;try{data=await api(`chart?symbol=${encodeURIComponent(symbol)}&range=${range}`,controller.signal);}finally{clearTimeout(deadline);}
    if(generation!==chartGeneration)return;
    $('security-chart').innerHTML=data.error?empty(data.error):graph(data.points,[],false,false,data.currency);
    $('security-chart-note').textContent=data.error?'Price history unavailable.':`Yahoo Finance · ${data.currency} · Retrieved ${stamp(data.updatedAt)} · ${range==='1D'?'One-minute bars, including extended hours':'Historical prices, not portfolio returns'}`;
    lastChartAt=Date.now();
  }catch(error){if(generation===chartGeneration)$('security-chart').innerHTML=empty(`Chart unavailable. ${error.message}`);}
}
async function sync() {
  if(loading || document.hidden)return;
  loading=true;
  try {
    const next=await api('snapshot'); if(next.error)throw new Error(next.error);
    const oldPortfolio=state?.portfolioID;state=next;
    const fingerprint=JSON.stringify([next.portfolioID,next.portfolioName,next.quotes,next.indices,next.summary,next.trades,next.intraday,next.history]);
    if(fingerprint!==lastFingerprint){lastFingerprint=fingerprint;render();if(oldPortfolio&&oldPortfolio!==next.portfolioID){renderSecurity();}}
    $('status').textContent=next.stale?`● ${next.status} · prices may be stale`:`● ${next.status}`;
    $('status').className=next.stale?'down':'up';
    $('updated').textContent=`Newest successful refresh ${stamp(next.updatedAt)}`;
    const warnings=[];
    if(next.failedSymbols?.length)warnings.push(`Refresh failed for ${next.failedSymbols.join(', ')}; last known prices shown.`);
    const foreign=next.quotes.filter(q=>q.quantity>0 && q.currency && q.currency!=='USD');
    if(foreign.length)warnings.push(`Currency limitation: ${foreign.map(q=>q.symbol+' '+q.currency).join(', ')}. The app does not convert FX; mixed-currency portfolio totals and weights are withheld.`);
    if(next.missingSymbols.length)warnings.push(`Missing prices for ${next.missingSymbols.join(', ')}. Totals cover priced positions only.`);
    if(next.backoffSeconds>0)warnings.push(`Provider rate limit: backing off for ${Math.ceil(next.backoffSeconds)} seconds.`);
    if(next.stale)warnings.push('Last known prices are retained. Check timestamps before relying on these values.');
    $('warning').hidden=!warnings.length;$('warning').textContent=warnings.join(' ');
    $('cadence').textContent=`App state sync: 1 second · Current app polling cadence: ${next.pollSeconds}s. Equities can poll every 2s in regular hours while this page is visible; extended hours ≥15s, closed equities ≥300s, crypto ≥10s. Providers may delay quotes; this is not an exchange streaming feed.`;
    if(selected && Date.now()-lastChartAt>60000 && $('security-range').value==='1D')loadSecurityChart(true);
    if(selected && Date.now()-lastResearchAt>300000)loadResearch();
  }catch(error){$('status').textContent='● Disconnected';$('status').className='down';$('warning').hidden=false;$('warning').textContent=`${error.message}. Last displayed values may be stale. Keep the app running, or reopen this page from its dropdown.`;}
  finally{loading=false;}
}
$('holdings').addEventListener('click',event=>{const button=event.target.closest('[data-symbol]');if(!button)return;selected=button.dataset.symbol;renderHoldings();renderSecurity();loadResearch();$('research').scrollIntoView({behavior:'smooth'});});
$('search').addEventListener('input',()=>state&&renderHoldings());
$('portfolio-ranges').addEventListener('click',event=>{const button=event.target.closest('[data-range]');if(!button||!state)return;portfolioRange=button.dataset.range;for(const b of $('portfolio-ranges').querySelectorAll('button'))b.classList.toggle('selected',b===button);renderPortfolioChart();});
$('benchmark').addEventListener('change',()=>state&&renderPortfolioChart());
$('security-range').addEventListener('change',()=>loadSecurityChart());
$('financial-period').addEventListener('click',event=>{const button=event.target.closest('[data-period]');if(!button)return;financialPeriod=button.dataset.period;for(const b of $('financial-period').querySelectorAll('button'))b.classList.toggle('selected',b===button);renderFinancials();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)sync();});
sync();setInterval(sync,1000);

for(const chart of document.querySelectorAll('.chart')) {
  chart.addEventListener('pointermove',event=>{const svg=chart.querySelector('svg[data-points]');if(!svg)return;const points=JSON.parse(svg.dataset.points),box=svg.getBoundingClientRect(),fraction=Math.max(0,Math.min(1,((event.clientX-box.left)/box.width*720-3)/653));const target=points[0][0]+fraction*(points.at(-1)[0]-points[0][0]);let index=0;for(let i=1;i<points.length;i++)if(Math.abs(points[i][0]-target)<Math.abs(points[index][0]-target))index=i;inspectChart(svg,index);});
  chart.addEventListener('pointerleave',()=>clearInspection(chart));
  chart.addEventListener('focusout',()=>clearInspection(chart));
  chart.addEventListener('keydown',event=>{const svg=event.target.closest('svg[data-points]');if(!svg||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;event.preventDefault();const count=JSON.parse(svg.dataset.points).length;let index=Number(svg.dataset.index??count-1);index=event.key==='Home'?0:event.key==='End'?count-1:index+(event.key==='ArrowRight'?1:-1);inspectChart(svg,index);});
}
const navLinks=[...document.querySelectorAll('nav a')];
const updateNavigation=()=>{let current='overview';for(const id of ['overview','positions','research','activity'])if($(id).getBoundingClientRect().top<window.innerHeight*.4)current=id;for(const link of navLinks){if(link.hash==='#'+current)link.setAttribute('aria-current','location');else link.removeAttribute('aria-current');}};
window.addEventListener('scroll',updateNavigation,{passive:true});

function renderFinancialChart(){
  const m=(financialData?.[financialPeriod]||[]).find(m=>m.id===$('financial-metric').value);
  if(!m){$('financial-chart').innerHTML=empty('Select a reported metric.');return;}
  $('financial-chart').innerHTML=estimateBars(m.points.slice(-10).map(p=>({label:p.label,value:p.value})),m.unit);
}
function estimateBars(rows,unit){
  const clean=rows.filter(r=>valid(r.value));
  if(!clean.length)return empty('No observations returned.');
  const low=Math.min(0,...clean.map(r=>valid(r.low)?Math.min(r.low,r.value):r.value)),high=Math.max(0,...clean.map(r=>valid(r.high)?Math.max(r.high,r.value):r.value)),span=high-low||1;
  const y=v=>24+(high-v)/span*170, width=720/clean.length;
  return `<svg viewBox="0 0 720 260" role="img" aria-label="${esc(unit+' observations; values and period labels shown below each bar')}"><line class="grid-line" x1="0" x2="720" y1="${y(0)}" y2="${y(0)}"/>${clean.map((r,i)=>{const x=width*(i+.5);return `<rect x="${x-width*.24}" y="${Math.min(y(0),y(r.value))}" width="${width*.48}" height="${Math.max(1,Math.abs(y(0)-y(r.value)))}" fill="${r.value<0?'#f08a8a':'#d6b77b'}" opacity=".75"/>${valid(r.low)&&valid(r.high)?`<path d="M${x},${y(r.low)}V${y(r.high)}M${x-5},${y(r.low)}h10M${x-5},${y(r.high)}h10" stroke="#e8eef6" fill="none"/>`:''}<text x="${x}" y="219" text-anchor="middle">${esc(compact(r.value))}</text><text x="${x}" y="243" text-anchor="middle">${esc(r.label)}</text>`;}).join('')}</svg>`;
}
function renderExpectations(data){
  const t=data.targets?.consensusOverview||{}, q=state?.quotes.find(q=>q.symbol===selected), current=q?.price;
  const upside=valid(t.priceTarget)&&valid(current)&&current>0&&q.currency==='USD'?(t.priceTarget/current-1)*100:null;
  const ratings=['buy','hold','sell'].filter(k=>valid(t[k]));
  const table=rows=>rows?.length?`<table><thead><tr><th>Fiscal end</th><th>Consensus EPS</th><th>Low / High</th><th>Analysts</th><th>4-week ↑ / ↓</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.fiscalEnd)}</td><td>${num(r.consensusEPSForecast)}</td><td>${num(r.lowEPSForecast)} / ${num(r.highEPSForecast)}</td><td>${num(r.noOfEstimates)}</td><td><span class="up">${num(r.up)}</span> / <span class="down">${num(r.down)}</span></td></tr>`).join('')}</tbody></table>`:empty('No EPS coverage returned.');
  const annual=data.eps?.yearlyForecast?.rows||[],quarterly=data.eps?.quarterlyForecast?.rows||[];
  $('analyst-content').innerHTML=`<div class="stat-grid">${stat('Low target · USD',money(t.lowPriceTarget))}${stat('Average target · USD',money(t.priceTarget))}${stat('High target · USD',money(t.highPriceTarget))}${stat('Implied upside to average',pct(upside))}</div><div class="analyst-ratings">${ratings.map(k=>`<span class="rating-${k}">${esc(k.toUpperCase())} <b>${num(t[k])}</b></span>`).join('')}</div><p class="footnote">Targets retrieved ${stamp(data.targetsRetrievedAt)}. Provider publication timestamp not supplied. Recommendation counts belong to the target feed; EPS coverage varies by period.</p><h3>Annual earnings expectations · USD/share</h3><p class="footnote">Gold bars: consensus EPS. White ranges: lowest to highest analyst estimate.</p><div class="chart small">${estimateBars(annual.map(r=>({label:r.fiscalEnd,value:r.consensusEPSForecast,low:r.lowEPSForecast,high:r.highEPSForecast})),'USD/share')}</div><div class="table-scroll">${table(annual)}</div><h3>Quarterly estimates & revisions</h3><div class="table-scroll">${table(quarterly)}</div><p class="footnote">Nasdaq analyst feeds · EPS retrieved ${stamp(data.epsRetrievedAt)} · Up/down revisions over the last four weeks. Estimates may use adjusted earnings and are not directly comparable to SEC GAAP EPS.</p>${(data.errors||[]).map(e=>empty(e)).join('')}`;
}
$('financial-metric').addEventListener('change',renderFinancialChart);

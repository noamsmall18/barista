'use strict';
// The desk composes provider views around durable research workflows.
const ResearchDesk = (() => {
  const M = ResearchModel;
  const pages = ['today','companies','compare','portfolio','theses'];
  let page = 'today', companyTab = 'overview', universeFilter = 'all';
  let modelDraft, modelSymbol, modelDirty = false, evidenceSymbol;
  const valuationDrafts=new Map(), studyPending=new Map(), studyAttempts=new Map();
  let compared = [], comparedData = new Map(), compareGeneration = 0, compareController;
  const noteFor = symbol => M.note(dirtyNotes.get(symbol) || workspace.notes?.[symbol]);
  const allNotes = () => ({...workspace.notes,...Object.fromEntries(dirtyNotes)});
  const id = () => window.crypto.randomUUID();
  const badge = stage => `<span class="stage-badge">${esc(M.stageLabels[stage])}</span>`;
  function setPage(next, writeHash=true) {
    if(!pages.includes(next)) next='today';
    page=next;
    for(const name of pages) $('page-'+name).hidden=name!==page;
    for(const link of document.querySelectorAll('nav [data-page]')) {
      if(link.dataset.page===page)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');
    }
    $('page-title').textContent=({today:'Today',companies:'Company desk',compare:'Comparison lab',portfolio:'Portfolio room',theses:'Thesis board'})[page];
    if(writeHash && location.hash!=='#'+page)history.pushState(null,'','#'+page);
    if(page==='compare')loadComparables();
    if(page==='theses')renderBoard();
  }
  function reveal(section) {
    const route={research:['companies','overview'],expectations:['companies','street'],fundamentals:['companies','financials'],notebook:['companies',companyTab],positions:['compare'],comparison:['compare'],overview:['portfolio'],exposure:['portfolio'],activity:['portfolio']};
    const [next,tab]=route[section]||[pages.includes(section)?section:'today'];
    setPage(next);if(tab)setCompanyTab(tab);
    window.scrollTo({top:0,behavior:reducedMotion()?'auto':'smooth'});
  }
  function setCompanyTab(tab) {
    const names=['overview','financials','street','valuation','news'];
    if(!names.includes(tab))return;
    companyTab=tab;
    for(const name of names){$('company-'+name).hidden=name!==tab;const button=$('tab-'+name);button.setAttribute('aria-selected',String(name===tab));button.tabIndex=name===tab?0:-1;}
    if(tab==='valuation')renderValuation();
  }
  function updateNote(symbol, transform) {
    if(!workspaceReady || !symbol){toast('Research storage unavailable. Refresh to reconnect.');return false;}
    const next=transform(noteFor(symbol));
    dirtyNotes.set(symbol,next);keepDrafts();
    if(symbol===selected)$('note-status').textContent='Unsaved changes · autosaving…';
    clearTimeout(noteTimer);noteTimer=setTimeout(drainNotes,600);notesChanged();return true;
  }
  function renderUniverse() {
    if(!state)return;
    const query=$('universe-search').value.trim().toUpperCase();
    const quotes=A.sortedQuotes(researchQuotes(),{search:query,filter:universeFilter,sort:'symbol',direction:'asc',favorites});
    const active=document.activeElement?.dataset?.universeSymbol;
    $('universe-list').innerHTML=quotes.map(q=>{
      const n=noteFor(q.symbol);
      return `<button class="universe-item ${q.symbol===selected?'active':''}" data-open-symbol="${esc(q.symbol)}" data-universe-symbol="${esc(q.symbol)}" ${q.symbol===selected?'aria-current="true"':''}><b>${esc(q.symbol)}${favorites.includes(q.symbol)?' · ★':''}</b><span class="price">${money(q.price,q.currency)}</span><small>${q.quantity>0?'Held position':q.researchOnly?'Research universe':'Watchlist'}</small><span class="move ${tone(q.change)}">${pct(q.change)}</span>${n.stage!=='inbox'?badge(n.stage):''}</button>`;
    }).join('')||empty('No companies match this filter.');
    if(active)for(const b of $('universe-list').querySelectorAll('button'))if(b.dataset.universeSymbol===active)b.focus({preventScroll:true});
  }
  function renderToday() {
    if(!state)return;
    const notes=allNotes(),rows=M.board(researchQuotes(),notes),agenda=M.agenda(researchQuotes(),notes);
    const questions=rows.flatMap(({quote:q,note:n})=>n.stage==='archived'?[]:n.questions.filter(t=>!t.done).map(t=>({...t,symbol:q.symbol})));
    const working=rows.filter(({note:n})=>n.stage==='researching'||n.stage==='ready').length;
    const count=(value,label)=>`<div class="today-counter"><strong>${value}</strong><span>${label}</span></div>`;
    $('today-counters').innerHTML=count(researchQuotes().length,'Companies in your universe')+count(working,'Theses in progress')+count(questions.length,'Open research questions')+count(rows.reduce((sum,{note:n})=>sum+n.evidence.length,0),'Pieces of evidence kept');
    const date=new Date();$('edition-date').innerHTML=`${esc(date.toLocaleDateString([],{weekday:'long'}))}<strong>${date.getDate()}</strong><span>${esc(date.toLocaleDateString([],{month:'long',year:'numeric'}))}</span>`;
    const priorities=agenda.slice(0,5);
    $('research-agenda').innerHTML=priorities.length?priorities.map((r,i)=>`<article class="agenda-row"><span class="agenda-number">0${i+1}</span><div><h3>${esc(r.title)}</h3><p>${esc(r.detail)}</p></div><button data-open-symbol="${esc(r.symbol)}">Open ↗</button></article>`).join(''):
      `<article class="agenda-row"><span class="agenda-number">01</span><div><h3>Choose a company. Start with a question.</h3><p>Open its dossier, write your thesis, and keep the evidence that could change your mind.</p></div><button data-page="companies">Begin ↗</button></article><article class="agenda-row"><span class="agenda-number">02</span><div><h3>Look for differences that matter.</h3><p>Compare the underlying businesses alongside their price histories.</p></div><button data-page="compare">Compare ↗</button></article>`;
    const q=quoteFor(selected)||state.quotes[0],n=q?noteFor(q.symbol):null;
    $('resume-research').innerHTML=q?`<div class="resume-symbol">${esc(q.symbol)}</div>${badge(n.stage)}<p>${esc(n.thesis.slice(0,220)||'A price is only the beginning. Build the case, name the risks, and decide what to investigate next.')}</p><button class="button" data-open-symbol="${esc(q.symbol)}">Continue researching ${esc(q.symbol)} ↗</button>`:`<h2>Build your research universe.</h2><p>Add a holding or watchlist symbol in the Marketbar menu. Your research starts here.</p>`;
    const events=state.quotes.filter(q=>q.earnings).sort((a,b)=>a.earnings.date-b.earnings.date).slice(0,4);
    $('today-events').innerHTML=events.map(q=>`<div class="resume-event"><button data-open-symbol="${esc(q.symbol)}">${esc(q.symbol)}</button><span>${esc(new Date(q.earnings.date*1000).toLocaleDateString([],{month:'short',day:'numeric'}))} · ${esc(q.earnings.session||'Unspecified')}</span></div>`).join('')||'<p>No earnings dates returned for your universe. Coverage can be incomplete.</p>';
    $('today-tasks').innerHTML=questions.slice(0,6).map(t=>`<div class="task-row"><input type="checkbox" data-task-symbol="${esc(t.symbol)}" data-task-id="${esc(t.id)}" id="today-task-${esc(t.id)}"><label for="today-task-${esc(t.id)}">${esc(t.text)}<small>${esc(t.symbol)} · Open research question</small></label><button class="text-link" data-open-symbol="${esc(t.symbol)}">Open ↗</button></div>`).join('')||empty('Keep a question in any company’s notebook. It will appear here until you answer it.');
    const recent=Object.entries(notes).filter(([,n])=>n.thesis||n.risks||n.catalysts||n.evidence?.length||n.questions?.length).sort((a,b)=>(b[1].updatedAt||0)-(a[1].updatedAt||0)).slice(0,4);
    $('recent-research').innerHTML=recent.map(([symbol,raw])=>{const n=M.note(raw);return `<article class="recent-row"><button data-open-research="${esc(symbol)}">${esc(symbol)}</button>${badge(n.stage)}<p>${esc(n.thesis||n.catalysts||n.evidence[0]?.text||'Research questions recorded.')}</p></article>`;}).join('')||empty('Your research trail will grow here. Notes and evidence survive app restarts.');
  }
  function renderBoard() {
    if(!state)return;
    const archived=$('board-archived').checked;
    const rows=M.board(researchQuotes(),allNotes(),$('board-search').value,archived);
    const stages=archived?M.stages:M.stages.filter(s=>s!=='archived');
    $('board-count').textContent=`${rows.length} companies · stages are your research process`;
    $('thesis-board').innerHTML=stages.map(stage=>{
      const cards=rows.filter(r=>r.note.stage===stage);
      return `<section class="board-column"><h2>${esc(M.stageLabels[stage])}<span>${cards.length}</span></h2>${cards.map(({quote:q,note:n})=>`<article class="thesis-card"><div class="thesis-card-head"><button data-open-research="${esc(q.symbol)}">${esc(q.symbol)}</button><span class="conviction ${esc(n.conviction)}">${esc(n.conviction)}</span></div><p>${esc(n.thesis||'No thesis yet. Open the company to capture your reasoning.')}</p><div class="card-evidence"><span>${n.evidence.length} evidence</span><span>${n.questions.filter(t=>!t.done).length} open questions</span></div>${n.reviewDate?`<div class="card-review ${M.due(n.reviewDate)?'overdue':''}">Review ${esc(n.reviewDate)}${M.due(n.reviewDate)?' · due':''}</div>`:''}<label class="sr-only" for="stage-${esc(q.symbol)}">Research stage for ${esc(q.symbol)}</label><select id="stage-${esc(q.symbol)}" data-board-symbol="${esc(q.symbol)}">${M.stages.map(s=>`<option value="${s}" ${s===stage?'selected':''}>${esc(M.stageLabels[s])}</option>`).join('')}</select></article>`).join('')||'<div class="empty">No companies at this stage.</div>'}</section>`;
    }).join('');
    $('thesis-board').classList.toggle('with-archive',archived);
  }
  function renderEvidence() {
    const n=noteFor(selected),ready=!!selected&&workspaceReady;
    $('add-evidence').disabled=!ready;$('question-text').disabled=!ready;
    $('evidence-count').textContent=n.evidence.length?String(n.evidence.length):'';
    $('evidence-list').innerHTML=n.evidence.map(e=>`<article class="evidence-item"><span class="evidence-kind ${esc(e.kind)}">${esc(e.kind==='question'?'Question':e.kind)}</span><p>${esc(e.text)}</p><div class="evidence-meta"><span>${e.url?external(e.url,e.source||'Source'):esc(e.source||'Personal observation')}</span><button data-remove-evidence="${esc(e.id)}" aria-label="Remove evidence: ${esc(e.text.slice(0,45))}">×</button></div></article>`).join('')||empty('Keep a headline, a reported number, or your own observation. Separate support from challenges.');
    $('question-count').textContent=`${n.questions.filter(q=>!q.done).length} open`;
    $('question-list').innerHTML=n.questions.map(t=>`<div class="task-row ${t.done?'done':''}"><input type="checkbox" id="question-${esc(t.id)}" data-task-symbol="${esc(selected)}" data-task-id="${esc(t.id)}" ${t.done?'checked':''}><label for="question-${esc(t.id)}">${esc(t.text)}</label><button class="remove" data-remove-question="${esc(t.id)}" aria-label="Remove question: ${esc(t.text.slice(0,45))}">×</button></div>`).join('');
  }
  function renderMetadata() {
    const n=noteFor(selected);
    $('thesis-stage').value=n.stage;$('thesis-conviction').value=n.conviction;$('thesis-review').value=n.reviewDate;
    for(const field of ['stage','conviction','review'])$('thesis-'+field).disabled=!selected||!workspaceReady;
  }
  function notesChanged() {renderToday();renderBoard();renderUniverse();renderEvidence();renderMetadata();}
  function render() {
    renderToday();renderUniverse();renderBoard();
    $('company-breadcrumb').textContent=selected?`Universe / ${selected}`:'Company dossier';
    $('remove-study').hidden=!quoteFor(selected)?.researchOnly;
    if(state)$('portfolio-context').textContent=`${state.portfolioName} · totals cover priced holdings and recorded cash.`;
  }
  function selectedChanged() {
    renderMetadata();renderEvidence();renderUniverse();renderToday();
    $('company-breadcrumb').textContent=selected?`Universe / ${selected}`:'Company dossier';
    $('remove-study').hidden=!quoteFor(selected)?.researchOnly;
    modelDraft=valuationDrafts.get(selected)||noteFor(selected).valuation;modelSymbol=selected;modelDirty=valuationDrafts.has(selected);
    renderValuation(true);renderSynthesis();
  }
  function loaded() {renderMetadata();renderEvidence();render();restoreStudy();}
  function renderSynthesis() {
    const q=quoteFor(selected);
    if(!q){$('dossier-synthesis').innerHTML=empty('Choose a company to begin.');return;}
    const revenue=M.latestMetric(financialData,'revenue'), cash=M.latestMetric(financialData,'free_cash_flow');
    const revenueMetric=financialData?.annual?.find(m=>m.id==='revenue'),change=A.financialChange(revenueMetric);
    const target=expectationsData?.targets?.consensusOverview?.priceTarget;
    const targetGap=q.currency==='USD'&&valid(target)&&q.price>0?(target/q.price-1)*100:null;
    const observed=revenue?`Latest revenue: ${compact(revenue.value)} ${revenue.unit} (${revenue.label}). ${change?.percent!==null&&change?`${pct(change.percent)} vs the previous reported period.`:''}`:'Reported revenue coverage is pending or unavailable.';
    const generation=cash?`Free cash flow: ${compact(cash.value)} ${cash.unit} (${cash.label}). Check the filing and period before comparing.`:'Free cash flow coverage is pending or unavailable.';
    $('dossier-synthesis').innerHTML=`<div class="eyebrow">THREE LENSES / ONE BUSINESS</div><h2>Start with the right questions.</h2><div class="synthesis-grid"><div><h3>Is the business progressing?</h3><p>${esc(observed)}</p><button class="text-link" data-tab="financials">Read the financials ↗</button></div><div><h3>Does it turn earnings into cash?</h3><p>${esc(generation)}</p><button class="text-link" data-tab="financials">Investigate cash generation ↗</button></div><div><h3>What is already expected?</h3><p>${valid(targetGap)?`${esc(pct(targetGap))} to the average analyst target. An opinion to examine, not an outcome to assume.`:'Compare your assumptions with the available analyst estimates.'}</p><button class="text-link" data-tab="valuation">Build your own range ↗</button></div></div>`;
  }
  function defaultsModel() {return {eps:null,years:3,basis:'Manual EPS input',bear:{growth:-5,multiple:15},base:{growth:8,multiple:22},bull:{growth:15,multiple:30}};}
  function renderValuation(reset=false) {
    if(modelSymbol!==selected){modelDraft=valuationDrafts.get(selected)||noteFor(selected).valuation;modelSymbol=selected;modelDirty=valuationDrafts.has(selected);reset=true;}
    if(!modelDraft)modelDraft=defaultsModel();
    if(reset||!$('valuation-assumptions').children.length){
      $('valuation-eps').value=modelDraft.eps??'';$('valuation-years').value=String(modelDraft.years);
      $('valuation-assumptions').innerHTML=`<div class="valuation-scenarios">${['bear','base','bull'].map(name=>`<section class="valuation-case ${name}"><h3>${name[0].toUpperCase()+name.slice(1)} case</h3><label>Annual EPS growth %<input type="number" data-model-case="${name}" data-model-field="growth" min="-90" max="200" step="1" value="${modelDraft[name].growth}"></label><label>Terminal P/E multiple<input type="number" data-model-case="${name}" data-model-field="multiple" min="0" max="200" step="1" value="${modelDraft[name].multiple}"></label></section>`).join('')}</div>`;
    }
    const rows=expectationsData?.eps?.yearlyForecast?.rows||[],next=rows.find(r=>valid(r.consensusEPSForecast)&&r.consensusEPSForecast>=0);
    const q=quoteFor(selected),available=q?.kind==='stock'&&q.currency==='USD';
    $('use-consensus').disabled=!available||!next;
    $('save-valuation').disabled=!available||!workspaceReady||!M.valuation(modelDraft,q);
    $('valuation-source').textContent=!available?'This EPS model requires a USD equity quote. Other quote currencies and crypto cannot use this model.':
      `${modelDraft.basis || 'Manual EPS input'}. ${next?`First available annual consensus: ${next.fiscalEnd}, ${num(next.consensusEPSForecast)} USD/share. Retrieved ${stamp(expectationsData.epsRetrievedAt)}.`:'Annual consensus coverage pending or unavailable. Enter your own EPS basis.'} Starter growth and multiples are editable placeholders, not recommendations.${modelDirty?' Assumptions have unsaved edits.':''}`;
    const results=M.valuation(modelDraft,q);
    $('valuation-results').innerHTML=results?`<div class="valuation-results">${results.map(r=>`<div class="valuation-result"><span>${r.name.toUpperCase()} / ${modelDraft.years}Y TERMINAL</span><strong>${money(r.price)}</strong><span class="${tone(r.upside)}">${pct(r.upside)} vs quote</span><small>Terminal EPS ${money(r.eps)}</small></div>`).join('')}</div>`:empty('Enter a nonnegative annual EPS basis. Growth must be −90% to 200%; P/E must be 0 to 200.');
    const matrix=M.sensitivity(modelDraft,q);
    $('valuation-matrix').innerHTML=matrix?`<table class="sensitivity"><thead><tr><th>EPS growth / P/E</th>${matrix.multiples.map(m=>`<th>${num(m)}×</th>`).join('')}</tr></thead><tbody>${matrix.growth.map((g,i)=>`<tr><td>${pct(g)}</td>${matrix.cells[i].map(c=>`<td class="${c.base?'base-cell':''}">${money(c.price)}<small>${pct((c.price/q.price-1)*100)} vs quote</small></td>`).join('')}</tr>`).join('')}</tbody></table>`:'';
  }
  function readNumber(input) {const raw=input.value.trim();return raw===''?null:Number(raw);}
  function editModel(event) {
    modelDraft.eps=readNumber($('valuation-eps'));modelDraft.years=Number($('valuation-years').value);
    if(event.target.id==='valuation-eps')modelDraft.basis='Manual EPS input';
    for(const input of $('valuation-assumptions').querySelectorAll('input'))modelDraft[input.dataset.modelCase][input.dataset.modelField]=readNumber(input);
    modelDirty=true;valuationDrafts.set(selected,structuredClone(modelDraft));renderValuation();
  }
  function openEvidence(seed={}) {
    if(!selected||!workspaceReady){toast('Select a company and connect research storage first.');return;}
    evidenceSymbol=selected;$('evidence-symbol').textContent=`Keeping evidence for ${selected}`;
    $('evidence-text').value=String(seed.text||'').slice(0,2000);$('evidence-source').value=String(seed.source||'').slice(0,200);$('evidence-url').value=String(seed.url||'').slice(0,2000);$('evidence-kind').value=seed.kind||'supports';$('evidence-error').textContent='';
    $('evidence-dialog').showModal();$('evidence-text').focus();
  }
  function researchChanged() {
    renderSynthesis();renderValuation();
    // Provider material becomes evidence only when the user explicitly keeps it.
    for(const [i,article] of [...$('news').querySelectorAll('.headline')].entries()) {
      if(article.querySelector('[data-capture-news]'))continue;
      const button=document.createElement('button');button.className='text-link';button.dataset.captureNews=String(i);button.textContent='+ Keep in evidence file';article.append(button);
    }
    for(const row of $('financials').querySelectorAll('tbody tr')) {
      if(row.querySelector('[data-capture-metric]'))continue;
      const index=[...row.parentElement.children].indexOf(row),metric=(financialData?.[financialPeriod]||[])[index];if(!metric)continue;
      const button=document.createElement('button');button.className='text-link';button.dataset.captureMetric=metric.id;button.textContent='+ Keep evidence';row.firstElementChild.append(document.createElement('br'),button);
    }
  }
  function openSaved(symbol) {
    if(quoteFor(symbol)){selectSecurity(symbol);return;}
    addCompany(symbol);
  }
  async function fetchStudy(symbol, refresh=false) {
    if(studyPending.has(symbol))return studyPending.get(symbol);
    if(!refresh&&studyQuotes.get(symbol)?.price>0)return studyQuotes.get(symbol);
    studyAttempts.set(symbol,Date.now());
    const promise=api(`study-quote?symbol=${encodeURIComponent(symbol)}`).then(data=>{
      if(data.error||data.symbol!==symbol||!valid(data.price)||data.price<=0)throw new Error(data.error||'No observed price returned.');
      studyQuotes.set(symbol,{...data,researchOnly:true,quantity:0});
      render();renderHoldings();renderPinned();if(selected===symbol)renderSecurity();return data;
    }).finally(()=>studyPending.delete(symbol));
    studyPending.set(symbol,promise);return promise;
  }
  async function restoreStudy() {
    for(const symbol of researchSymbols)if(!quoteFor(symbol))studyQuotes.set(symbol,{symbol,kind:'stock',currency:'USD',price:null,change:null,quantity:0,researchOnly:true,session:'Loading coverage',sparkline:[]});
    render();
    for(const symbol of researchSymbols){
      if(state?.quotes.some(q=>q.symbol===symbol))continue;
      try{await fetchStudy(symbol);}catch{const q=studyQuotes.get(symbol);if(q){q.session='Coverage unavailable';}renderUniverse();}
    }
  }
  async function addCompany(raw) {
    const symbol=String(raw||'').trim().toUpperCase();
    if(!/^[A-Z0-9^][A-Z0-9.^=-]{0,29}$/.test(symbol)){ $('add-company-error').textContent='Enter an exact ticker, such as COST or BRK-B.';return; }
    if(quoteFor(symbol)&&(!quoteFor(symbol).researchOnly||quoteFor(symbol).price>0)){selectSecurity(symbol);$('company-dialog').close();return;}
    if(!workspaceReady){$('add-company-error').textContent='Research storage is unavailable. Refresh to reconnect.';return;}
    if(!researchSymbols.includes(symbol)&&researchSymbols.length>=100){$('add-company-error').textContent='The research universe can hold up to 100 additional tickers.';return;}
    $('add-company-submit').disabled=true;$('add-company-error').textContent='Reading observed market data…';
    try {
      await fetchStudy(symbol,true);
      if(!researchSymbols.includes(symbol))researchSymbols.push(symbol);
      savePreferences();selectSecurity(symbol);$('company-dialog').close();if($('command-dialog').open)$('command-dialog').close();
      toast(`${symbol} added to research. Portfolio holdings unchanged.`);
    }catch(error){$('add-company-error').textContent=error.message;toast(`Could not open ${symbol}. Check the ticker or retry.`);}
    finally{$('add-company-submit').disabled=false;}
  }
  function poll() {
    const q=studyQuotes.get(selected);
    if(q && !studyPending.has(selected) && Date.now()-(studyAttempts.get(selected)||0)>60000 && Date.now()/1000-(q.receivedAt||0)>60)fetchStudy(selected,true).catch(()=>{});
  }
  function refreshStudy() {if(studyQuotes.has(selected))fetchStudy(selected,true).catch(error=>toast(error.message));}
  async function loadComparables(force=false) {
    const symbols=[...compareSymbols];
    if(!force&&JSON.stringify(symbols)===JSON.stringify(compared))return;
    compared=symbols;comparedData.clear();$('export-comparison').disabled=true;compareController?.abort();compareController=new AbortController();const signal=compareController.signal,generation=++compareGeneration;
    if(symbols.length<2){comparedData.clear();$('comparison-fundamentals').innerHTML=empty('Select two or more equities above to compare their reported businesses.');return;}
    $('comparison-fundamentals').innerHTML=pending('Reading company filings for the selected equities…');
    const results=await Promise.allSettled(symbols.map(symbol=>api(`research?symbol=${encodeURIComponent(symbol)}`,signal)));
    if(generation!==compareGeneration)return;
    comparedData=new Map(results.map((r,i)=>[symbols[i],r.status==='fulfilled'?r.value:{error:r.reason.message}]));renderComparables();
  }
  const comparisonMetrics=[['revenue','Revenue'],['net_income','Net income'],['operating_cash_flow','Operating cash flow'],['free_cash_flow','Free cash flow'],['cash','Cash & equivalents'],['assets','Total assets']];
  function renderComparables() {
    $('export-comparison').disabled=false;
    const symbols=compared;
    const quoteRows=[['Last price',q=>money(q?.price,q?.currency)],['Live move',q=>pct(q?.change)],['Market cap',q=>valid(q?.marketCap)?`${compact(q.marketCap)} ${q.currency||'USD'}`:'—'],['Trailing P/E',q=>num(q?.pe)],['Held weight',q=>valid(q?.weight)?q.weight.toFixed(1)+'%':'Watchlist / unavailable']];
    const reportCell=(symbol,id)=>{const d=comparedData.get(symbol),m=M.latestMetric(d,id);return d?.error?`<td>Unavailable<small>${esc(d.error)}</small></td>`:m?`<td>${compact(m.value)} ${esc(m.unit)}<small>${esc(m.label)} · ${esc(m.form||'Reported')}</small><small>Filed ${esc(m.filed||'Unavailable')}</small></td>`:'<td>—<small>Metric not returned</small></td>';};
    $('comparison-fundamentals').innerHTML=`<p class="footnote">Latest annual observations from SEC EDGAR. Fiscal periods and units are shown in each cell; these are not synchronized reporting periods. No currency conversion or missing-value ranking is performed.</p><div class="table-scroll"><table class="comparison-table"><thead><tr><th>Company lens</th>${symbols.map(s=>`<th><button data-open-symbol="${esc(s)}">${esc(s)} ↗</button><small>${esc(comparedData.get(s)?.company||'Company feed unavailable')}</small></th>`).join('')}</tr></thead><tbody>${quoteRows.map(([label,fn])=>`<tr><td>${label}</td>${symbols.map(s=>`<td>${esc(fn(quoteFor(s)))}</td>`).join('')}</tr>`).join('')}<tr class="metric-section"><td colspan="${symbols.length+1}">LATEST ANNUAL REPORTED METRICS</td></tr>${comparisonMetrics.map(([id,label])=>`<tr><td>${label}</td>${symbols.map(s=>reportCell(s,id)).join('')}</tr>`).join('')}</tbody></table></div>`;
  }
  function exportComparison() {
    if(compared.length<2 || !comparedData.size){toast('Select equities and load company metrics first.');return;}
    const rows=[['Symbol','Metric','Value','Unit','Fiscal period','Filed','Source']];
    for(const symbol of compared)for(const [id,label]of comparisonMetrics){const m=M.latestMetric(comparedData.get(symbol),id);rows.push([symbol,label,m?.value,m?.unit,m?.label,m?.filed,'SEC EDGAR']);}
    download('marketbar-company-comparison.csv',A.csv(rows));
  }
  function memo(symbol) {
    const n=noteFor(symbol),q=quoteFor(symbol),v=n.valuation,lines=[`# ${symbol} — Marketbar research memo`,'',`Exported ${new Date().toLocaleString()}`,`Research stage: ${M.stageLabels[n.stage]} · Conviction: ${n.conviction}`,`Next review: ${n.reviewDate||'Not set'}`,'','## Thesis',n.thesis||'Not written.','','## Risks & invalidation',n.risks||'Not written.','','## Catalysts & next questions',n.catalysts||'Not written.','','## Evidence file',...n.evidence.flatMap(e=>[`- [${e.kind}] ${e.text}`,`  Source: ${e.source||'Personal observation'}${e.url?' — '+e.url:''}`]),'','## Research questions',...n.questions.map(t=>`- [${t.done?'x':' '}] ${t.text}`)];
    if(v){lines.push('','## Valuation assumptions',`Basis: ${v.basis} · EPS ${v.eps} USD/share · Horizon ${v.years} years`,...['bear','base','bull'].map(k=>`- ${k}: EPS growth ${v[k].growth}% annually; terminal P/E ${v[k].multiple}×`));const results=M.valuation(v,q);if(results)lines.push(...results.map(r=>`- ${r.name} illustrative terminal price: ${money(r.price)} (${pct(r.upside)} vs current quote)`));lines.push('Excludes dividends, dilution and discounting. User assumptions, not forecasts.');}
    if(symbol===selected&&financialData&&!financialData.error){lines.push('','## Reported business context',`SEC EDGAR · ${financialData.company} · CIK ${financialData.cik} · Retrieved ${stamp(financialData.updatedAt)}`);for(const [id,label] of comparisonMetrics){const m=M.latestMetric(financialData,id);if(m)lines.push(`- ${label}: ${num(m.value)} ${m.unit} (${m.label}, filed ${m.filed})`);}}
    if(q)lines.push('','## Quote context',`${money(q.price,q.currency)} · ${pct(q.change)} live move · Received ${stamp(q.receivedAt)}`);
    lines.push('','Research annotations are separate from portfolio holdings and recorded trades. Public data can be delayed or incomplete.');return lines.join('\n');
  }
  function exportMemo() {if(!selected){toast('Choose a company first.');return;}download(filename(selected)+'-research-memo.md',memo(selected),'text/markdown;charset=utf-8');toast('Research memo exported, including unsaved drafts.');}
  // Routes and company tabs are independently keyboard navigable.
  document.addEventListener('click',event=>{
    const route=event.target.closest('[data-page]');if(route){event.preventDefault();setPage(route.dataset.page);window.scrollTo({top:0,behavior:'auto'});}
    const tab=event.target.closest('[data-company-tab],[data-tab]');if(tab)setCompanyTab(tab.dataset.companyTab||tab.dataset.tab);
    const saved=event.target.closest('[data-open-research]');if(saved)openSaved(saved.dataset.openResearch);
    const news=event.target.closest('[data-capture-news]');if(news){const item=newsData?.items?.[Number(news.dataset.captureNews)];if(item)openEvidence({text:item.title,source:item.source||'Yahoo Finance',url:item.link});}
    const metricButton=event.target.closest('[data-capture-metric]');if(metricButton){const m=(financialData?.[financialPeriod]||[]).find(m=>m.id===metricButton.dataset.captureMetric),p=m?.points.at(-1);if(p)openEvidence({text:`${m.label}: ${num(p.value)} ${m.unit}, ${p.label}. Filed ${p.filed}.`,source:`SEC EDGAR · ${financialData.company}`,url:'https://www.sec.gov/edgar/browse/?CIK='+encodeURIComponent(financialData.cik)});}
    const removal=event.target.closest('[data-remove-evidence],[data-remove-question]');if(removal){const key=removal.dataset.removeEvidence?'evidence':'questions',item=removal.dataset.removeEvidence||removal.dataset.removeQuestion;updateNote(selected,n=>({...n,[key]:n[key].filter(e=>e.id!==item)}));}
  });
  document.addEventListener('change',event=>{
    const task=event.target.closest('[data-task-id]');if(task)updateNote(task.dataset.taskSymbol,n=>({...n,questions:n.questions.map(t=>t.id===task.dataset.taskId?{...t,done:task.checked}:t)}));
    const stage=event.target.closest('[data-board-symbol]');if(stage)updateNote(stage.dataset.boardSymbol,n=>({...n,stage:stage.value}));
  });
  $('company-overview').parentElement.querySelector('.company-tabs').addEventListener('keydown',event=>{
    const tab=event.target.closest('[data-company-tab]');if(!tab||!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
    event.preventDefault();const buttons=[...document.querySelectorAll('[data-company-tab]')],i=buttons.indexOf(tab),next=event.key==='Home'?0:event.key==='End'?buttons.length-1:(i+(event.key==='ArrowRight'?1:-1)+buttons.length)%buttons.length;setCompanyTab(buttons[next].dataset.companyTab);buttons[next].focus();
  });
  document.addEventListener('keydown',event=>{
    if(event.altKey&&!event.ctrlKey&&!event.metaKey && /^[1-5]$/.test(event.key)){event.preventDefault();setPage(pages[Number(event.key)-1]);}
  });
  window.addEventListener('beforeunload',event=>{if(valuationDrafts.size){event.preventDefault();event.returnValue='';}});
  window.addEventListener('hashchange',()=>setPage(location.hash.slice(1),false));
  $('universe-search').addEventListener('input',renderUniverse);
  $('open-add-company').addEventListener('click',()=>{$('add-company-symbol').value='';$('add-company-error').textContent='';$('company-dialog').showModal();$('add-company-symbol').focus();});
  $('remove-study').addEventListener('click',()=>{if(!quoteFor(selected)?.researchOnly)return;const symbol=selected;researchSymbols=researchSymbols.filter(s=>s!==symbol);studyQuotes.delete(symbol);compareSymbols=compareSymbols.filter(s=>s!==symbol);selectSecurity(researchQuotes()[0]?.symbol,false);savePreferences();render();renderComparison();loadComparables();toast(`${symbol} removed from the research universe. Saved research retained on the thesis board.`);});
  $('close-add-company').addEventListener('click',()=>$('company-dialog').close());
  $('add-company-form').addEventListener('submit',event=>{event.preventDefault();addCompany($('add-company-symbol').value);});
  $('command-search').addEventListener('input',()=>{const symbol=$('command-search').value.trim().toUpperCase();$('command-add').hidden=!/^[A-Z0-9^][A-Z0-9.^=-]{0,29}$/.test(symbol)||!!quoteFor(symbol);$('command-add').textContent=`Research ${symbol} outside this portfolio ↗`;});
  $('command-add').addEventListener('click',()=>addCompany($('command-search').value));
  $('universe-filter').addEventListener('click',event=>{const button=event.target.closest('[data-universe]');if(!button)return;universeFilter=button.dataset.universe;chooseSegment('universe-filter',universeFilter,'universe');renderUniverse();});
  for(const [field,key]of [['stage','stage'],['conviction','conviction'],['review','reviewDate']])$('thesis-'+field).addEventListener('change',()=>updateNote(selected,n=>({...n,[key]:$('thesis-'+field).value})));
  $('board-search').addEventListener('input',renderBoard);$('board-archived').addEventListener('change',renderBoard);
  $('question-form').addEventListener('submit',event=>{event.preventDefault();const text=$('question-text').value.trim();if(!text)return;if(noteFor(selected).questions.length>=100){toast('Keep at most 100 questions per company.');return;}if(updateNote(selected,n=>({...n,questions:[...n.questions,{id:id(),text,done:false,createdAt:Date.now()/1000}]})))$('question-text').value='';});
  $('add-evidence').addEventListener('click',()=>openEvidence());$('close-evidence').addEventListener('click',()=>$('evidence-dialog').close());
  $('evidence-form').addEventListener('submit',event=>{
    event.preventDefault();const text=$('evidence-text').value.trim(),url=$('evidence-url').value.trim();
    if(!text){$('evidence-error').textContent='Write an observation first.';return;}
    if(url){try{const parsed=new URL(url);if(parsed.protocol!=='https:'||parsed.username||parsed.password)throw new Error();}catch{$('evidence-error').textContent='Use an HTTPS source link without account credentials.';return;}}
    if(noteFor(evidenceSymbol).evidence.length>=100){$('evidence-error').textContent='Keep at most 100 pieces of evidence per company.';return;}
    const record={id:id(),text,source:$('evidence-source').value.trim(),url,kind:$('evidence-kind').value,createdAt:Date.now()/1000};
    if(updateNote(evidenceSymbol,n=>({...n,evidence:[...n.evidence,record]}))){$('evidence-dialog').close();toast(`Evidence kept for ${evidenceSymbol}.`);}
  });
  for(const node of [$('valuation-eps'),$('valuation-years'),$('valuation-assumptions')])node.addEventListener('input',editModel);
  $('use-consensus').addEventListener('click',()=>{const row=expectationsData?.eps?.yearlyForecast?.rows?.find(r=>valid(r.consensusEPSForecast)&&r.consensusEPSForecast>=0);if(!row)return;modelDraft.eps=row.consensusEPSForecast;modelDraft.basis=`Nasdaq adjusted annual consensus · ${row.fiscalEnd}`;modelDirty=true;valuationDrafts.set(selected,structuredClone(modelDraft));renderValuation(true);});
  $('save-valuation').addEventListener('click',()=>{if(!M.valuation(modelDraft,quoteFor(selected)))return;if(updateNote(selected,n=>({...n,valuation:structuredClone(modelDraft)}))){modelDirty=false;valuationDrafts.delete(selected);renderValuation();toast('Valuation assumptions attached to this thesis.');}});
  $('holdings').addEventListener('change',()=>queueMicrotask(()=>loadComparables()));
  $('clear-comparison').addEventListener('click',()=>loadComparables());$('refresh-comparison').addEventListener('click',()=>loadComparables(true));
  $('export-comparison').addEventListener('click',exportComparison);$('export-memo').addEventListener('click',exportMemo);
  $('board-export').addEventListener('click',()=>{const symbols=new Set([...Object.keys(allNotes()),...(state?.quotes||[]).map(q=>q.symbol)]);download('marketbar-research-book.md',[...symbols].sort().map(memo).join('\n\n---\n\n'),'text/markdown;charset=utf-8');});
  setPage(location.hash.slice(1)||'today',false);setCompanyTab('overview');
  return {render,reveal,selected:selectedChanged,loaded,notesChanged,research:researchChanged,updateNote,memo,poll,refreshStudy};
})();
window.ResearchDesk=ResearchDesk;

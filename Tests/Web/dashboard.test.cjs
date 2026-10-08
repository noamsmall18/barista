const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const analytics = fs.readFileSync(path.join(__dirname,'../../Barista/Web/analytics.js'),'utf8');
const source = fs.readFileSync(path.join(__dirname,'../../Barista/Web/app.js'),'utf8');
const fixture = () => ({
  app:'Marketbar',portfolioID:'test',portfolioName:'Test portfolio',portfolios:[{id:'test',name:'Test portfolio'}],
  quotes:[{symbol:'AAPL',kind:'stock',currency:'USD',price:125,regularPrice:125,change:2,quantity:10,value:1250,weight:100,dayPL:25,unrealizedPL:100,unrealizedPercent:8.7,sparkline:[120,123,125],receivedAt:1700000000}],
  indices:[],trades:[],intraday:[[1700000000,1200],[1700000060,1250]],history:[],benchmark:[],missingSymbols:[],failedSymbols:[],
  summary:{currencyComparable:true,positions:1,liveTotal:1250,cash:0,dayPL:25,dayPercent:2,unrealizedPL:100,unrealizedPercent:8.7,missingCostCount:0,extendedPL:null,realizedPL:0,winners:1,losers:0},
  status:'Regular session',updatedAt:1700000000,stale:false,pollSeconds:2,backoffSeconds:0
});
async function render(data, options = {}) {
  const nodes = new Map();
  const classList = () => { const classes = new Set(); return {contains:c=>classes.has(c),toggle(c,on){const yes=on===undefined?!classes.has(c):on;if(yes)classes.add(c);else classes.delete(c);return yes;}}; };
  const node = id => {
    if(!nodes.has(id))nodes.set(id,{value:({'security-range':'1D','portfolio-unit':'value','security-unit':'value','scenario-shock':'-5','scenario-symbol':'all','compare-range':'1M'})[id]||'',checked:false,innerHTML:'',textContent:'',dataset:{},classList:classList(),events:{},
      addEventListener(type,fn){this.events[type]=fn;},setAttribute(){},querySelector(){return null;},querySelectorAll(){return [];},focus(){},scrollIntoView(){},getBoundingClientRect(){return {top:0}}});
    return nodes.get(id);
  };
  const requests = [];
  const storage = new Map();
  const context = vm.createContext({
    document:{getElementById:node,querySelectorAll(){return []},addEventListener(){},hidden:false,body:{classList:classList()}},
    window:{addEventListener(){},innerHeight:900},
    fetch:async (route,init)=>{ requests.push({route,init});if(options.fetch)return options.fetch(route,init);return {ok:true,json:async()=>route==='workspace'?{notes:{},preferences:{}}:route==='snapshot'?data:route.startsWith('chart')?{points:[[1700000000,120],[1700000060,125]],currency:'USD',updatedAt:1700000000}:{items:[],annual:[],ratios:[],company:'Example',cik:'1'}}; },
    localStorage:{getItem:key=>storage.get(key),setItem:(key,value)=>storage.set(key,value)},
    AbortSignal,AbortController,setTimeout,clearTimeout,setInterval(){},console
  });
  vm.runInContext(analytics,context);
  vm.runInContext(source,context);
  await new Promise(resolve=>setImmediate(resolve));
  return {node,context,requests,storage};
}
test('renders shared portfolio values and chart, with escaped user names',async()=>{
  const data=fixture();data.quotes[0].symbol='<script>bad</script>';
  const {node}=await render(data);
  assert.match(node('summary').innerHTML,/\$1,250\.00/);
  assert.match(node('holdings').innerHTML,/&lt;script&gt;bad&lt;\/script&gt;/);
  assert.doesNotMatch(node('holdings').innerHTML,/<script>/);
  assert.match(node('portfolio-chart').innerHTML,/data-points=/);
  assert.doesNotMatch(node('status').textContent,/Disconnected/);
});
test('combined portfolio explains automatic aggregation and counts source accounts',async()=>{
  const data=fixture();data.portfolioName='All Portfolios';data.combinedPortfolio=true;
  data.portfolios=[{id:'first',name:'Main'},{id:'second',name:'Savings'}];
  const {node}=await render(data);
  assert.equal(node('portfolio-name').textContent,'All Portfolios');
  assert.match(node('portfolio-note').textContent,/2 portfolios/);
  assert.match(node('portfolio-note').textContent,/Automatically combined from all portfolios/);
});
test('mixed currencies suppress portfolio weights, aggregate charts and total',async()=>{
  const data=fixture();data.summary.currencyComparable=false;data.summary.liveTotal=null;
  data.quotes[0].currency='EUR';data.quotes[0].weight=null;
  const {node}=await render(data);
  assert.match(node('holdings').innerHTML,/€/);
  assert.match(node('portfolio-chart').innerHTML,/different quote currencies/);
  assert.match(node('summary').innerHTML,/total withheld/);
  assert.doesNotMatch(node('insights').innerHTML,/largest priced/);
});
test('empty portfolio renders without inventing prices',async()=>{
  const data=fixture();data.quotes=[];data.intraday=[];data.summary.positions=0;
  const {node}=await render(data);
  assert.match(node('holdings').innerHTML,/No matching symbols/);
  assert.match(node('portfolio-chart').innerHTML,/more history/);
  assert.doesNotMatch(node('status').textContent,/Disconnected/);
});
test('stale and rate-limited feeds remain visibly distinguished',async()=>{
  const data=fixture();data.failedSymbols=['AAPL'];data.stale=true;data.backoffSeconds=30;
  const {node}=await render(data);
  assert.equal(node('warning').hidden,false);
  assert.match(node('warning').textContent,/Refresh failed for AAPL/);
  assert.match(node('warning').textContent,/30 seconds/);
  assert.match(node('status').textContent,/stale/);
});
test('analyst expectations preserve zero EPS and missing targets',async()=>{
  const {node,context}=await render(fixture());
  vm.runInContext(`renderExpectations({eps:{yearlyForecast:{rows:[{fiscalEnd:'Dec 2027',consensusEPSForecast:0,lowEPSForecast:-1,highEPSForecast:1,noOfEstimates:5,up:0,down:2}]}},errors:[]})`,context);
  assert.match(node('analyst-content').innerHTML,/Dec 2027/);
  assert.match(node('analyst-content').innerHTML,/>0<\/td>/);
  assert.doesNotMatch(node('analyst-content').innerHTML,/NaN|Infinity|\$0\.00/);
});
test('analyst upside uses same-currency current quote and escapes provider labels',async()=>{
  const {node,context}=await render(fixture());
  vm.runInContext(`renderExpectations({targets:{consensusOverview:{priceTarget:150,buy:3,hold:2,sell:1}},errors:['<script>']})`,context);
  assert.match(node('analyst-content').innerHTML,/\+20\.00%/);
  assert.match(node('analyst-content').innerHTML,/&lt;script&gt;/);
});

test('scenario keeps cash unchanged and shows only held exposure',async()=>{
  const data=fixture();data.summary.liveTotal=1500;data.summary.cash=250;
  const {node}=await render(data);
  assert.match(node('scenario-result').innerHTML,/-\$62\.50/);
  assert.match(node('scenario-result').innerHTML,/\$1,437\.50/);
});
test('filters watchlist and sorts absent values last without creating zero values',async()=>{
  const data=fixture();data.quotes.push({...data.quotes[0],symbol:'MSFT',quantity:0,value:null});
  const {node,context}=await render(data);
  vm.runInContext("tableFilter='watch';renderHoldings()",context);
  assert.match(node('holdings').innerHTML,/MSFT/);
  assert.doesNotMatch(node('holdings').innerHTML,/AAPL/);
});
test('switching from equity to crypto clears old financial and price controls',async()=>{
  const data=fixture();data.quotes.push({...data.quotes[0],symbol:'BTC',kind:'crypto'});
  const {node,context}=await render(data);
  vm.runInContext("selectSecurity('BTC',false)",context);
  assert.match(node('financials').innerHTML,/apply to equities/);
  assert.match(node('security-chart-note').textContent,/CoinGecko/);
  assert.match(node('security-chart').innerHTML,/data-ordinal="true"/);
});
test('rejects dangerous research source schemes',async()=>{
  const {context}=await render(fixture());
  const html=vm.runInContext("external('javascript:alert(1)','Bad <source>')",context);
  assert.equal(html,'Bad &lt;source&gt;');
});
test('notebook saves the original symbol when selection changes mid-save',async()=>{
  const data=fixture();data.quotes.push({...data.quotes[0],symbol:'MSFT'});
  let finishSave;
  const {node,context,requests}=await render(data,{fetch:async(route,init)=>{
    if(route==='workspace'&&init.method==='POST')await new Promise(resolve=>{finishSave=resolve;});
    return {ok:true,json:async()=>route==='workspace'?{notes:{},preferences:{}}:route==='snapshot'?data:route.startsWith('chart')?{points:[[1,120],[2,125]],currency:'USD'}:{items:[],annual:[],ratios:[],company:'Example'}};
  }});
  node('note-thesis').value='Apple thesis';
  vm.runInContext("editNote();drainNotes();selectSecurity('MSFT',false)",context);
  assert.equal(JSON.parse(requests.find(r=>r.init.method==='POST').init.body).symbol,'AAPL');
  assert.equal(node('note-thesis').value,'');
  finishSave();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(vm.runInContext("workspace.notes.AAPL.thesis",context),'Apple thesis');
  vm.runInContext('clearTimeout(preferenceTimer);clearTimeout(noteTimer)',context);
});
test('a newer notebook draft survives an older save finishing',async()=>{
  let finishSave;let saved=0;
  const {node,context,requests}=await render(fixture(),{fetch:async(route,init)=>{
    if(route==='workspace'&&init.method==='POST'&&++saved===1)await new Promise(resolve=>{finishSave=resolve;});
    return {ok:true,json:async()=>route==='workspace'?{notes:{},preferences:{}}:route==='snapshot'?fixture():route.startsWith('chart')?{points:[[1,120],[2,125]],currency:'USD'}:{items:[],annual:[],ratios:[],company:'Example'}};
  }});
  node('note-thesis').value='First';vm.runInContext('editNote();drainNotes()',context);
  node('note-thesis').value='Second';vm.runInContext('editNote()',context);
  finishSave();await new Promise(resolve=>setImmediate(resolve));
  const writes=requests.filter(r=>r.init.method==='POST').map(r=>JSON.parse(r.init.body));
  assert.deepEqual(writes.map(r=>r.note.thesis),['First','Second']);
  assert.equal(vm.runInContext('dirtyNotes.size',context),0);
  assert.equal(vm.runInContext('workspace.notes.AAPL.thesis',context),'Second');
  vm.runInContext('clearTimeout(preferenceTimer);clearTimeout(noteTimer)',context);
});
test('comparison uses a shared time window and suppresses mixed quote currencies',async()=>{
  const data=fixture();data.quotes.push({...data.quotes[0],symbol:'MSFT'});
  const {node,context}=await render(data);
  await vm.runInContext("compareSymbols=['AAPL','MSFT'];renderComparison()",context);
  assert.match(node('compare-chart').innerHTML,/data-percent="true"/);
  vm.runInContext("state.quotes[1].currency='EUR'",context);
  await vm.runInContext('renderComparison()',context);
  assert.match(node('compare-chart').innerHTML,/same quote currency/);
});

test('editing thesis text preserves evidence, questions and valuation without resending timestamps',async()=>{
  const {node,context,requests}=await render(fixture());
  vm.runInContext(`workspace.notes.AAPL={thesis:'Before',risks:'',catalysts:'',stage:'monitoring',evidence:[{id:'e',text:'Kept'}],questions:[{id:'q',text:'Question',done:false}],valuation:{eps:5},updatedAt:10}`,context);
  node('note-thesis').value='After';vm.runInContext('editNote();drainNotes()',context);await new Promise(resolve=>setImmediate(resolve));
  const saved=JSON.parse(requests.find(r=>r.init.method==='POST').init.body).note;
  assert.equal(saved.thesis,'After');assert.equal(saved.stage,'monitoring');assert.equal(saved.evidence[0].text,'Kept');assert.equal(saved.questions[0].done,false);assert.equal(saved.valuation.eps,5);assert.equal(saved.updatedAt,undefined);
  vm.runInContext('clearTimeout(noteTimer);clearTimeout(preferenceTimer)',context);
});

test('independent research companies do not alter portfolio totals or allocations',async()=>{
  const {node,context}=await render(fixture());
  vm.runInContext(`studyQuotes.set('COST',{symbol:'COST',kind:'stock',currency:'USD',price:900,change:1,quantity:0,researchOnly:true,session:'Last observed bar',sparkline:[890,895,900]});render();selectSecurity('COST',false)`,context);
  assert.match(node('security-name').textContent,/COST/);assert.match(node('security-price').innerHTML,/observed bar change/);
  assert.match(node('summary').innerHTML,/\$1,250\.00/);assert.doesNotMatch(node('allocation').innerHTML,/COST/);
  assert.match(node('holdings').innerHTML,/Research universe/);assert.equal(vm.runInContext('state.quotes.length',context),1);
  vm.runInContext('clearTimeout(preferenceTimer);clearTimeout(noteTimer)',context);
});

test('standalone snapshot explains that the app can be closed',async()=>{
  const data=fixture();data.standalone=true;
  const {node}=await render(data);
  assert.match(node('portfolio-note').textContent,/Independent research service · app can be closed/);
  assert.match(node('cadence').textContent,/Workspace sync/);
});
test('service disconnect points to the independent launcher',async()=>{
  const {node}=await render(fixture(),{fetch:async(route)=>{
    if(route==='snapshot')throw new Error('Service unavailable');
    return {ok:true,json:async()=>({notes:{},preferences:{}})};
  }});
  assert.match(node('warning').textContent,/Reopen the research launcher/);
  assert.doesNotMatch(node('warning').textContent,/Keep the app running/);
});

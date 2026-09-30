const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../../Barista/Web/app.js'),'utf8');
const fixture = () => ({
  app:'Marketbar',portfolioID:'test',portfolioName:'Test portfolio',portfolios:[{id:'test',name:'Test portfolio'}],
  quotes:[{symbol:'AAPL',kind:'stock',currency:'USD',price:125,regularPrice:125,change:2,quantity:10,value:1250,weight:100,dayPL:25,unrealizedPL:100,unrealizedPercent:8.7,sparkline:[120,123,125],receivedAt:1700000000}],
  indices:[],trades:[],intraday:[[1700000000,1200],[1700000060,1250]],history:[],benchmark:[],missingSymbols:[],failedSymbols:[],
  summary:{currencyComparable:true,positions:1,liveTotal:1250,cash:0,dayPL:25,dayPercent:2,unrealizedPL:100,unrealizedPercent:8.7,missingCostCount:0,extendedPL:null,realizedPL:0,winners:1,losers:0},
  status:'Regular session',updatedAt:1700000000,stale:false,pollSeconds:2,backoffSeconds:0
});
async function render(data) {
  const nodes = new Map();
  const node = id => { if(!nodes.has(id))nodes.set(id,{value:id==='security-range'?'1D':'',checked:false,innerHTML:'',textContent:'',addEventListener(){},getBoundingClientRect(){return {top:0}}});return nodes.get(id); };
  const context = vm.createContext({
    document:{getElementById:node,querySelectorAll(){return []},addEventListener(){},hidden:false},
    window:{addEventListener(){},innerHeight:900},
    fetch:async route=>({ok:true,json:async()=>route==='snapshot'?data:route.startsWith('chart')?{points:[[1700000000,120],[1700000060,125]],currency:'USD',updatedAt:1700000000}:{items:[],annual:[],ratios:[],company:'Example',cik:'1'}}),
    AbortSignal,AbortController,setTimeout,clearTimeout,setInterval(){},console
  });
  vm.runInContext(source,context);
  await new Promise(resolve=>setImmediate(resolve));
  return {node,context};
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

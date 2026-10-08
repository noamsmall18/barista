const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../../Barista/Web/analytics.js');
const snapshot = () => ({summary:{currencyComparable:true,liveTotal:2000,cash:500},quotes:[{symbol:'AAPL',quantity:10,value:1000},{symbol:'MSFT',quantity:5,value:500},{symbol:'WATCH',quantity:0,value:null}]});
test('normalization sorts, deduplicates and excludes invalid observations',()=>{
  assert.deepEqual(A.normalize([[3,120],[1,100],[2,110],[2,115],[4,null],[5,Infinity]]),[[1,0],[2,14.999999999999991],[3,19.999999999999996]]);
  assert.deepEqual(A.normalize([[1,0],[2,10]]),[]);
});
test('allocation includes cash and calculates effective holdings independently',()=>{
  const e=A.exposure(snapshot());
  assert.equal(e.cashWeight,25);assert.equal(e.topThree,75);assert.equal(e.held[0].weight,50);assert.ok(Math.abs(e.effectivePositions-1.8)<1e-10);
});
test('borrowed cash remains a signed exposure against net portfolio value',()=>{
  const s=snapshot();s.summary.liveTotal=1000;s.summary.cash=-500;
  const e=A.exposure(s);
  assert.equal(e.cashWeight,-50);
  assert.equal(e.held[0].weight,100);
  assert.equal(e.held[1].weight,50);
});
test('portfolio shock excludes cash and unheld securities',()=>{
  assert.deepEqual(A.scenario(snapshot(),-10),{exposed:1500,delta:-150,total:1850,percent:-7.5});
  assert.equal(A.scenario(snapshot(),10,'AAPL').delta,100);
  assert.equal(A.scenario(snapshot(),10,'WATCH'),null);
});
test('mixed currency allocation and hypothetical totals are withheld',()=>{
  const s=snapshot();s.summary.currencyComparable=false;
  assert.equal(A.exposure(s),null);assert.equal(A.scenario(s,-5),null);
});
test('all numeric sorts put missing numbers last in both directions',()=>{
  const quotes=[{symbol:'MISSING',value:null},{symbol:'ZERO',value:0},{symbol:'LARGE',value:5}];
  assert.deepEqual(A.sortedQuotes(quotes,{direction:'asc'}).map(q=>q.symbol),['ZERO','LARGE','MISSING']);
  assert.deepEqual(A.sortedQuotes(quotes).map(q=>q.symbol),['LARGE','ZERO','MISSING']);
});
test('held, watchlist, search and pinned filters compose',()=>{
  const q=snapshot().quotes;
  assert.deepEqual(A.sortedQuotes(q,{filter:'held',search:'ms'}).map(q=>q.symbol),['MSFT']);
  assert.deepEqual(A.sortedQuotes(q,{filter:'starred',favorites:['WATCH']}).map(q=>q.symbol),['WATCH']);
});
test('financial changes preserve zero and avoid percentages on negative baselines',()=>{
  assert.equal(A.financialChange({points:[{value:10},{value:0}]}).percent,-100);
  const c=A.financialChange({points:[{value:-10},{value:5}]});assert.equal(c.percent,null);assert.equal(c.delta,15);
});
test('CSV escapes quotes, newlines and spreadsheet formula prefixes',()=>{
  const result=A.csv([['=IMPORTXML("bad")','\n@command',-5,'plain,cell']]);
  assert.equal(result,'"\'=IMPORTXML(""bad"")","\'\n@command","-5","plain,cell"');
});
test('ranges clamp only valid comparable observations',()=>{
  assert.equal(A.rangePosition(20,10,30),50);assert.equal(A.rangePosition(40,10,30),100);
  assert.equal(A.rangePosition(20,20,20),null);assert.equal(A.rangePosition(null,10,30),null);
});

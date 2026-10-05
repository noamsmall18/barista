const test=require('node:test');
const assert=require('node:assert/strict');
const M=require('../../Barista/Web/desk-model.js');
const q={symbol:'AAPL',kind:'stock',currency:'USD',price:100,change:3};
const model=()=>({eps:5,years:3,basis:'Manual',bear:{growth:-5,multiple:15},base:{growth:10,multiple:20},bull:{growth:20,multiple:30}});
test('old notebooks migrate to research defaults without losing text',()=>{
  const n=M.note({thesis:'Original reasoning',risks:'Risk',catalysts:'Question',updatedAt:1});
  assert.equal(n.thesis,'Original reasoning');assert.equal(n.stage,'inbox');assert.deepEqual(n.evidence,[]);assert.equal(n.updatedAt,undefined);
});
test('note edits cannot mutate previously saved evidence or valuation',()=>{
  const original={evidence:[{id:'a',text:'First'}],valuation:model()};const copy=M.note(original);
  copy.evidence[0].text='Changed';copy.valuation.base.growth=90;
  assert.equal(original.evidence[0].text,'First');assert.equal(original.valuation.base.growth,10);
});
test('review agenda prioritizes local due dates, earnings, questions and observations',()=>{
  const now=new Date(2026,9,1,12),time=now.getTime()/1000;
  const quotes=[{...q,earnings:{date:time+86400,session:'After close'}}];
  const notes={AAPL:{reviewDate:'2026-10-01',questions:[{id:'q',text:'Margins?',done:false}]}};
  assert.deepEqual(M.agenda(quotes,notes,now).map(r=>r.kind),['review','earnings','questions','move']);
  assert.equal(M.due('2026-10-02',now),false);
});
test('archived research and completed questions stay out of the agenda',()=>{
  const notes={AAPL:{stage:'archived',reviewDate:'2026-01-01',questions:[{text:'Done',done:true}]}};
  assert.deepEqual(M.agenda([q],notes,new Date(2026,9,1)),[]);
});
test('valuation compounds annual EPS over the selected horizon before applying multiples',()=>{
  const results=M.valuation(model(),q);
  assert.ok(Math.abs(results[1].eps-6.655)<1e-10);assert.ok(Math.abs(results[1].price-133.1)<1e-10);assert.ok(Math.abs(results[1].upside-33.1)<1e-10);
});
test('valuation preserves zero EPS and refuses crypto, FX, missing or invalid inputs',()=>{
  const zero=model();zero.eps=0;assert.equal(M.valuation(zero,q)[0].price,0);
  for(const quote of [{...q,kind:'crypto'},{...q,currency:'EUR'},{...q,price:null}])assert.equal(M.valuation(model(),quote),null);
  for(const bad of [{...model(),eps:-1},{...model(),eps:NaN},{...model(),years:4},{...model(),base:{growth:201,multiple:20}},{...model(),base:{growth:5,multiple:-1}}])assert.equal(M.valuation(bad,q),null);
});
test('sensitivity bounds stay valid and identify the exact base assumptions',()=>{
  const m=model();m.base={growth:-88,multiple:2};const matrix=M.sensitivity(m,q);
  assert.ok(matrix.growth.every(g=>g>=-90));assert.ok(matrix.multiples.every(p=>p>=0));assert.equal(matrix.cells.flat().filter(c=>c.base).length,1);
});
test('reported metrics retain period and units, and never replace absent values with zero',()=>{
  const data={annual:[{id:'net_income',unit:'USD',points:[{value:0,label:'FY2025',filed:'2026-02-01'}]}]};
  assert.equal(M.latestMetric(data,'net_income').value,0);assert.equal(M.latestMetric(data,'net_income').label,'FY2025');assert.equal(M.latestMetric(data,'revenue'),null);
});
test('thesis board includes saved companies outside the universe and supports text filtering',()=>{
  const notes={MSFT:{thesis:'Cloud margin question',stage:'monitoring'},AAPL:{stage:'archived'}};
  assert.deepEqual(M.board([q],notes).map(r=>r.quote.symbol),['MSFT']);assert.equal(M.board([q],notes,'margin')[0].quote.symbol,'MSFT');assert.equal(M.board([q],notes,'',true).length,2);
});

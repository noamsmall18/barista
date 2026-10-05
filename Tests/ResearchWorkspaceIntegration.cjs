// Run after ./build-app.sh marketbar. Exercises the shipped helper, not a preview.
// A temporary bundle identity keeps the user's portfolio/research untouched.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn,execFileSync} = require('node:child_process');
const {once} = require('node:events');
const delay = ms => new Promise(resolve=>setTimeout(resolve,ms));
const product=process.env.RESEARCH_PRODUCT||'Marketbar';
const standalone=path.join(__dirname,`../dist/${product}Research.bundle`);
const built=process.env.RESEARCH_BUNDLE|| (fs.existsSync(standalone)?standalone:path.join(__dirname,`../dist/${product}.app/Contents/Resources/Research.bundle`));

test('real helper serves a complete desk, survives launcher exit, and restores saves after restart', {timeout:90000}, async t=>{
  assert.ok(fs.existsSync(built),'Build the app before running this integration check.');
  const bundleID=execFileSync('/usr/libexec/PlistBuddy',['-c','Print :CFBundleIdentifier',path.join(built,'Contents/Info.plist')],{encoding:'utf8'}).trim();
  const suite=execFileSync('/usr/libexec/PlistBuddy',['-c','Print :BAResearchDefaultsSuite',path.join(built,'Contents/Info.plist')],{encoding:'utf8'}).trim();
  assert.notEqual(bundleID,suite,'The service must never register as another copy of the menu-bar app.');
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'research-integration-'));
  const bundle=path.join(root,built.endsWith('.bundle')?'Research.bundle':'Research.app'),domain=`com.noam.research-test-${process.pid}`;
  const session=path.join(root,'session');
  fs.cpSync(built,bundle,{recursive:true});
  const plist=path.join(bundle,'Contents/Info.plist');
  execFileSync('/usr/libexec/PlistBuddy',['-c',`Set :CFBundleIdentifier ${domain}.service`,plist]);
  execFileSync('/usr/libexec/PlistBuddy',['-c',`Set :BAResearchDefaultsSuite ${domain}`,plist]);
  execFileSync('/usr/bin/codesign',['--force','--sign','-',bundle],{stdio:'ignore'});
  const executable=path.join(bundle,`Contents/MacOS/${product}Research`);
  let child;
  t.after(async()=>{
    if(child&&child.exitCode===null&&child.signalCode===null){child.kill('SIGTERM');await once(child,'exit');}
    try{execFileSync('/usr/bin/defaults',['delete',domain],{stdio:'ignore'});}catch{}
    fs.rmSync(root,{recursive:true,force:true});
  });
  const config={symbols:[],coins:[],portfolios:[{id:'independent',name:'Independent check',cash:350,holdings:{},costBasis:{},transactions:[]}],activePortfolioID:'independent'};
  function setConfig(config){
    const widget={instanceID:'11111111-1111-1111-1111-111111111111',widgetID:'stock-ticker',order:0,isEnabled:true,configData:Buffer.from(JSON.stringify(config)).toString('base64')};
    const raw=Buffer.from(JSON.stringify([widget])).toString('hex');
    execFileSync('/usr/bin/defaults',['write',domain,'barista.activeWidgets','-data',raw]);
  }
  setConfig(config);
  let output='',errors='';
  async function start(){
    output='';errors='';
    child=spawn(executable,['--no-open','--session-directory',session]);
    child.stdout.on('data',data=>output+=data);
    child.stderr.on('data',data=>errors+=data);
    for(let i=0;i<100&&!output.includes('\n');i++){
      assert.equal(child.exitCode,null,errors);await delay(100);
    }
    assert.match(output,/^http:\/\/127\.0\.0\.1:/,errors);
    return output.trim().split('\n')[0];
  }
  let url=await start();
  const get=async route=>{
    const response=await fetch(new URL(route,url),{signal:AbortSignal.timeout(25000)});
    assert.equal(response.status,200,route);return response.json();
  };
  const health=await get('health');assert.equal(health.pid,child.pid);
  const snap=await get('snapshot');
  assert.equal(snap.standalone,true);
  assert.equal(snap.portfolioName,'Independent check');
  assert.equal(snap.summary.cash,350);
  assert.equal(snap.summary.liveTotal,350);
  assert.deepEqual(snap.trades,[]);
  for(const file of ['', 'app.js','desk.js','desk-model.js','analytics.js','style.css']){
    const response=await fetch(new URL(file,url));assert.equal(response.status,200,file);
    assert.ok((await response.text()).length>100,file);
    assert.match(response.headers.get('content-security-policy'),/connect-src 'self'/);
  }
  const logo=await fetch(new URL('marketbar-logo.png',url));assert.equal(logo.status,200);assert.match(logo.headers.get('content-type'),/image\/png/);assert.ok((await logo.arrayBuffer()).byteLength>1000);
  // The second launcher exits; the original independent service remains alive.
  const second=spawn(executable,['--no-open','--session-directory',session]);let secondOutput='';
  second.stdout.on('data',d=>secondOutput+=d);
  const [code]=await once(second,'exit');assert.equal(code,0);assert.equal(secondOutput.trim(),url);
  assert.equal((await get('health')).pid,health.pid);
  const note={thesis:'Independent thesis ☕',risks:'Test risk',catalysts:'Next filing',stage:'monitoring',conviction:'high',reviewDate:'2026-10-05',
    evidence:[{id:'e1',text:'Test observed evidence',source:'Integration check',url:'https://www.sec.gov/',kind:'supports',createdAt:1700000000}],
    questions:[{id:'q1',text:'Durable?',done:false,createdAt:1700000000}],
    valuation:{eps:5,years:3,basis:'Manual',bear:{growth:0,multiple:15},base:{growth:10,multiple:20},bull:{growth:20,multiple:30}}};
  const post=await fetch(new URL('workspace',url),{method:'POST',headers:{Origin:new URL(url).origin,'Content-Type':'application/json'},body:JSON.stringify({symbol:'AAPL',note,preferences:{researchSymbols:['AAPL'],selected:'AAPL',favorites:['AAPL']}})});
  assert.equal(post.status,200);assert.equal((await post.json()).saved,true);
  const saved=await get('workspace');assert.equal(saved.notes.AAPL.thesis,note.thesis);assert.deepEqual(saved.notes.AAPL.valuation,note.valuation);
  const forbidden=await fetch(new URL('workspace',url),{method:'POST',headers:{Origin:'https://attacker.example','Content-Type':'application/json'},body:'{"preferences":{"selected":"MSFT"}}'});
  assert.equal(forbidden.status,403);
  const unchanged=await get('snapshot');assert.equal(unchanged.summary.cash,350);assert.deepEqual(unchanged.trades,[]);
  // App edits arrive across preferences domains without an app or UI instance.
  setConfig({...config,portfolios:[{...config.portfolios[0],name:'Updated outside the service',cash:425}]});
  let changed;
  for(let i=0;i<30;i++){changed=await get('snapshot');if(changed.summary.cash===425)break;await delay(100);}
  assert.equal(changed.portfolioName,'Updated outside the service');assert.equal(changed.summary.cash,425);
  // Restart preserves the URL/origin, research data, and preferences.
  child.kill('SIGTERM');await once(child,'exit');
  const prior=url;url=await start();assert.equal(url,prior);
  const restored=await get('workspace');assert.deepEqual(restored,saved);
  assert.equal((fs.statSync(path.join(session,'session.json')).mode&0o777),0o600);
  assert.equal((fs.statSync(session).mode&0o777),0o700);
  // All company providers are still routed through the real Swift services.
  const routes=['study-quote?symbol=AAPL','chart?symbol=AAPL&range=1M','research?symbol=AAPL','news?symbol=AAPL','expectations?symbol=AAPL'];
  const provider=await Promise.all(routes.map(route=>get(route)));
  provider.forEach((data,i)=>assert.ok(data&&typeof data==='object',routes[i]));
  if(process.env.RESEARCH_REQUIRE_LIVE==='1'){
    assert.ok(provider[0].price>0,JSON.stringify(provider[0]));
    assert.ok(provider[1].points.length>1,JSON.stringify(provider[1]));
    assert.ok(provider[2].annual.length>0,JSON.stringify(provider[2]));
    assert.ok(provider[3].items.length>0,JSON.stringify(provider[3]));
    assert.ok(provider[4].eps||provider[4].targets,JSON.stringify(provider[4]));
  }
  // Installer can stop a manually started helper through its authenticated health session.
  const stopped=once(child,'exit');
  const stopper=spawn(executable,['--stop','--session-directory',session]);
  const [stopCode]=await once(stopper,'exit');assert.equal(stopCode,0);
  await stopped;
  console.log('Standalone lifecycle, persisted research, config sync, all assets and all five provider routes verified.');
});

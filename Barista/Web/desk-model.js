'use strict';
// Research workflow calculations. No browser, provider, or persistence side effects.
const ResearchModel = (() => {
  const stages = ['inbox','researching','ready','monitoring','archived'];
  const stageLabels = {inbox:'Inbox',researching:'Researching',ready:'Ready to review',monitoring:'Monitoring',archived:'Archived'};
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  function note(raw = {}) {
    return {
      thesis: typeof raw.thesis === 'string' ? raw.thesis : '',
      risks: typeof raw.risks === 'string' ? raw.risks : '',
      catalysts: typeof raw.catalysts === 'string' ? raw.catalysts : '',
      stage: stages.includes(raw.stage) ? raw.stage : 'inbox',
      conviction: ['unrated','low','medium','high'].includes(raw.conviction) ? raw.conviction : 'unrated',
      reviewDate: typeof raw.reviewDate === 'string' ? raw.reviewDate : '',
      evidence: Array.isArray(raw.evidence) ? raw.evidence.map(e => ({...e})) : [],
      questions: Array.isArray(raw.questions) ? raw.questions.map(q => ({...q})) : [],
      ...(raw.valuation ? {valuation:structuredClone(raw.valuation)} : {})
    };
  }
  function dateKey(now = new Date()) {
    return `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;
  }
  function due(reviewDate, now = new Date()) {
    return /^\d{4}-\d{2}-\d{2}$/.test(reviewDate || '') && reviewDate <= dateKey(now);
  }
  function agenda(quotes, notes, now = new Date()) {
    const time = now.getTime()/1000, result = [];
    for (const q of quotes) {
      const n = note(notes[q.symbol]);
      if(n.stage === 'archived') continue;
      if(due(n.reviewDate,now)) result.push({symbol:q.symbol,kind:'review',priority:0,title:`Revisit the ${q.symbol} thesis`,detail:`Review ${n.reviewDate === dateKey(now) ? 'due today' : 'overdue since '+n.reviewDate}. Check the case against new evidence.`});
      if(q.earnings && finite(q.earnings.date) && q.earnings.date >= time-86400 && q.earnings.date <= time+10*86400) result.push({symbol:q.symbol,kind:'earnings',priority:1,title:`${q.symbol} earnings on the horizon`,detail:`${new Date(q.earnings.date*1000).toLocaleDateString([], {month:'short',day:'numeric'})} · ${q.earnings.session || 'Session unspecified'} · prepare the questions that matter.`});
      const open = n.questions.filter(t=>!t.done).length;
      if(open) result.push({symbol:q.symbol,kind:'questions',priority:2,title:`${open} unanswered question${open===1?'':'s'} on ${q.symbol}`,detail:n.questions.find(t=>!t.done).text});
      if(finite(q.change) && Math.abs(q.change)>=2) result.push({symbol:q.symbol,kind:'move',priority:3,title:`${q.symbol} moved ${q.change>0?'+':''}${q.change.toFixed(2)}%`,detail:'Live price observation. Investigate the context before changing your view.'});
    }
    return result.sort((a,b)=>a.priority-b.priority || a.symbol.localeCompare(b.symbol));
  }
  function valuation(model, quote) {
    if(quote?.kind!=='stock' || quote.currency!=='USD' || !finite(quote.price) || quote.price<=0) return null;
    if(!model || !finite(model.eps) || model.eps<0 || model.eps>1e6 || ![1,2,3,5].includes(model.years)) return null;
    const results=[];
    for(const name of ['bear','base','bull']) {
      const c=model[name];
      if(!c || !finite(c.growth) || c.growth< -90 || c.growth>200 || !finite(c.multiple) || c.multiple<0 || c.multiple>200) return null;
      const eps=model.eps*(1+c.growth/100)**model.years, price=eps*c.multiple;
      results.push({name,eps,price,upside:(price/quote.price-1)*100});
    }
    return results;
  }
  function sensitivity(model, quote) {
    if(!valuation(model,quote)) return null;
    const growth=[...new Set([-10,-5,0,5,10].map(n=>Math.max(-90,Math.min(200,model.base.growth+n))))];
    const multiples=[...new Set([-10,-5,0,5,10].map(n=>Math.max(0,Math.min(200,model.base.multiple+n))))];
    return {growth,multiples,cells:growth.map(g=>multiples.map(m=>({price:model.eps*(1+g/100)**model.years*m,base:g===model.base.growth&&m===model.base.multiple})))};
  }
  function latestMetric(data,id,period='annual') {
    const m=data?.[period]?.find(m=>m.id===id);
    const p=m?.points?.at(-1);
    return p && finite(p.value) ? {value:p.value,unit:m.unit,label:p.label,filed:p.filed,form:p.form,statement:m.statement} : null;
  }
  function board(quotes, notes, search='', archived=false) {
    const universe=new Map(quotes.map(q=>[q.symbol,q]));
    for(const symbol of Object.keys(notes)) if(!universe.has(symbol)) universe.set(symbol,{symbol,kind:'saved'});
    const query=search.trim().toLowerCase();
    return [...universe.values()].map(q=>({quote:q,note:note(notes[q.symbol])})).filter(({quote:q,note:n})=>
      (archived || n.stage!=='archived') && (!query || `${q.symbol} ${n.thesis} ${n.risks} ${n.catalysts}`.toLowerCase().includes(query)));
  }
  return {stages,stageLabels,note,dateKey,due,agenda,valuation,sensitivity,latestMetric,board};
})();
if(typeof module !== 'undefined') module.exports=ResearchModel;

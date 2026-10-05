'use strict';
// Pure calculations shared by the dashboard and its offline tests.
const WorkspaceAnalytics = (() => {
  const finite = n => typeof n === 'number' && Number.isFinite(n);
  function points(series) {
    const unique = new Map();
    for (const p of series || []) if (Array.isArray(p) && finite(p[0]) && finite(p[1])) unique.set(p[0], p[1]);
    return [...unique].sort((a, b) => a[0] - b[0]);
  }
  function normalize(series) {
    const clean = points(series);
    return clean.length && clean[0][1] > 0 ? clean.map(([t, v]) => [t, (v / clean[0][1] - 1) * 100]) : [];
  }
  function exposure(snapshot) {
    if (!snapshot.summary.currencyComparable || !finite(snapshot.summary.liveTotal) || snapshot.summary.liveTotal <= 0) return null;
    const total = snapshot.summary.liveTotal;
    const held = snapshot.quotes.filter(q => q.quantity > 0 && finite(q.value) && q.value > 0)
      .map(q => ({symbol: q.symbol, value: q.value, weight: q.value / total * 100}))
      .sort((a, b) => b.value - a.value);
    const cashWeight = Math.max(0, snapshot.summary.cash || 0) / total * 100;
    const equityWeight = held.reduce((sum, q) => sum + q.weight, 0);
    const hhi = held.reduce((sum, q) => sum + (equityWeight > 0 ? q.weight / equityWeight : 0) ** 2, 0);
    return {held, cashWeight, topThree: held.slice(0, 3).reduce((sum, q) => sum + q.weight, 0), effectivePositions: hhi > 0 ? 1 / hhi : 0};
  }
  function scenario(snapshot, shock, symbol = 'all') {
    if (!snapshot.summary.currencyComparable || !finite(snapshot.summary.liveTotal) || !finite(shock)) return null;
    const holdings = snapshot.quotes.filter(q => q.quantity > 0 && (symbol === 'all' || q.symbol === symbol));
    if (symbol !== 'all' && (!holdings.length || !finite(holdings[0].value))) return null;
    const exposed = holdings.reduce((sum, q) => sum + (finite(q.value) ? q.value : 0), 0);
    const delta = exposed * Math.max(-100, shock) / 100;
    return {exposed, delta, total: snapshot.summary.liveTotal + delta, percent: snapshot.summary.liveTotal > 0 ? delta / snapshot.summary.liveTotal * 100 : null};
  }
  function sortedQuotes(quotes, {search = '', filter = 'all', sort = 'value', direction = 'desc', favorites = []} = {}) {
    const query = search.trim().toUpperCase();
    const result = quotes.filter(q => q.symbol.toUpperCase().includes(query) &&
      (filter === 'all' || (filter === 'held' && q.quantity > 0) || (filter === 'watch' && !(q.quantity > 0)) || (filter === 'starred' && favorites.includes(q.symbol))));
    return result.sort((a, b) => {
      if (sort === 'symbol') return (direction === 'asc' ? 1 : -1) * a.symbol.localeCompare(b.symbol);
      const av = a[sort], bv = b[sort];
      if (!finite(av)) return finite(bv) ? 1 : a.symbol.localeCompare(b.symbol);
      if (!finite(bv)) return -1;
      return (direction === 'asc' ? av - bv : bv - av) || a.symbol.localeCompare(b.symbol);
    });
  }
  function financialChange(metric) {
    const p = metric?.points || [];
    if (p.length < 2) return null;
    const latest = p.at(-1), previous = p.at(-2);
    if (!finite(latest.value) || !finite(previous.value)) return null;
    return {latest, previous, delta: latest.value - previous.value, percent: previous.value > 0 ? (latest.value / previous.value - 1) * 100 : null};
  }
  function rangePosition(value, low, high) {
    return finite(value) && finite(low) && finite(high) && high > low ? Math.max(0, Math.min(100, (value - low) / (high - low) * 100)) : null;
  }
  // Neutralize formula prefixes before quoting user/provider-controlled CSV cells.
  function csv(rows) {
    return rows.map(row => row.map(value => {
      let text = String(value ?? '');
      if (typeof value !== 'number' && /^[\s]*[=+\-@]/.test(text)) text = "'" + text;
      return '"' + text.replace(/"/g, '""') + '"';
    }).join(',')).join('\r\n');
  }
  return {finite, points, normalize, exposure, scenario, sortedQuotes, financialChange, rangePosition, csv};
})();
if (typeof module !== 'undefined') module.exports = WorkspaceAnalytics;

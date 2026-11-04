#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.join(__dirname, '../ChromeExtension');
const source = fs.readFileSync(path.join(root, 'background.js'), 'utf8');

function fixture({body = '%PDF-1.7\nfixture', injectFails = false, metadata = {}, nativeError = false, fetchFails = false, fetchOverride} = {}) {
  const calls = {native: [], badges: [], results: [], options: 0, fetch: []};
  let click;
  const chrome = {
    action: {onClicked: {addListener: fn => { click = fn; }},
      setBadgeText: async value => { calls.badges.push(value); },
      setBadgeBackgroundColor: async () => {}, setTitle: async () => {}},
    runtime: {connectNative: host => {
      let receive, disconnect;
      return {onMessage: {addListener: fn => { receive = fn; }}, onDisconnect: {addListener: fn => { disconnect = fn; }},
        postMessage: payload => {
          calls.native.push({host, payload});
          queueMicrotask(() => receive({ok: true, status: payload.action === 'pdfFinish' ? 'saved' : 'streaming',
            offset: payload.action === 'pdfChunk' ? payload.offset + atob(payload.data).length : 0}));
        }, disconnect: () => disconnect?.()};
    }, sendNativeMessage: async (host, payload) => {
      calls.native.push({host, payload});
      if (nativeError) throw new Error('Native host not registered');
      return {ok: true, status: payload.action === 'beginCapture' ? 'added' : payload.action === 'savePDF' ? 'saved' : 'metadataOnly'};
    }, openOptionsPage: async () => { calls.options++; }, onInstalled: {addListener() {}}},
    storage: {local: {set: async value => { calls.results.push(value.lastResult); }}},
    scripting: {executeScript: async () => {
      if (injectFails) throw new Error('PDF viewer cannot inject');
      return [{result: metadata}];
    }}
  };
  const context = vm.createContext({chrome, URL, crypto: crypto.webcrypto, TextDecoder, Uint8Array,
    AbortSignal, btoa, setTimeout, clearTimeout, fetch: async (url, options) => {
      calls.fetch.push({url, options});
      if (fetchOverride) return fetchOverride(url, options);
      if (fetchFails) throw new Error('CORS or login failure');
      return new Response(body);
    }});
  context.importScripts = name => vm.runInContext(fs.readFileSync(path.join(root, name), 'utf8'), context);
  vm.runInContext(source, context);
  return {calls, click};
}

function extract({meta = [], links = [], jsonLD = []} = {}) {
  const document = {
    title: 'Fallback browser title',
    createElement: () => ({set innerHTML(value) {this.value = value.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');}}),
    querySelector: () => null,
    querySelectorAll: selector => selector.startsWith('meta[') ? meta.map(([name, content]) => ({content, getAttribute: key => key === 'name' ? name : null}))
      : selector.startsWith('script[') ? jsonLD.map(value => ({textContent: JSON.stringify(value)}))
      : selector === 'a[href]' ? links.map(link => ({...link, textContent: link.text || '', getAttribute: () => '', closest: () => link.supplement ? {} : null})) : []
  };
  const context = vm.createContext({document, location: {href: 'https://www.nature.com/articles/s41586-026-11114-1', pathname: '/articles/s41586-026-11114-1'}, URL});
  vm.runInContext(fs.readFileSync(path.join(root, 'capture-page.js'), 'utf8'), context);
  return vm.runInContext('citationMetadata()', context);
}

(async () => {
  const tab = {id: 8, url: 'https://publisher.example/paper.pdf', title: 'A paper'};
  let f = fixture({injectFails: true});
  await f.click(tab);
  assert.equal(f.calls.native[0].payload.action, 'beginCapture');
  assert.equal(f.calls.native[1].payload.action, 'pdfStart');
  assert.equal(atob(f.calls.native[2].payload.data), '%PDF-1.7\nfixture');
  assert.equal(f.calls.native.at(-1).payload.action, 'pdfFinish');
  assert.equal(f.calls.fetch[0].options.credentials, 'include');
  assert.equal(f.calls.badges.at(-1).text, '✓');
  console.log('PASS direct PDF viewer capture publishes metadata then sends PDF bytes');

  let finishDownload;
  f = fixture({fetchOverride: () => new Promise(resolve => { finishDownload = () => resolve(new Response('%PDF-1.7\nslow')); })});
  const running = f.click(tab);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.results[0].status, 'downloading');
  assert.equal(f.calls.native.length, 1);
  assert.ok(f.calls.results[0].addedMilliseconds < 1000);
  assert.equal(f.calls.badges.at(-1).text, '↓');
  finishDownload(); await running;
  assert.equal(f.calls.badges.at(-1).text, '✓');
  console.log('PASS metadata handoff completes before a deliberately stalled PDF download');

  f = fixture({metadata: {title: 'Citation title', authors: [{name: 'A Scientist'}], journal: 'Nature', pdfURL: 'https://publisher.example/full.pdf'}});
  await f.click({...tab, url: 'https://publisher.example/article'});
  assert.equal(f.calls.fetch[0].url, 'https://publisher.example/full.pdf');
  assert.equal(f.calls.native[0].payload.metadata.authors[0].name, 'A Scientist');
  assert.equal(f.calls.native[0].payload.metadata.journal, 'Nature');
  console.log('PASS full page metadata and discovered PDF are passed together');

  for (const settings of [{body: '<html>login required</html>'}, {fetchFails: true}]) {
    f = fixture(settings); await f.click(tab);
    assert.equal(f.calls.native.at(-1).payload.action, 'captureFailed');
    assert.equal(f.calls.badges.at(-1).text, 'PDF?');
    assert.match(f.calls.results.at(-1).detail, /metadata saved.*needs attention/i);
  }
  console.log('PASS HTML and network failures retain metadata without claiming a saved PDF');

  for (const url of ['chrome://settings', 'file:///tmp/paper.pdf', 'javascript:alert(1)', 'https://u:p@example.org/paper.pdf']) {
    f = fixture(); await f.click({...tab, url});
    assert.equal(f.calls.native.length, 0); assert.equal(f.calls.fetch.length, 0);
    assert.equal(f.calls.results[0].ok, false);
  }
  f = fixture({nativeError: true}); await f.click(tab);
  assert.equal(f.calls.badges.at(-1).text, '!'); assert.equal(f.calls.options, 1);
  f = fixture(); await Promise.all([f.click(tab), f.click(tab)]);
  assert.equal(f.calls.native.length, 4);
  f = fixture({fetchOverride: async () => new Response('%PDF-small', {headers:{'content-length': String(512 * 1024 * 1024 + 1)}})}); await f.click(tab);
  assert.equal(f.calls.native.at(-1).payload.action, 'captureFailed');
  assert.match(f.calls.results.at(-1).downloadError, /512 MB/);
  console.log('PASS invalid URLs, absent helper, repeated clicks and PDF size limits');

  const names = ['Rathkey, Joseph K.', 'Choi, Shannon S.', 'van Unen, Vincent', 'Zhang, Huimin', 'Liu, Min', 'Ding, Jie', 'Alwahabi, Samira A.', 'Santos, António J. M.', 'Mallajosyula, Vamsee', 'Chan, Joshua E.', 'Mohsin, Azam', 'Elsheikh, Maher M.', 'Rustagi, Arjun', 'Lam, Brandon', 'Chirieleison, Steven M.', 'Wallen, Bailey', 'Solis, Daniel', 'Mah, Jordan', 'Horn, Hudson T.', 'Röltgen, Katharina', 'Nair, Ramesh', 'Trope, Winston', 'Guh-Siesel, Alexander', 'Lin, Zhongqi', 'Powell, Hannah S.', 'Salehi, Ahmad', 'Beck, Aimee', 'Edwards, Caitlin', 'Martin, Brock A.', 'Dunn, James C. Y.', 'Blish, Catherine A.', 'Baric, Ralph S.', 'Pinsky, Benjamin', 'Boyd, Scott D.', 'Sette, Alessandro', 'Grifoni, Alba', 'Davis, Mark M.', 'Shrager, Joseph', 'Kuo, Calvin J.'];
  const nature = extract({meta: [
    ['citation_title', 'Human lung organoid modelling of tissue-resident antiviral T cell responses'],
    ['citation_doi', '10.1038/s41586-026-11114-1'], ['citation_journal_title', 'Nature'],
    ['citation_online_date', '2026/10/07'], ['citation_firstpage', '1'], ['citation_lastpage', '11'],
    ['dc.description', 'Lung organoids retain T&nbsp;cells.'], ...names.map(name => ['dc.creator', name])],
    jsonLD: [{mainEntity: {'@type':'ScholarlyArticle', headline:'Nature article', author:[{name:'Joseph K. Rathkey',url:'https://orcid.org/0009-0004-5981-7469'}]}}],
    links: [{href:'https://www.nature.com/articles/s41586-026-11114-1#Fig1',text:'Figure 1'},
      {href: 'https://static-content.springer.com/esm/Reporting.pdf', text: 'Reporting Summary (download PDF )', supplement: true},
      {href: 'https://www.nature.com/articles/s41586-026-11114-1.pdf', text: 'Download PDF'}]});
  assert.equal(nature.pdfURL, 'https://www.nature.com/articles/s41586-026-11114-1.pdf');
  assert.equal(nature.authors.length, 39); assert.equal(nature.authors[2].familyName, 'van Unen');
  assert.equal(nature.authors[0].orcid, '0009-0004-5981-7469');
  assert.equal(nature.authors[38].familyName, 'Kuo'); assert.equal(nature.journal, 'Nature');
  assert.equal(nature.abstract, 'Lung organoids retain T cells.'); assert.equal(nature.pages, '1–11');
  console.log('PASS Nature fixture: main PDF, 39 ordered authors, particles, date, abstract and journal');

  const ld = extract({jsonLD: [{mainEntity: {'@type': 'ScholarlyArticle', headline: 'JSON-LD paper', author: [{name:'Jane Scientist', url:'https://orcid.org/0000-0001-2345-6789'}], encoding: {encodingFormat:'application/pdf', contentUrl:'/paper.pdf'}, datePublished:'2026-10-07', isPartOf:{name:'A Journal'}}}]});
  assert.equal(ld.title, 'JSON-LD paper'); assert.equal(ld.pdfURL, 'https://www.nature.com/paper.pdf');
  assert.equal(ld.authors[0].orcid, '0000-0001-2345-6789');
  assert.equal(extract({links:[{href:'https://example.org/supplement.pdf',text:'Supplementary PDF'}]}).pdfURL, null);
  console.log('PASS structured article metadata fallback and exclusion of supplementary PDFs');
})().catch(error => { console.error(error); process.exitCode = 1; });

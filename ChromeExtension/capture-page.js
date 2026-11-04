// Chrome serializes this entire function into the selected page's isolated world.
function citationMetadata() {
  const clean = (value, max = 1000) => {
    if (typeof value !== 'string') return '';
    const node = document.createElement('textarea');
    node.innerHTML = value;
    return node.value.replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim().slice(0, max);
  };
  const tags = [...document.querySelectorAll('meta[name],meta[property]')];
  const all = name => tags.filter(node => (node.getAttribute('name') || node.getAttribute('property') || '').toLowerCase() === name)
    .map(node => node.content).filter(Boolean);
  const first = (...names) => names.flatMap(all)[0] || '';
  const safeURL = value => {
    try {
      if (!value) return null;
      const url = new URL(value, location.href);
      return /^https?:$/.test(url.protocol) && !url.username && !url.password && url.href.length <= 8000 ? url.href : null;
    } catch { return null; }
  };
  const articles = [];
  const visit = (value, depth = 0) => {
    if (!value || typeof value !== 'object' || depth > 5) return;
    if (Array.isArray(value)) { value.slice(0, 30).forEach(v => visit(v, depth + 1)); return; }
    const type = [].concat(value['@type'] || []).join(' ');
    if (/ScholarlyArticle|MedicalScholarlyArticle|NewsArticle|^Article$/.test(type) || value.headline && value.author) articles.push(value);
    visit(value.mainEntity, depth + 1); visit(value['@graph'], depth + 1);
  };
  for (const node of [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0, 10)) {
    if (node.textContent.length > 500000) continue;
    try { visit(JSON.parse(node.textContent)); } catch { /* Broken publisher JSON must not prevent capture. */ }
  }
  const article = articles.find(value => /ScholarlyArticle/.test([].concat(value['@type'] || []).join(' '))) || articles[0] || {};
  const ldAuthors = [].concat(article.author || []).slice(0, 300);
  const citationAuthors = all('citation_author');
  const dcAuthors = all('dc.creator');
  const authors = (citationAuthors.length ? citationAuthors : dcAuthors.length ? dcAuthors : ldAuthors).map((value, index) => {
    const name = clean(typeof value === 'string' ? value : value.name, 300);
    const comma = name.indexOf(',');
    const display = comma >= 0 ? `${name.slice(comma + 1).trim()} ${name.slice(0, comma).trim()}` : name;
    const ld = ldAuthors.find(a => a && typeof a === 'object' && clean(a.name, 300) === display) || {};
    const givenName = comma >= 0 ? name.slice(comma + 1).trim() : clean(value.givenName || ld.givenName, 200);
    const familyName = comma >= 0 ? name.slice(0, comma).trim() : clean(value.familyName || ld.familyName, 200);
    const orcid = String(value.url || ld.url || all('citation_author_orcid')[index] || '').match(/\d{4}-\d{4}-\d{4}-[\dX]{4}/i)?.[0];
    return {name, givenName, familyName, ...(orcid ? {orcid} : {})};
  }).filter(a => a.name || a.familyName);

  const candidates = [];
  const add = (url, score) => { const safe = safeURL(url); if (safe) candidates.push({url: safe, score}); };
  all('citation_pdf_url').forEach(url => add(url, 1000));
  for (const node of document.querySelectorAll('link[type="application/pdf"][href]')) add(node.href, 800);
  for (const value of [].concat(article.encoding || [], article.associatedMedia || [])) {
    if (value && /pdf/i.test(value.encodingFormat || value.fileFormat || '')) add(value.contentUrl || value.url, 700);
  }
  const articlePath = location.pathname.replace(/\/$/, '');
  for (const link of [...document.querySelectorAll('a[href]')].slice(0, 3000)) {
    const label = clean(`${link.textContent || ''} ${link.getAttribute('aria-label') || ''} ${link.title || ''}`, 500);
    const href = safeURL(link.href);
    if (!href || /supplement|reporting summary|supporting information|download references/i.test(label) || /(?:MOESM|\/esm\/|supplement|supporting)/i.test(href)) continue;
    if (link.closest('[id^="MOESM"], [id*="supplement"], [class*="supplement"], [id*="references"]')) continue;
    const path = new URL(href).pathname;
    let score = /^download\s+(?:article\s+)?pdf$/i.test(label) ? 600 : /(?:download|view|full.?text).*pdf|^pdf$/i.test(label) ? 400 : 0;
    if (/\.pdf$/i.test(path) || /\/(?:e?pdf|showpdf)(?:\/|$)/i.test(path)) score += 100;
    if (score === 0) continue;
    if (articlePath.length > 8 && path.startsWith(articlePath)) score += 120;
    if (score >= 100) add(href, score);
  }
  candidates.sort((a, b) => b.score - a.score);
  const date = first('citation_publication_date', 'citation_online_date', 'dc.date', 'prism.publicationdate') || article.datePublished || '';
  const start = first('citation_firstpage', 'prism.startingpage') || article.pageStart;
  const end = first('citation_lastpage', 'prism.endingpage') || article.pageEnd;
  return {
    title: clean(first('citation_title', 'dc.title', 'og:title') || article.headline || document.querySelector('h1')?.textContent || document.title),
    doi: clean(first('citation_doi', 'prism.doi', 'dc.identifier') || article.sameAs, 200),
    pmid: clean(first('citation_pmid'), 20), authors,
    journal: clean(first('citation_journal_title', 'prism.publicationname') || article.isPartOf?.name, 500),
    publicationDate: clean(date, 30), abstract: clean(first('citation_abstract', 'dc.description', 'description', 'og:description') || article.description, 20000),
    volume: clean(first('citation_volume', 'prism.volume'), 100), issue: clean(first('citation_issue', 'prism.number'), 100),
    pages: clean(first('citation_pages') || [start, end].filter(Boolean).join('–'), 100),
    publisher: clean(first('citation_publisher', 'dc.publisher') || article.publisher?.name, 500),
    language: clean(first('citation_language', 'dc.language'), 30),
    issn: [...new Set([...all('citation_issn'), ...all('prism.issn')])].slice(0, 10),
    keywords: [...new Set([...all('citation_keywords').flatMap(v => v.split(/[;,]/)), ...all('dc.subject'), ...[].concat(article.keywords || [])])].map(v => clean(v, 200)).filter(Boolean).slice(0, 100),
    pdfURL: candidates[0]?.url || null
  };
}

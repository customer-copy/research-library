/* One click saves PDF bytes through a local helper; no remote extension service. */
const HOST = 'org.researchlibrary.chrome';
const MAX_PDF = 512 * 1024 * 1024;
const pending = new Set();
importScripts('capture-page.js');

function webURL(value, base) {
  try {
    const url = new URL(value, base);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.href.length > 8000) return null;
    return url.href;
  } catch { return null; }
}

function pdfResponse(url) {
  return fetch(url, {credentials: 'include', signal: AbortSignal.timeout(120000)});
}

function nativeStream() {
  const port = chrome.runtime.connectNative(HOST);
  let waiting, disconnected = false;
  port.onMessage.addListener(message => {
    if (!waiting) return;
    const current = waiting; waiting = null; clearTimeout(current.timer);
    if (message?.ok) current.resolve(message);
    else current.reject(new Error(message?.error || 'The PDF transfer failed.'));
  });
  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message || 'The local PDF helper disconnected.';
    disconnected = true;
    if (waiting) { clearTimeout(waiting.timer); waiting.reject(new Error(reason)); waiting = null; }
  });
  return {
    ask(message) {
      if (disconnected) return Promise.reject(new Error('The local PDF helper disconnected.'));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { waiting = null; reject(new Error('The PDF helper did not respond.')); }, 45000);
        waiting = {resolve, reject, timer};
        try { port.postMessage(message); } catch (error) { clearTimeout(timer); waiting = null; reject(error); }
      });
    },
    close() { port.disconnect(); }
  };
}

async function streamPDF(response, id) {
  if (!response.ok) throw new Error(`The website returned ${response.status}.`);
  if (Number(response.headers.get('content-length')) > MAX_PDF) throw new Error('PDF exceeds 512 MB.');
  const connection = nativeStream();
  const reader = response.body.getReader();
  let size = 0, prefix = '';
  try {
    await connection.ask({action: 'pdfStart', id});
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      if (size + value.length > MAX_PDF) throw new Error('PDF exceeds 512 MB.');
      if (prefix.length < 5) {
        prefix += new TextDecoder().decode(value.subarray(0, 5 - prefix.length));
        if (prefix.length >= 5 && prefix !== '%PDF-') throw new Error('This page did not return a PDF.');
      }
      // Bound native message size and memory independently of the total PDF size.
      for (let offset = 0; offset < value.length; offset += 512 * 1024) {
        const chunk = value.subarray(offset, offset + 512 * 1024);
        let binary = '';
        for (let i = 0; i < chunk.length; i += 32768) binary += String.fromCharCode(...chunk.subarray(i, i + 32768));
        const acknowledgement = await connection.ask({action: 'pdfChunk', id, offset: size, data: btoa(binary)});
        size += chunk.length;
        if (acknowledgement.offset !== size) throw new Error('PDF transfer acknowledgement was out of sequence.');
      }
    }
    if (prefix !== '%PDF-') throw new Error('The website returned an empty or invalid PDF.');
    return await connection.ask({action: 'pdfFinish', id});
  } catch (error) {
    await reader.cancel().catch(() => {});
    await connection.ask({action: 'pdfCancel', id}).catch(() => {});
    throw error;
  } finally { reader.releaseLock(); connection.close(); }
}

async function native(message) {
  let result;
  try { result = await chrome.runtime.sendNativeMessage(HOST, message); }
  catch { throw new Error('The local helper is unavailable. Run the installer in the ChromeExtension folder, then try again.'); }
  if (!result?.ok) throw new Error(result?.error || 'Research Library could not save this PDF.');
  return result;
}

async function badge(tabId, text, title, color) {
  await Promise.all([
    chrome.action.setBadgeText({tabId, text}),
    chrome.action.setBadgeBackgroundColor({tabId, color}),
    chrome.action.setTitle({tabId, title})
  ]).catch(() => {});
}

async function capture(tab) {
  if (!tab?.id || pending.has(tab.id)) return;
  const clickedAt = Date.now();
  pending.add(tab.id);
  await badge(tab.id, '…', 'Saving to Research Library…', '#526879');
  try {
    const url = webURL(tab.url);
    if (!url) throw new Error('Open a PDF or article in a normal web tab first. Local files and Chrome settings pages are not supported.');
    let metadata = {};
    try {
      metadata = (await chrome.scripting.executeScript({target: {tabId: tab.id}, func: citationMetadata}))[0]?.result || {};
    } catch { /* The built-in PDF viewer blocks injection; its web URL still works. */ }
    const pdfURL = webURL(metadata.pdfURL) || url;
    const id = crypto.randomUUID();
    const title = String(metadata.title || tab.title || 'Article').slice(0, 500);
    // Metadata is handed off before any publisher/network wait. Download in parallel.
    const transfer = pdfResponse(pdfURL).then(response => ({response}), error => ({error: error.message}));
    await native({action: 'beginCapture', id, url, pdfURL, metadata: {...metadata, title}, clickedAt});
    const addedAt = Date.now();
    await chrome.storage.local.set({lastResult: {ok: true, status: 'downloading', title,
      detail: 'Article metadata added to Research Library. Downloading the PDF…', date: new Date().toISOString(), addedMilliseconds: addedAt - clickedAt}});
    await badge(tab.id, '↓', 'Article added. Downloading PDF…', '#526879');
    const download = await transfer;
    let result, downloadError = download.error;
    if (download.response) {
      try { result = await streamPDF(download.response, id); } catch (error) { downloadError = error.message; }
    }
    if (!result) result = await native({action: 'captureFailed', id, error: downloadError});
    const detail = result.status === 'saved'
      ? 'PDF and page metadata saved to Research Library.'
      : `Article metadata saved. PDF download needs attention: ${downloadError}`;
    await chrome.storage.local.set({lastResult: {ok: true, status: result.status, detail,
      title, date: new Date().toISOString(), downloadError, addedMilliseconds: addedAt - clickedAt, totalMilliseconds: Date.now() - clickedAt}});
    await badge(tab.id, result.status === 'saved' ? '✓' : 'PDF?', detail, result.status === 'saved' ? '#28745a' : '#ad7532');
  } catch (error) {
    await chrome.storage.local.set({lastResult: {ok: false, detail: error.message, date: new Date().toISOString()}});
    await badge(tab.id, '!', error.message, '#ad3b36');
    await chrome.runtime.openOptionsPage();
  } finally { pending.delete(tab.id); }
}

chrome.action.onClicked.addListener(capture);
chrome.runtime.onInstalled.addListener(({reason}) => {
  if (reason === 'install') chrome.runtime.openOptionsPage();
});

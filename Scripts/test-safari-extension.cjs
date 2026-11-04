#!/usr/bin/env node
// Run local UI fixtures in a disposable headless browser; no Safari settings or user tabs change.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const playwright = require(process.env.RESEARCH_PLAYWRIGHT_MODULE || 'playwright');
const resources = path.resolve(__dirname, '../Apple/SafariExtension/Resources');
const source = name => fs.readFileSync(path.join(resources, name), 'utf8');

(async () => {
  const browser = await playwright.chromium.launch({headless: true,
    ...(process.env.RESEARCH_CHROME_EXECUTABLE ? {executablePath: process.env.RESEARCH_CHROME_EXECUTABLE} : {})});
  const checks = [];
  try {
    const page = await browser.newPage();
    await page.route('https://www.google.com/**', route => route.fulfill({contentType: 'text/html', body:
      '<main id="search"><a id="paper" href="https://publisher.example/paper"><h3>An article title</h3></a><a href="/url?q=https%3A%2F%2Fpublisher.example%2Fpaper.pdf"><h3>A PDF result</h3></a><a href="javascript:alert(1)"><h3>Unsafe link</h3></a><a href="/search?q=related"><h3>Google navigation</h3></a></main>'}));
    await page.goto('https://www.google.com/search?q=microscopy');
    await page.evaluate(() => {
      globalThis.captures = [];
      globalThis.failCapture = false;
      globalThis.browser = {runtime: {sendMessage: async payload => {
        captures.push(payload);
        return failCapture ? {ok: false, error: 'App unavailable'} : {ok: true, status: 'sent'};
      }}};
      // Retain closed shadow roots only in this test fixture for accessible UI assertions.
      const original = Element.prototype.attachShadow;
      Element.prototype.attachShadow = function(options) { return original.call(this, {...options, mode: 'open'}); };
    });
    await page.addScriptTag({content: source('capture.js')});
    await page.addScriptTag({content: source('google.js')});
    const buttons = page.locator('[data-research-library-capture] button');
    await buttons.first().waitFor();
    assert.equal(await buttons.count(), 2);
    checks.push('Article and Google redirect PDF links get buttons; unsafe and navigation links do not');
    await buttons.first().click();
    await page.waitForFunction(() => captures.length === 1);
    const first = await page.evaluate(() => captures[0]);
    assert.equal(first.url, 'https://publisher.example/paper');
    assert.equal(first.title, 'An article title');
    assert.match(first.id, /^[a-f0-9-]{36}$/);
    assert.equal(await buttons.first().textContent(), 'Sent ✓');
    assert.equal(await buttons.first().isDisabled(), true);
    assert.equal(page.url(), 'https://www.google.com/search?q=microscopy');
    checks.push('A trusted click hands off the result once without navigating away');
    await page.evaluate(() => { document.querySelector('#paper').href = 'https://publisher.example/new-paper'; });
    // Anchor href mutation is accompanied by heading mutation in Google; exercise both.
    await page.evaluate(() => { document.querySelector('#paper h3').textContent = 'Replacement article'; });
    await page.waitForFunction(() => document.querySelector('[data-research-library-capture]').shadowRoot.querySelector('button').textContent === '+ Research Library');
    await buttons.first().click();
    assert.equal(await page.evaluate(() => captures.at(-1).url), 'https://publisher.example/new-paper');
    checks.push('Reused Google result elements get a fresh save button');
    await page.evaluate(() => {
      failCapture = true;
      const link = document.createElement('a'); link.href = 'https://publisher.example/later';
      const heading = document.createElement('h3'); heading.textContent = 'Dynamically loaded result';
      link.append(heading); document.querySelector('#search').append(link);
    });
    await page.waitForFunction(() => document.querySelectorAll('[data-research-library-capture]').length === 3);
    await buttons.last().click();
    assert.equal(await buttons.last().textContent(), 'Retry save');
    const failedID = await page.evaluate(() => captures.at(-1).id);
    await page.evaluate(() => { failCapture = false; });
    await buttons.last().click();
    assert.equal(await page.evaluate(() => captures.at(-1).id), failedID);
    assert.equal(await buttons.last().textContent(), 'Sent ✓');
    checks.push('New results are detected, errors are visible, and retries reuse their capture ID');

    await page.setContent(source('popup.html').replace(/<script[^>]*>[\s\S]*?<\/script>/g, ''));
    await page.evaluate(() => {
      globalThis.captures = [];
      for (const [name, content] of Object.entries({citation_title: 'Citation title', citation_doi: '10.1146/test', citation_pmid: '1234', citation_pdf_url: 'https://publisher.example/article.pdf'})) {
        const meta = document.createElement('meta'); meta.name = name; meta.content = content; document.head.append(meta);
      }
      browser.tabs = {query: async () => [{id: 7, url: 'https://publisher.example/article', title: 'Fallback title'}]};
      browser.scripting = {executeScript: async ({func}) => [{result: func()}]};
    });
    await page.addScriptTag({content: source('capture.js')});
    await page.addScriptTag({content: source('popup.js')});
    await page.getByRole('button', {name: 'Save to Research Library'}).click();
    await page.waitForFunction(() => captures.length === 1);
    const payload = await page.evaluate(() => captures[0]);
    assert.equal(payload.title, 'Citation title');
    assert.equal(payload.doi, '10.1146/test');
    assert.equal(payload.pdfURL, 'https://publisher.example/article.pdf');
    checks.push('Toolbar captures publisher metadata and declared PDF links');

    await page.setContent(source('popup.html').replace(/<script[^>]*>[\s\S]*?<\/script>/g, ''));
    await page.evaluate(() => {
      captures = [];
      browser.tabs.query = async () => [{id: 8, url: 'https://publisher.example/file.pdf', title: 'PDF document'}];
      browser.scripting.executeScript = async () => { throw new Error('PDF viewer cannot inject scripts'); };
    });
    await page.addScriptTag({content: source('popup.js')});
    await page.getByRole('button', {name: 'Save to Research Library'}).click();
    await page.waitForFunction(() => captures.length === 1);
    assert.equal(await page.evaluate(() => captures[0].url), 'https://publisher.example/file.pdf');
    checks.push('PDF viewer capture succeeds without page script injection');
    if (process.env.RESEARCH_EXTENSION_SCREENSHOT) {
      await page.addStyleTag({content: source('popup.css')});
      await page.locator('header img').evaluate((image, svg) => {
        image.src = 'data:image/svg+xml;base64,' + btoa(svg);
      }, source('icon.svg'));
      await page.setViewportSize({width: 336, height: 350});
      await page.screenshot({path: process.env.RESEARCH_EXTENSION_SCREENSHOT});
    }
    console.log(JSON.stringify({passed: true, checks}, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });

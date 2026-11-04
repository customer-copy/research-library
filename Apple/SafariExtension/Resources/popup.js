(() => {
  const button = document.getElementById("save");
  const status = document.getElementById("status");
  let tab, id = crypto.randomUUID();
  const ready = browser.tabs.query({active: true, currentWindow: true}).then(tabs => {
    tab = tabs[0];
    if (!tab || !ResearchCapture.webURL(tab.url)) throw new Error("Open an article or PDF in a normal web tab first.");
    document.getElementById("title").textContent = tab.title || tab.url;
  }).catch(error => { button.disabled = true; status.textContent = error.message; });
  button.addEventListener("click", async () => {
    await ready;
    if (!tab || button.disabled) return;
    button.disabled = true; status.className = ""; status.textContent = "Sending…";
    try {
      let metadata = {};
      try {
        const results = await browser.scripting.executeScript({target: {tabId: tab.id}, func: () => {
          const meta = name => [...document.querySelectorAll("meta[name],meta[property]")]
            .find(node => (node.getAttribute("name") || node.getAttribute("property") || "").toLowerCase() === name)?.content;
          const pdf = meta("citation_pdf_url");
          return {title: meta("citation_title") || document.title,
            doi: meta("citation_doi"), pmid: meta("citation_pmid"),
            pdfURL: pdf ? new URL(pdf, location.href).href : undefined};
        }});
        metadata = results[0]?.result || {};
      } catch { /* Safari's built-in PDF viewer can disallow script injection; its URL still works. */ }
      const payload = {action: "capture", id, url: tab.url,
        title: String(metadata.title || tab.title || "").slice(0, 500)};
      if (typeof metadata.doi === "string" && metadata.doi.length <= 200) payload.doi = metadata.doi;
      if (typeof metadata.pmid === "string" && /^\d{1,9}$/.test(metadata.pmid)) payload.pmid = metadata.pmid;
      const pdfURL = metadata.pdfURL && ResearchCapture.webURL(metadata.pdfURL);
      if (pdfURL) payload.pdfURL = pdfURL;
      const response = await browser.runtime.sendMessage(payload);
      if (!response?.ok) throw new Error(response?.error || "Could not send this page.");
      button.textContent = "Sent ✓";
      status.textContent = "Sent to Research Library. Your Inbox will retrieve metadata and available PDFs.";
    } catch (error) {
      status.className = "error"; status.textContent = error.message;
      button.disabled = false; button.textContent = "Retry save";
    }
  });
})();

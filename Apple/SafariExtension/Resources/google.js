(() => {
  const marked = new WeakMap();
  let scheduled = false;
  function scan() {
    scheduled = false;
    for (const heading of document.querySelectorAll("#search h3, #rso h3")) {
      const link = heading.closest("a[href]");
      if (!link || !link.isConnected) continue;
      const url = ResearchCapture.resultURL(link.href, location.href);
      const existing = marked.get(link);
      if (existing?.host.isConnected) {
        if (existing.url === url) continue;
        // Google can reuse an anchor for a different result during live searches.
        existing.host.remove(); marked.delete(link);
      }
      if (!url) continue;
      const host = document.createElement("span");
      host.dataset.researchLibraryCapture = "true";
      const shadow = host.attachShadow({mode: "closed"});
      const style = document.createElement("style");
      style.textContent = ":host{display:inline-block;margin:4px 0 8px 8px;vertical-align:middle}button{font:12px system-ui;color:#17664a;background:#edf8f2;border:1px solid #91bda7;border-radius:14px;padding:4px 10px;cursor:pointer}button:focus-visible{outline:2px solid #17664a;outline-offset:2px}button:disabled{cursor:default;opacity:.8}@media(prefers-color-scheme:dark){button{color:#ade5c5;background:#163b2c;border-color:#47775b}}";
      const button = document.createElement("button");
      button.type = "button"; button.textContent = "+ Research Library";
      button.setAttribute("aria-label", "Send this result to Research Library");
      const entry = {host, url, id: null};
      button.addEventListener("click", async event => {
        event.preventDefault(); event.stopPropagation();
        if (!event.isTrusted || !entry.url || button.disabled) return;
        entry.id ||= crypto.randomUUID();
        button.disabled = true; button.textContent = "Sending…";
        try {
          const response = await browser.runtime.sendMessage({action: "capture", id: entry.id,
            url: entry.url, title: heading.textContent.trim().slice(0, 500)});
          if (!response?.ok) throw new Error(response?.error || "Could not send this result.");
          button.textContent = "Sent ✓";
          button.title = "Sent to Research Library for Inbox processing.";
        } catch (error) {
          button.textContent = "Retry save"; button.title = error.message; button.disabled = false;
        }
      });
      shadow.append(style, button); link.insertAdjacentElement("afterend", host);
      marked.set(link, entry);
    }
  }
  const observer = new MutationObserver(() => {
    if (!scheduled) { scheduled = true; setTimeout(scan, 150); }
  });
  observer.observe(document.documentElement, {childList: true, subtree: true});
  scan();
})();

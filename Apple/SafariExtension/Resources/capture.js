(() => {
  const webURL = (value, base) => {
    try {
      const url = new URL(value, base);
      if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.href.length > 8000) return null;
      return url.href;
    } catch { return null; }
  };
  const resultURL = (value, base) => {
    const valid = webURL(value, base);
    if (!valid) return null;
    const url = new URL(valid);
    if (/^(www\.)?google\./.test(url.hostname)) {
      if (url.pathname !== "/url") return null;
      return webURL(url.searchParams.get("q") || url.searchParams.get("url"));
    }
    return valid;
  };
  globalThis.ResearchCapture = { webURL, resultURL };
})();

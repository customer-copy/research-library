function showResult(lastResult) {
  if (!lastResult) return;
  const section = document.getElementById('result');
  section.hidden = false;
  section.classList.toggle('error', !lastResult.ok);
  document.getElementById('detail').textContent = lastResult.detail;
  document.getElementById('paper').textContent = lastResult.title || '';
}
chrome.storage.local.get('lastResult').then(({lastResult}) => showResult(lastResult));
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.lastResult) showResult(changes.lastResult.newValue);
});
chrome.runtime.sendNativeMessage('org.researchlibrary.chrome', {action: 'status', id: crypto.randomUUID()})
  .then(result => {
    document.getElementById('setup').open = !result?.ok;
    document.getElementById('destination').textContent = result?.ok
      ? `Destination: ${result.inbox}` : result?.error || 'Run the local helper installer to finish setup.';
  }).catch(() => {
    document.getElementById('setup').open = true;
    document.getElementById('destination').textContent = 'Run the local helper installer to finish setup.';
  });

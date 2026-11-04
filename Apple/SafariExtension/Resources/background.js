browser.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== browser.runtime.id || message?.action !== "capture") return;
  return browser.runtime.sendNativeMessage("org.researchlibrary.mac", message)
    .then(response => response || {ok: false, error: "Research Library did not respond."})
    .catch(() => ({ok: false, error: "Could not reach Research Library. Open the app and try again."}));
});

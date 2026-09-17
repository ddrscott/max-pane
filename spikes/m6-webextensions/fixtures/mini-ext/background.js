chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  sendResponse({ from: "background", ua: navigator.userAgent });
  return true;
});

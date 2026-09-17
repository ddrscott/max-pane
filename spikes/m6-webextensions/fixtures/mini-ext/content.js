// Stamp at document_start, then again with the background's answer, so the
// report can tell "injected" from "injected and reached the background".
document.documentElement.dataset.m6 = "content-script-ran";
try {
  chrome.runtime.sendMessage({ hello: "background" }, (reply) => {
    document.documentElement.dataset.m6bg = (reply && reply.from) || ("no-reply:" + (chrome.runtime.lastError && chrome.runtime.lastError.message));
  });
} catch (e) {
  document.documentElement.dataset.m6bg = "sendMessage threw: " + e;
}

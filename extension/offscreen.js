// Clears the clipboard after a code was copied (MV3 service workers can't touch the clipboard).
chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.target !== "offscreen" || msg.type !== "clear") return;
  const t = document.getElementById("t");
  t.value = " ";
  t.select();
  document.execCommand("copy");
});

const $ = (id) => document.getElementById(id);
let ac = null, player = null;

function setState(live, text) { $("state").classList.toggle("live", live); $("stateText").textContent = text; }

function preview(linkText) {
  ac?.abort(); ac = null; player?.close(); player = null;
  const l = LiveCharPlayer.parseLink(linkText);
  $("err").hidden = !linkText || !!l;
  $("err").textContent = "That doesn't look like a LiveChar live link (…/watch/…)";
  if (!l) { setState(false, linkText ? "Bad link" : "No link yet"); return; }
  player = LiveCharPlayer.create($("v"), { waitingText: "Waiting for your iPhone…",
    onState: (s) => setState(s === "live", s === "live" ? "LIVE" : "Waiting for the iPhone to go live") });
  ac = new AbortController();
  LiveCharPlayer.follow(l.stream, player.push, { signal: ac.signal, onStatus: (s) => {
    if (s === "unknown") setState(false, "This link was reset — copy the new one");
    else if (s === "offline") setState(false, "Can't reach the server");
  } });
}

chrome.storage.local.get({ enabled: true, link: "", replaceAll: true }, (v) => {
  $("link").value = v.link; $("enabled").checked = v.enabled; $("replaceAll").checked = v.replaceAll;
  preview(v.link);
});
$("link").addEventListener("change", () => {
  const link = $("link").value.trim();
  chrome.storage.local.set({ link });
  preview(link);
});
$("enabled").addEventListener("change", () => chrome.storage.local.set({ enabled: $("enabled").checked }));
$("replaceAll").addEventListener("change", () => chrome.storage.local.set({ replaceAll: $("replaceAll").checked }));

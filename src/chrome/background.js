// Chrome-extension service worker. Two jobs the content script cannot do
// itself:
//   1. Translation fetches — content scripts follow the page's CORS rules, and
//      the unofficial translate endpoint sends no CORS headers, so the fetch
//      must happen here, where host_permissions (see manifest.json) exempt it.
//   2. Song-change notifications — chrome.notifications is extension-only, and
//      unlike the page's Notification API it needs no permission prompt.

// Only proxy the one endpoint the extension actually uses — anything else is
// rejected so this worker can't be used as a general-purpose fetch proxy.
const ALLOWED_URL_PREFIX = "https://translate.googleapis.com/translate_a/single?";

// Reusing one id means each song replaces the previous notification rather
// than stacking a new one per track.
const SONG_NOTIFICATION_ID = "bs-song-change";

function showSongNotification(message, sendResponse) {
  const fallbackIcon = chrome.runtime.getURL("icons/icon128.png");
  const build = (iconUrl) => ({
    type: "basic",
    title: String(message.title || "Now playing"),
    message: String(message.body || ""),
    iconUrl,
    silent: true,
  });

  const create = (iconUrl, onFailure) => {
    chrome.notifications.create(SONG_NOTIFICATION_ID, build(iconUrl), () => {
      const error = chrome.runtime.lastError;
      if (error) onFailure(error);
      else sendResponse({ ok: true });
    });
  };

  const artwork = typeof message.iconUrl === "string" ? message.iconUrl : "";
  if (!artwork) {
    create(fallbackIcon, (error) => sendResponse({ ok: false, error: error.message }));
    return;
  }
  // Album art comes from Spotify's CDN and can fail to load (offline, blocked
  // image, changed host) — retry once with the bundled icon so a bad artwork
  // URL never costs the user the notification itself.
  create(artwork, () => create(fallbackIcon, (error) => sendResponse({ ok: false, error: error.message })));
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "bs-notify") {
    showSongNotification(message, sendResponse);
    return true; // keep sendResponse alive for the async create
  }

  if (
    message?.type !== "bs-translate" ||
    typeof message.url !== "string" ||
    !message.url.startsWith(ALLOWED_URL_PREFIX)
  ) {
    sendResponse({ ok: false, error: "Rejected request" });
    return false;
  }

  fetch(message.url)
    .then((response) => {
      if (!response.ok) {
        sendResponse({ ok: false, status: response.status, error: `HTTP ${response.status}` });
        return;
      }
      return response.json().then((payload) => sendResponse({ ok: true, payload }));
    })
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true; // keep sendResponse alive for the async fetch
});

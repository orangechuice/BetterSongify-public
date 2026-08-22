(() => {
  "use strict";

  const SETTINGS_KEY = "better_songify_settings";
  const CACHE_KEY = "better_songify_translations_v3";

  // Legacy settings blob keys (SpotifyLyrics / BetterSpotify) carried over
  // into SETTINGS_KEY once by loadSettings.
  const PRE_RENAME_SETTINGS_KEYS = [
    "better_spotify_settings",
    "spotify_lyrics_settings",
  ];

  // Pre-blob per-setting localStorage keys, deleted by migrateLegacySettings
  // on first load. Values are folded into the blob only when the setting
  // still exists in DEFAULTS; entries for since-removed settings stay listed
  // here purely so their stale keys get cleaned up. Do not add new entries —
  // new settings only ever live in the blob.
  const LEGACY_SETTING_KEYS = {
    targetLang: "spotify_lyrics_lang",
    currentMode: "spotify_lyrics_mode",
    highlightTranslation: "spotify_lyrics_highlight",
    highlightTransliteration: "spotify_lyrics_r_highlight",
    showTransliteration: "spotify_lyrics_romaji",
    preferVideo: "spotify_lyrics_prefer_video",
    subtextOpacity: "spotify_lyrics_g_opacity",
    subtextScale: "spotify_lyrics_g_scale",
    subtextColor: "spotify_lyrics_g_color",
    subtextItalic: "spotify_lyrics_g_italic",
  };

  // Superseded cache keys; wiped on load rather than migrated (caches refill on play).
  const LEGACY_CACHE_KEYS = [
    "spotify_lyrics_cache",
    "spotify_lyrics_cache_v2",
    "spotify_lyrics_translations_v3",
    "better_spotify_translations_v3",
  ];

  const DEFAULTS = {
    targetLang: "en",
    showOriginal: true,
    showTranslation: true,
    showTransliteration: true,
    preferVideo: false,
    preferVideoExpanded: false,
    autoOpenLyrics: false,
    hideRecommendations: false,
    hideHomeAudiobooks: false,
    hideHomePodcasts: false,
    songChangeNotifications: false,
    // Desktop only: visibility of the companion app's menu-bar item. Default
    // on, matching the companion's own fallback when it has never been told.
    menuBarSong: true,
    lyricsScale: 100,
    lyricsFont: "",
  };

  // Lyrics font choices. System font stacks only — loading webfonts would hit
  // the page CSP on the desktop client. Values are stored verbatim in the
  // settings blob; "" means leave Spotify's own font untouched.
  const LYRIC_FONTS = [
    { label: "App Default", value: "" },
    { label: "Serif", value: "Georgia, 'Times New Roman', serif" },
    { label: "Sans Serif", value: "Arial, 'Helvetica Neue', sans-serif" },
    { label: "Rounded", value: "ui-rounded, 'Arial Rounded MT Bold', 'Hiragino Maru Gothic ProN', sans-serif" },
    { label: "Monospace", value: "'SF Mono', Menlo, Consolas, 'Cascadia Mono', monospace" },
    { label: "Handwritten", value: "'Segoe Print', 'Bradley Hand', 'Comic Sans MS', cursive" },
  ];

  // Spotify DOM coupling — undocumented and can change in any Spotify release.
  // Verified against the desktop client July 2026. If a feature silently stops
  // working, re-derive these via open.spotify.com devtools: the web player runs
  // the same xpui codebase and the same data-testids.
  const SELECTORS = {
    lyricsContainer: "[data-testid=\"lyrics-container\"]",
    lyricsLine: "[data-testid=\"lyrics-line\"]",
    lyricsButton: "[data-testid=\"lyrics-button\"]",
    playerBar: "[data-testid=\"now-playing-bar\"], footer, .Root__now-playing-bar",
    // Player-bar track title/artist. Also the track-change signal for
    // auto-open lyrics (lyric-line hashing only works with lyrics open).
    nowPlayingTitle: "[data-testid=\"context-item-info-title\"]",
    nowPlayingArtist: "[data-testid=\"context-item-info-artist\"]",
    // Player-bar album art, used only as the song-change notification's icon.
    // Strictly best-effort: getNowPlayingArtwork() falls back to scanning the
    // player bar for an i.scdn.co image, and a miss just means an icon-less
    // notification (Chrome substitutes the extension icon) — never a missing
    // notification. Unverified against July 2026 Spotify.
    nowPlayingCoverArt: "[data-testid=\"cover-art-image\"], [data-testid=\"now-playing-image\"] img",
    // The app's main content pane. Zero width ⇔ the expanded Now Playing
    // view is covering it (verified on open.spotify.com July 2026) — the
    // "already expanded" signal for enforceVideoExpanded.
    mainView: "main",
    // Despite the singular testid, this is the single wrapper around the
    // whole "Recommended" section at the bottom of editable playlists
    // (header, Refresh button, and its virtualized track-list). Verified on
    // open.spotify.com July 2026; secondary hook if the testid dies:
    // div.playlistRecommenderContainer just inside it.
    playlistRecommendations: "[data-testid=\"recommended-track\"]",
    // Home-screen recommendation shelves. The home route's own wrapper scopes
    // everything below to Home (component-shelf also renders on artist/search
    // pages, which these toggles deliberately leave alone); each shelf is one
    // horizontal row with a heading, and each tile inside it is an encore card.
    // Verified on the desktop client August 2026.
    homePage: "section[data-testid=\"home-page\"]",
    homeShelf: "section[data-testid=\"component-shelf\"]",
    homeCard: "div[data-encore-id=\"card\"]",
    // Card entity type is read off the tile's own link. Music types are listed
    // so a shelf mixing music with a stray show isn't hidden wholesale.
    homeMusicLink: "a[href^=\"/playlist/\"], a[href^=\"/album/\"], a[href^=\"/artist/\"], a[href^=\"/track/\"]",
  };

  // Audiobooks and podcasts are indistinguishable by link: both are
  // `spotify:show:` / `/show/<id>` (verified against the desktop client and
  // the search view's own "Podcast"/"Audiobook" labels, August 2026). The one
  // discriminator in the DOM is the cover-art namespace — audiobook covers are
  // ab676663, podcast covers ab676563 (and ab6772ab for some shows). Matching
  // audiobooks positively and treating every other /show/ tile as a podcast
  // means a future podcast cover namespace still gets hidden; the cost is that
  // a new audiobook namespace would read as a podcast.
  const AUDIOBOOK_COVER_PATTERN = "i.scdn.co/image/ab676663";

  const LANGUAGE_CODES = [
    "af", "sq", "am", "ar", "hy", "as", "ay", "az", "bm", "eu", "be", "bn", "bho", "bs", "bg", "ca",
    "ceb", "ny", "zh-CN", "zh-TW", "co", "hr", "cs", "da", "dv", "doi", "nl", "en", "eo", "et", "ee",
    "tl", "fi", "fr", "fy", "gl", "ka", "de", "el", "gn", "gu", "ht", "ha", "haw", "he", "hi", "hmn",
    "hu", "is", "ig", "ilo", "id", "ga", "it", "ja", "jv", "kn", "kk", "km", "rw", "kok", "ko", "kri",
    "ku", "ckb", "ky", "lo", "la", "lv", "ln", "lt", "lg", "lb", "mk", "mai", "mg", "ms", "ml", "mt",
    "mi", "mr", "mni-Mtei", "lus", "mn", "my", "ne", "no", "or", "om", "ps", "fa", "pl", "pt", "pa",
    "qu", "ro", "ru", "sm", "sa", "gd", "sr", "st", "sn", "sd", "si", "sk", "sl", "so", "es", "su",
    "sw", "sv", "tg", "ta", "tt", "te", "th", "ti", "ts", "tr", "tk", "ak", "uk", "ur", "ug", "uz",
    "vi", "cy", "xh", "yi", "yo", "zu",
  ];

  const LANGUAGE_LABEL_OVERRIDES = {
    "zh-CN": "Chinese (Simplified)",
    "zh-TW": "Chinese (Traditional)",
    ckb: "Kurdish (Sorani)",
    ku: "Kurdish (Kurmanji)",
    "mni-Mtei": "Meiteilon (Manipuri)",
    my: "Myanmar (Burmese)",
    ny: "Chichewa",
    or: "Odia (Oriya)",
    gd: "Scots Gaelic",
    st: "Sesotho",
    tl: "Filipino (Tagalog)",
    ak: "Twi",
  };

  const LANGUAGE_DISPLAY_NAMES = (() => {
    try {
      return new Intl.DisplayNames(["en"], { type: "language" });
    } catch {
      return null;
    }
  })();

  const state = {
    translations: new Map(),
    pending: new Set(),
    cache: loadCache(),
    transcript: [],
    currentSongTitle: "",
    currentArtist: "",
    trackKey: "",
    lineObserver: null,
    uiPlacementTimer: null,
    lastLyricsAutoOpenKey: "",
    lyricsOpenDeferKey: "",
    lyricsOpenDeferUntil: 0,
    lastExpandAutoKey: "",
    lastExpandAutoClick: 0,
    expandAutoClickKey: "",
    expandAutoClickCount: 0,
    lastVideoAutoClick: 0,
    videoAutoClickKey: "",
    videoAutoClickCount: 0,
    startedAt: 0,
    notifiedTrackKey: "",
    notifyPendingKey: "",
    notifyTimer: null,
    videoObserver: null,
    videoRafQueued: false,
    rafQueued: false,
  };

  const settingsData = loadSettings();

  const appSettings = Object.defineProperties(
    {},
    Object.fromEntries(
      Object.keys(DEFAULTS).map((key) => [
        key,
        {
          get() {
            return settingsData[key];
          },
          set(value) {
            settingsData[key] = value;
            persistSettings();
          },
        },
      ]),
    ),
  );

  function readStorage(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function writeStorage(key, value) {
    try {
      localStorage.setItem(key, String(value));
    } catch {}
  }

  function removeStorage(key) {
    try {
      localStorage.removeItem(key);
    } catch {}
  }

  function loadSettings() {
    try {
      // One-time carry-over of pre-rename settings blobs (BetterSpotify, SpotifyLyrics).
      let raw = readStorage(SETTINGS_KEY);
      if (raw === null) {
        for (const key of PRE_RENAME_SETTINGS_KEYS) {
          raw = readStorage(key);
          if (raw !== null) {
            writeStorage(SETTINGS_KEY, raw);
            break;
          }
        }
      }
      PRE_RENAME_SETTINGS_KEYS.forEach(removeStorage);
      const stored = JSON.parse(raw);
      if (stored && typeof stored === "object") {
        // Only keys still in DEFAULTS survive, so removed settings fall out
        // of the blob on the next persist.
        const data = { ...DEFAULTS };
        Object.keys(DEFAULTS).forEach((key) => {
          if (key in stored) data[key] = stored[key];
        });
        // Blobs written before July 2026 stored a three-way view mode
        // (lyrics/dual/translation) instead of the showOriginal/
        // showTranslation pair; map it once so users keep their mode.
        if (!("showOriginal" in stored) && typeof stored.currentMode === "string") {
          data.showOriginal = stored.currentMode !== "translation";
          data.showTranslation = stored.currentMode !== "lyrics";
        }
        return data;
      }
    } catch {}
    return migrateLegacySettings();
  }

  function migrateLegacySettings() {
    const migrated = { ...DEFAULTS };
    Object.entries(LEGACY_SETTING_KEYS).forEach(([name, key]) => {
      const value = readStorage(key);
      removeStorage(key);
      if (value === null || !(name in DEFAULTS)) return;
      migrated[name] = typeof DEFAULTS[name] === "boolean" ? value === "true" : value;
    });
    writeStorage(SETTINGS_KEY, JSON.stringify(migrated));
    return migrated;
  }

  function persistSettings() {
    writeStorage(SETTINGS_KEY, JSON.stringify(settingsData));
  }

  function loadCache() {
    try {
      LEGACY_CACHE_KEYS.forEach(removeStorage);
      return new Map(Object.entries(JSON.parse(readStorage(CACHE_KEY) || "{}")));
    } catch {
      return new Map();
    }
  }

  function saveCache() {
    const cache = {};
    [...state.cache.entries()].slice(-1000).forEach(([key, value]) => {
      cache[key] = value;
    });
    writeStorage(CACHE_KEY, JSON.stringify(cache));
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[char];
    });
  }

  function getLanguageLabel(code) {
    if (LANGUAGE_LABEL_OVERRIDES[code]) return LANGUAGE_LABEL_OVERRIDES[code];
    try {
      return LANGUAGE_DISPLAY_NAMES?.of(code) || code;
    } catch {
      return code;
    }
  }

  function notify(message) {
    let toast = document.getElementById("better-songify-toast");
    if (!toast) {
      toast = document.createElement("div");
      toast.id = "better-songify-toast";
      document.body.appendChild(toast);
    }
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(toast.timeoutId);
    toast.timeoutId = setTimeout(() => toast.classList.remove("show"), 3000);
  }

  function ensureBaseStyles() {
    let style = document.getElementById("better-songify-styles");
    if (!style) {
      style = document.createElement("style");
      style.id = "better-songify-styles";
      document.head.appendChild(style);
    }
    style.textContent = `
      @keyframes betterSongifySlideIn { from { transform: translateX(20px); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
      [data-testid="lyrics-line"] { position: relative; }
      /* Lyrics style controls. zoom (not font-size) so text and spacing scale
         together without knowing Spotify's responsive base size; the CSS vars
         and data attributes are set on body by applyLyricsAppearance(). */
      [data-testid="lyrics-line"] { zoom: var(--bs-lyrics-scale, 1); }
      body[data-bs-font] [data-testid="lyrics-line"] { font-family: var(--bs-lyrics-font) !important; }
      /* "Recommended" section at the bottom of editable playlists — see
         SELECTORS.playlistRecommendations (CSS cannot read that constant;
         keep the two in sync). */
      body[data-bs-hide-recs] [data-testid="recommended-track"] { display: none !important; }
      /* Home audiobook/podcast filtering — see SELECTORS.homePage/homeShelf/
         homeCard/homeMusicLink and AUDIOBOOK_COVER_PATTERN (CSS cannot read
         those constants; keep the two in sync). Each type gets two rules: the
         whole shelf when it holds nothing but that type (leaving a bare
         heading over an empty row would look broken), and the individual card
         for shelves that mix the type in with music. */
      body[data-bs-hide-audiobooks] section[data-testid="home-page"] section[data-testid="component-shelf"]:has(a[href^="/show/"]):has(img[src*="i.scdn.co/image/ab676663"]):not(:has(a[href^="/playlist/"], a[href^="/album/"], a[href^="/artist/"], a[href^="/track/"])) { display: none !important; }
      body[data-bs-hide-audiobooks] section[data-testid="home-page"] div[data-encore-id="card"]:has(a[href^="/show/"]):has(img[src*="i.scdn.co/image/ab676663"]) { display: none !important; }
      body[data-bs-hide-podcasts] section[data-testid="home-page"] section[data-testid="component-shelf"]:has(a[href^="/show/"], a[href^="/episode/"]):not(:has(img[src*="i.scdn.co/image/ab676663"])):not(:has(a[href^="/playlist/"], a[href^="/album/"], a[href^="/artist/"], a[href^="/track/"])) { display: none !important; }
      body[data-bs-hide-podcasts] section[data-testid="home-page"] div[data-encore-id="card"]:has(a[href^="/show/"]):not(:has(img[src*="i.scdn.co/image/ab676663"])) { display: none !important; }
      body[data-bs-hide-podcasts] section[data-testid="home-page"] div[data-encore-id="card"]:has(a[href^="/episode/"]) { display: none !important; }
      body[data-bs-hide-original] [data-testid="lyrics-line"] > :not([data-bs-annotation="lyrics"]) { display: none !important; }
      .bs-lyric-note { box-sizing: border-box; display: block; width: 100%; margin-top: 6px; color: inherit; font: inherit; letter-spacing: inherit; line-height: inherit; opacity: inherit; pointer-events: none; }
      .bs-note-line { display: block; max-width: 100%; color: inherit; font-family: inherit; font-style: italic; font-weight: inherit; line-height: inherit; letter-spacing: inherit; overflow-wrap: anywhere; }
      .bs-note-pronunciation { font-size: .78em; opacity: .9; }
      .bs-note-meaning { font-size: .86em; opacity: .82; }
      body[data-bs-hide-translation] .bs-note-meaning { display: none !important; }
      .bs-caption-missing { opacity: .55 !important; }
      #better-songify-toast { position: fixed; right: 24px; bottom: 86px; z-index: 99999; padding: 10px 14px; border-radius: 8px; background: #282828; color: #fff; font-size: 13px; opacity: 0; transform: translateY(8px); pointer-events: none; transition: .2s ease; box-shadow: 0 8px 24px rgba(0,0,0,.35); }
      #better-songify-toast.show { opacity: 1; transform: translateY(0); }
      #better-songify-panel-aside { position: fixed; top: 16px; right: 16px; bottom: 104px; z-index: 100000; width: 340px; max-width: calc(100vw - 32px); min-width: 280px; display: none; flex-direction: column; background: #121212; color: #fff; border: 1px solid rgba(255,255,255,.08); border-radius: 8px; box-shadow: 0 16px 48px rgba(0,0,0,.45); overflow: hidden; animation: betterSongifySlideIn .18s ease-out; }
      #better-songify-panel-aside.open { display: flex; }
      .better-songify-panel-header { padding: 18px 18px 12px; display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .better-songify-panel-title { color: #1ed760; font-weight: 800; font-size: 24px; letter-spacing: 0; }
      .better-songify-panel-body { flex: 1; display: flex; flex-direction: column; gap: 18px; overflow: auto; padding: 0 18px 18px; }
      .better-songify-section { display: flex; flex-direction: column; gap: 10px; }
      .better-songify-section-title { color: #b3b3b3; font-size: 12px; font-weight: 700; text-transform: uppercase; }
      .better-songify-row { min-height: 40px; display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 10px; background: rgba(255,255,255,.055); border-radius: 8px; }
      .better-songify-row-label { min-width: 0; color: #fff; font-size: 13px; }
      .better-songify-row-sub { background: rgba(255,255,255,.035); }
      .better-songify-row-disabled { opacity: .45; pointer-events: none; }
      .better-songify-toggle { position: relative; display: inline-flex; width: 42px; height: 24px; flex: 0 0 auto; }
      .better-songify-toggle input { opacity: 0; position: absolute; inset: 0; cursor: pointer; }
      .better-songify-toggle-track { position: absolute; inset: 0; border-radius: 999px; background: #535353; transition: .2s; }
      .better-songify-toggle-knob { position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; transition: .2s; }
      .better-songify-toggle input:checked ~ .better-songify-toggle-track { background: #1ed760; }
      .better-songify-toggle input:checked ~ .better-songify-toggle-knob { transform: translateX(18px); }
      .better-songify-select { width: 100%; min-height: 34px; border: 1px solid rgba(255,255,255,.12); border-radius: 8px; background: #242424; color: #fff; padding: 0 8px; }
      .better-songify-row .better-songify-select { width: auto; flex: 1; min-width: 0; }
      .better-songify-range { flex: 1; min-width: 0; accent-color: #1ed760; cursor: pointer; }
      .better-songify-range-value { flex: 0 0 auto; min-width: 42px; text-align: right; color: #b3b3b3; font-size: 12px; font-variant-numeric: tabular-nums; }
      .better-songify-btn { min-height: 38px; border: 0; border-radius: 8px; padding: 0 12px; font-weight: 800; cursor: pointer; transition: background .15s ease, transform .1s ease, opacity .15s ease; }
      .better-songify-btn:disabled { opacity: .65; cursor: progress; }
      .better-songify-btn:hover:not(:disabled) { transform: scale(1.02); }
      .better-songify-btn:active:not(:disabled) { transform: scale(0.98); }
      .better-songify-btn-primary { background: #1ed760; color: #000; }
      .better-songify-btn-primary:hover:not(:disabled) { background: #3be477; }
      .better-songify-btn-secondary { background: rgba(255,255,255,.1); color: #fff; }
      .better-songify-btn-secondary:hover:not(:disabled) { background: rgba(255,255,255,.2); color: #fff; }
      .better-songify-btn-text { background: none; color: #b3b3b3; border: 0; cursor: pointer; transition: color .15s ease; }
      .better-songify-btn-text:hover { color: #fff; }
      #better-songify-tab-btn { background: transparent; border: none; cursor: pointer; padding: 8px 16px; margin: 0 8px; font-family: inherit; font-weight: 700; font-size: 14px; color: #b3b3b3; border-radius: 20px; transition: all .2s cubic-bezier(.4,0,.2,1); outline: none; }
      #better-songify-tab-btn:hover { color: #fff; background: rgba(255,255,255,.1); }
      #better-songify-tab-btn.active { color: #000 !important; background: #fff !important; }
      @media (max-width: 900px) { #better-songify-panel-aside { top: 12px; right: 12px; bottom: 92px; width: calc(100vw - 24px); max-width: none; min-width: 0; } }
    `;
  }

  function updateBodyMode() {
    const body = document.body;
    if (appSettings.showOriginal) {
      delete body.dataset.bsHideOriginal;
    } else {
      body.dataset.bsHideOriginal = "true";
    }
    if (appSettings.showTranslation) {
      delete body.dataset.bsHideTranslation;
    } else {
      body.dataset.bsHideTranslation = "true";
    }
    applyLyricsAppearance();
  }

  // Pushes the style settings onto body as CSS vars/attributes; the rules in
  // ensureBaseStyles do the actual work. Runs on every refresh (cheap), so a
  // Spotify re-render can never leave the styling stale for long.
  function applyLyricsAppearance() {
    const body = document.body;
    const scale = Number(appSettings.lyricsScale) || 100;
    body.style.setProperty("--bs-lyrics-scale", String(scale / 100));

    if (appSettings.lyricsFont) {
      body.style.setProperty("--bs-lyrics-font", appSettings.lyricsFont);
      body.dataset.bsFont = "custom";
    } else {
      body.style.removeProperty("--bs-lyrics-font");
      delete body.dataset.bsFont;
    }

    if (appSettings.hideRecommendations) {
      body.dataset.bsHideRecs = "true";
    } else {
      delete body.dataset.bsHideRecs;
    }

    if (appSettings.hideHomeAudiobooks) {
      body.dataset.bsHideAudiobooks = "true";
    } else {
      delete body.dataset.bsHideAudiobooks;
    }

    if (appSettings.hideHomePodcasts) {
      body.dataset.bsHidePodcasts = "true";
    } else {
      delete body.dataset.bsHidePodcasts;
    }
  }

  function getLyricsLines() {
    return [...document.querySelectorAll(SELECTORS.lyricsLine)];
  }

  function getLineText(line) {
    const clone = line.cloneNode(true);
    clone.querySelectorAll("[data-bs-annotation=\"lyrics\"]").forEach((node) => node.remove());
    const raw = clone.textContent;
    return raw.replace(/\s+/g, " ").trim();
  }

  function lineId(text, index) {
    return `${index}:${text}`;
  }

  function hashText(text) {
    // FNV-1a, 32-bit
    let hash = 0x811c9dc5;
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(36);
  }

  function getTrackKey(lines = getLyricsLines()) {
    return hashText(`${appSettings.targetLang}|${lines.map(getLineText).join("\n")}`);
  }

  // True in the Chrome-extension build, false in the injected desktop build —
  // the one runtime branch both worker-backed features key off (translation
  // fetches and song-change notifications).
  function isExtensionRuntime() {
    return typeof chrome !== "undefined" && !!chrome.runtime?.id;
  }

  // In the Chrome-extension build, content scripts are subject to the page's
  // CORS rules and cannot fetch translate.googleapis.com directly; the
  // background service worker (src/chrome/background.js) performs the fetch
  // under host_permissions instead. The injected desktop build has no
  // chrome.runtime.id and keeps fetching directly, as before.
  function fetchTranslationPayload(url) {
    if (isExtensionRuntime()) {
      return chrome.runtime.sendMessage({ type: "bs-translate", url }).then((reply) => {
        if (!reply?.ok) throw new Error(reply?.error || "Translation request failed");
        return reply.payload;
      });
    }
    return fetch(url).then((response) => response.json());
  }

  function parseGoogleTranslatePayload(payload) {
    if (!payload || !payload[0]) return null;

    let translated = "";
    let roman = "";
    payload[0].forEach((part) => {
      if (part[0] !== null && part[0] !== undefined) translated += part[0];
      if ((part[0] === null || part[0] === undefined) && part.length > 3 && part[3]) {
        roman += part[3];
      }
    });

    return { text: translated.trim(), romaji: roman.trim() };
  }

  const TRANSLATION_PROVIDERS = {
    googleAuto: {
      async translate(text, targetLang) {
        const url = new URL("https://translate.googleapis.com/translate_a/single");
        const params = new URLSearchParams();
        params.set("client", "gtx");
        params.set("sl", "auto");
        params.set("tl", targetLang);
        params.append("dt", "t");
        params.append("dt", "rm");
        params.set("q", text);
        url.search = params.toString();
        return parseGoogleTranslatePayload(await fetchTranslationPayload(url.toString()));
      },
    },
  };

  async function translateText(text) {
    if (!text) return null;
    const cacheKey = `${appSettings.targetLang}\u0000${text}`;
    const cached = state.cache.get(cacheKey);
    if (Array.isArray(cached)) return { text: cached[0], romaji: cached[1] };

    try {
      const result = await TRANSLATION_PROVIDERS.googleAuto.translate(text, appSettings.targetLang);
      if (!result) return null;
      state.cache.set(cacheKey, [result.text, result.romaji]);
      saveCache();
      return result;
    } catch {
      return null;
    }
  }

  function isLyricAnnotation(node) {
    return !!node && node.nodeType === 1 && node.dataset?.bsAnnotation === "lyrics";
  }

  function restoreNativeLine(line) {
    if (line.dataset.bsProcessed !== "true") return;
    if (line.dataset.bsSourceText) line.textContent = line.dataset.bsSourceText;
    delete line.dataset.bsProcessed;
    delete line.dataset.bsSourceText;
  }

  function removeLyricAnnotation(line) {
    const annotation = [...line.children].find(isLyricAnnotation);
    if (isLyricAnnotation(annotation)) annotation.remove();
  }

  function ensureLyricAnnotation(line) {
    const existing = [...line.children].find(isLyricAnnotation);
    if (isLyricAnnotation(existing)) return existing;

    const annotation = document.createElement("div");
    annotation.className = "bs-lyric-note";
    annotation.dataset.bsAnnotation = "lyrics";
    line.appendChild(annotation);
    return annotation;
  }

  function normalizeComparableText(value) {
    return String(value || "").toLowerCase().replace(/\s+/g, " ").trim();
  }

  // Lines already in the target language translate to themselves (Google
  // still answers, just verbatim) — rendering the duplicate under the
  // original is noise. Checked per line, not per track, so mixed-language
  // songs keep translations only where they add something. Only redundant
  // while the original layer is visible: with the original hidden, the
  // "duplicate" is the only text left on the line.
  function isRedundantTranslation(originalText, translatedText) {
    if (!appSettings.showOriginal) return false;
    const translated = normalizeComparableText(translatedText);
    return !!translated && translated === normalizeComparableText(originalText);
  }

  function createNoteLine(kind, value) {
    const noteLine = document.createElement("span");
    noteLine.className = `bs-note-line bs-note-${kind}`;
    noteLine.textContent = value;
    return noteLine;
  }

  function syncLyricAnnotationTone(line) {
    const annotation = [...line.children].find(isLyricAnnotation);
    if (!isLyricAnnotation(annotation)) return;

    annotation.style.removeProperty("color");
    annotation.style.removeProperty("opacity");
  }

  function syncLyricAnnotationTones(lines = getLyricsLines()) {
    lines.forEach(syncLyricAnnotationTone);
  }

  function renderLyricAnnotation(line, entry) {
    restoreNativeLine(line);
    line.dataset.bsLineKey = entry.id;
    line.classList.toggle("bs-caption-missing", appSettings.showTranslation && !entry.translation?.text);

    const fragments = [];
    if (appSettings.showTransliteration && entry.translation?.romaji) {
      fragments.push(createNoteLine("pronunciation", entry.translation.romaji));
    }
    if (
      appSettings.showTranslation &&
      entry.translation?.text &&
      !isRedundantTranslation(entry.text, entry.translation.text)
    ) {
      fragments.push(createNoteLine("meaning", entry.translation.text));
    }

    if (!fragments.length) {
      removeLyricAnnotation(line);
      return;
    }

    const annotation = ensureLyricAnnotation(line);
    annotation.dataset.bsLineKey = entry.id;
    annotation.replaceChildren(...fragments);
    syncLyricAnnotationTone(line);
  }

  function cleanupLyricAnnotations(lines) {
    const liveLines = new Set(lines);
    document.querySelectorAll("[data-bs-annotation=\"lyrics\"]").forEach((annotation) => {
      const line = annotation.closest(SELECTORS.lyricsLine);
      if (!line || !liveLines.has(line)) annotation.remove();
    });
  }

  function isLyricAnnotationMutation(mutation) {
    if (mutation.target.closest?.("[data-bs-annotation=\"lyrics\"]")) return true;
    const nodes = [...mutation.addedNodes, ...mutation.removedNodes];
    return nodes.length > 0 && nodes.every(isLyricAnnotation);
  }

  async function refreshLyrics() {
    updateBodyMode();
    enforceVideoFeatures();

    const lines = getLyricsLines();
    if (!lines.length) {
      state.transcript = [];
      cleanupLyricAnnotations([]);
      return;
    }

    lines.forEach(restoreNativeLine);
    const trackKey = getTrackKey(lines);
    if (trackKey !== state.trackKey) {
      state.trackKey = trackKey;
      state.translations.clear();
      state.transcript = [];
      detectSongMetadata();
    }

    const transcript = lines
      .map((line, index) => {
        restoreNativeLine(line);
        const text = getLineText(line);
        if (!text) {
          removeLyricAnnotation(line);
          return null;
        }
        return { id: lineId(text, index), line, text, translation: null };
      })
      .filter(Boolean);

    state.transcript = transcript.map((entry) => ({
      id: entry.id,
      text: entry.text,
      pronunciation: "",
      translation: "",
    }));

    const jobs = transcript.map(async (entry) => {
      const { id, line, text } = entry;

      let translation = state.translations.get(id);
      if (!translation && !state.pending.has(id)) {
        state.pending.add(id);
        translation = await translateText(text);
        state.pending.delete(id);
        if (translation) state.translations.set(id, translation);
      }

      entry.translation = translation || null;
      renderLyricAnnotation(line, entry);
    });

    await Promise.all(jobs);
    state.transcript = transcript.map((entry) => ({
      id: entry.id,
      text: entry.text,
      pronunciation: entry.translation?.romaji || "",
      translation: entry.translation?.text || "",
    }));
    cleanupLyricAnnotations(lines);
    syncLyricAnnotationTones(lines);
  }

  function scheduleRefresh() {
    if (state.rafQueued) return;
    state.rafQueued = true;
    requestAnimationFrame(() => {
      state.rafQueued = false;
      refreshLyrics();
    });
  }

  function setupLineObserver() {
    if (state.lineObserver) state.lineObserver.disconnect();
    const container =
      document.querySelector(SELECTORS.lyricsContainer) ||
      document.querySelector(SELECTORS.lyricsLine)?.parentElement ||
      document.body;

    state.lineObserver = new MutationObserver((mutations) => {
      const shouldRefresh = mutations.some(
        (mutation) =>
          mutation.type === "childList" &&
          !isLyricAnnotationMutation(mutation) &&
          (mutation.addedNodes.length > 0 || mutation.removedNodes.length > 0),
      );
      if (shouldRefresh) {
        installPanelButton();
        scheduleRefresh();
        return;
      }
    });
    state.lineObserver.observe(container, { childList: true, subtree: true });
  }

  function detectSongMetadata() {
    const title =
      document.querySelector(SELECTORS.nowPlayingTitle)?.textContent?.trim() ||
      document.querySelector("h1")?.textContent?.trim() ||
      "Unknown Song";
    const artist =
      document.querySelector(SELECTORS.nowPlayingArtist)?.textContent?.trim() ||
      document.querySelector("[data-testid=\"creator-link\"]")?.textContent?.trim() ||
      "Unknown Artist";
    state.currentSongTitle = title;
    state.currentArtist = artist;
  }

  // Track-change signal for once-per-track enforcement (auto-open lyrics,
  // full-screen video) — getTrackKey() can't be used because it hashes lyric
  // lines, which only exist while the lyrics view is already open. Returns ""
  // while the player bar hasn't rendered.
  function getNowPlayingTrack() {
    return {
      title: document.querySelector(SELECTORS.nowPlayingTitle)?.textContent?.trim() || "",
      artist: document.querySelector(SELECTORS.nowPlayingArtist)?.textContent?.trim() || "",
    };
  }

  function getNowPlayingKey() {
    const { title, artist } = getNowPlayingTrack();
    if (!title) return "";
    return `${title}|${artist}`;
  }

  // Spotify's own album art is served from its image CDN; the player bar holds
  // no other image from that host, which makes this a stable hook even when the
  // testids in SELECTORS.nowPlayingCoverArt drift.
  const COVER_ART_URL_PATTERN = /^https:\/\/i\.scdn\.co\/image\//;

  function getNowPlayingArtwork() {
    const scope = document.querySelector(SELECTORS.playerBar) || document;
    const tagged = scope.querySelector(SELECTORS.nowPlayingCoverArt);
    if (tagged?.src) return tagged.src;
    for (const image of scope.querySelectorAll("img")) {
      if (COVER_ART_URL_PATTERN.test(image.src)) return image.src;
    }
    return "";
  }

  // Song-change notifications ------------------------------------------------
  //
  // The player bar is the only track-change signal (same reasoning as
  // getNowPlayingKey), and it updates title and artist in separate renders, so
  // a key seen mid-update can pair a new title with the previous artist. This
  // runs off the mutation-observer path, where a track change produces a burst
  // of frames, so wait for the key to hold still rather than firing per
  // intermediate state.
  //
  // Kept deliberately short: this is the largest single component of the delay
  // before a notification appears (the poster backend — Spotify read, artwork
  // download, authorization-state check, post — measures ~0.17s). Desktop no
  // longer has to cover the mismatched-artist window because the helper reads
  // the track from Spotify itself. Chrome notifications still display the
  // scraped values, so that target keeps the more conservative delay.
  const NOTIFY_DESKTOP_SETTLE_MS = 100;
  const NOTIFY_EXTENSION_SETTLE_MS = 250;
  // Whatever was already playing when the script loaded is not a song change:
  // a page refresh, a Spotify restart, or a re-injection must not pop a
  // notification. The player bar renders a beat after load, so the first key is
  // swallowed only when it arrives inside this window.
  const NOTIFY_STARTUP_GRACE_MS = 5000;

  function scheduleSongChangeNotification() {
    if (!appSettings.songChangeNotifications) return;
    const key = getNowPlayingKey();
    if (!key || key === state.notifiedTrackKey || key === state.notifyPendingKey) return;

    state.notifyPendingKey = key;
    clearTimeout(state.notifyTimer);
    state.notifyTimer = setTimeout(() => {
      state.notifyPendingKey = "";
      const settled = getNowPlayingKey();
      if (!settled || settled === state.notifiedTrackKey) return;

      const startup = !state.notifiedTrackKey && Date.now() - state.startedAt < NOTIFY_STARTUP_GRACE_MS;
      state.notifiedTrackKey = settled;
      if (startup) return;

      const { title, artist } = getNowPlayingTrack();
      if (title) showSongChangeNotification(title, artist, getNowPlayingArtwork());
    }, isExtensionRuntime() ? NOTIFY_EXTENSION_SETTLE_MS : NOTIFY_DESKTOP_SETTLE_MS);
  }

  // Resident BetterSongifyNotifier menu-bar companion, the desktop build's
  // only route to a real macOS notification — see the Notification-API
  // findings below. Port is a stable native-app contract. Spotify's CSP
  // permits loopback fetches (verified August 2026); this would not work if
  // that ever changes.
  const NOTIFIER_ORIGIN = "http://127.0.0.1:17352";
  const NOTIFIER_ENDPOINT = `${NOTIFIER_ORIGIN}/notify`;
  const NOTIFIER_MENU_BAR_ENDPOINT = `${NOTIFIER_ORIGIN}/menu-bar`;

  // Resolves false for every failure mode (companion not running, error status,
  // unparsable reply) so callers only have to handle "it didn't take".
  async function postToNotifier(endpoint, payload) {
    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) return false;
      const reply = await response.json().catch(() => null);
      return !!reply?.ok;
    } catch {
      return false;
    }
  }

  // The POST is only a trigger — the companion reads the authoritative track from
  // Spotify over AppleEvents and ignores these fields unless that fails. They
  // are sent purely as its fallback.
  function postToLocalNotifier(title, artist, artwork) {
    return postToNotifier(NOTIFIER_ENDPOINT, { title, artist, artwork });
  }

  // The menu-bar item belongs to the companion app, so the panel toggle reaches
  // it over the same loopback contract as the notification trigger. The
  // companion remembers the last value it was told, which is what keeps the
  // preference honoured at login, before Spotify's renderer runs this script.
  function syncMenuBarVisibility({ announce = false } = {}) {
    if (isExtensionRuntime()) return;
    postToNotifier(NOTIFIER_MENU_BAR_ENDPOINT, { visible: !!appSettings.menuBarSong }).then((ok) => {
      if (ok || !announce) return;
      notify("Notifier companion isn't running — the menu bar item can't be changed.");
    });
  }

  // Is the companion listening? Uses the CORS preflight verb so probing cannot
  // pop a notification as a side effect.
  async function probeLocalNotifier() {
    try {
      const response = await fetch(NOTIFIER_ENDPOINT, {
        method: "OPTIONS",
        signal: AbortSignal.timeout(2000),
      });
      return response.ok || response.status === 204;
    } catch {
      return false;
    }
  }

  // Transport differs per target, like fetchTranslationPayload:
  //   Chrome build  -> service worker's chrome.notifications (granted at
  //                    install, no page prompt).
  //   Desktop build -> the resident menu-bar companion. The page Notification API is
  //                    deliberately NOT tried here: it is unreachable in
  //                    Spotify's client (permission can never be granted) and
  //                    the helper is better anyway, since it reads the album
  //                    and full-size art from Spotify.
  // Either way, an unavailable transport lands on the in-app toast so an
  // enabled setting always produces something visible.
  async function showSongChangeNotification(title, artist, artwork) {
    if (isExtensionRuntime()) {
      try {
        const reply = await chrome.runtime.sendMessage({
          type: "bs-notify",
          title,
          body: artist,
          iconUrl: artwork,
        });
        if (reply?.ok) return;
      } catch {}
    } else if (await postToLocalNotifier(title, artist, artwork)) {
      return;
    }
    notify(artist ? `${title} — ${artist}` : title);
  }

  // Auto-open lyrics: opens Spotify's lyrics view once per track when enabled.
  // Deliberately once per track (keyed by state.lastLyricsAutoOpenKey): if the
  // user closes the lyrics view without a captured click (Esc, navigation) we
  // do not fight them for the rest of that track. Like sticky video, the
  // preference mirrors the user's clicks on Spotify's own lyrics button
  // (handleVideoToggleClick): a click that opens lyrics turns auto-open on,
  // one that closes them turns it off.
  // When Expand Music Video is also on, the expanded video takes precedence:
  // opening lyrics would cover/collapse the expanded view, so on a track
  // whose video will play expanded, the lyrics key is consumed without
  // clicking. Tracks without a video still auto-open — after a grace period,
  // because the pill's absence is the only "no video" signal and it renders
  // a beat after track change.
  function enforceLyricsOpen(toggles = null) {
    if (!appSettings.autoOpenLyrics) return;
    const key = getNowPlayingKey();
    if (!key) return;
    if (key === state.lastLyricsAutoOpenKey) return;

    if (document.querySelector(SELECTORS.lyricsContainer)) {
      state.lastLyricsAutoOpenKey = key;
      return;
    }

    if (appSettings.preferVideoExpanded) {
      if (!toggles) {
        toggles = findVideoToggles();
        toggles.remote = isPlayingRemotely();
      }
      // While casting the pill still renders but video enforcement is
      // suspended — nothing will expand locally, so lyrics open normally.
      if (!toggles.remote) {
        // Video already playing ("Switch to audio" present), or present and
        // sticky video is about to switch to it — expansion will follow, so
        // lyrics loses this track.
        if (toggles.audio || (toggles.video && appSettings.preferVideo)) {
          state.lastLyricsAutoOpenKey = key;
          return;
        }
        if (appSettings.preferVideo) {
          if (key !== state.lyricsOpenDeferKey) {
            state.lyricsOpenDeferKey = key;
            // Short because this runs from the mutation-observer path, so
            // the pill is spotted the frame it renders — the grace only
            // needs to cover Spotify's render latency after a track change,
            // and it is the whole lyrics-open delay on video-less tracks.
            state.lyricsOpenDeferUntil = Date.now() + 1500;
          }
          // No pill yet: could be a video-less track, or the pill just
          // hasn't rendered. Hold off (without consuming the key) so video
          // wins the race when there is one.
          if (Date.now() < state.lyricsOpenDeferUntil) return;
        }
      }
    }

    const button = findLyricsControlButton();
    if (!button) return; // player bar may not have rendered yet; retry next tick

    // A disabled button means the track has no lyrics — consume the key
    // without clicking. The aria-pressed/data-active check is not just a
    // guard: on the web player the /lyrics page has no lyrics-container
    // testid at all (verified July 2026), so button state is the only
    // "already open" signal there.
    const active =
      button.getAttribute("aria-pressed") === "true" || button.dataset.active === "true";
    if (!active && !button.disabled) synthesizeClick(button);
    state.lastLyricsAutoOpenKey = key;
  }

  // Spotify buttons activate on one of two handler styles (verified on the
  // web player July 2026): the lyrics button needs a pointer sequence and
  // ignores element.click(); the NPV expand/minimize buttons need
  // element.click() and ignore a constructed "click" MouseEvent. So this
  // dispatches constructed pointer/mouse events and finishes with
  // element.click() — each style fires exactly once; do NOT add a
  // constructed "click" on top (click-style handlers would fire twice and
  // toggles would revert). Everything here has isTrusted === false, which
  // handleVideoToggleClick relies on.
  function synthesizeClick(element) {
    const rect = element.getBoundingClientRect();
    const options = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      button: 0,
      clientX: rect.x + rect.width / 2,
      clientY: rect.y + rect.height / 2,
    };
    ["pointerdown", "mousedown", "pointerup", "mouseup"].forEach((type) => {
      const Ctor = type.startsWith("pointer") ? PointerEvent : MouseEvent;
      element.dispatchEvent(new Ctor(type, { ...options, pointerId: 1, pointerType: "mouse", isPrimary: true }));
    });
    element.click();
  }

  function ensurePanel() {
    let panel = document.getElementById("better-songify-panel-aside");
    if (panel) {
      if (panel.parentElement !== document.body) document.body.appendChild(panel);
      return panel;
    }

    panel = document.createElement("aside");
    panel.id = "better-songify-panel-aside";

    document.body.appendChild(panel);
    renderSettingsView();
    return panel;
  }

  function setPanelOpen(open) {
    const panel = ensurePanel();
    const button = document.getElementById("better-songify-tab-btn");
    panel.classList.toggle("open", open);
    button?.classList.toggle("active", open);
  }

  function togglePanel() {
    const panel = ensurePanel();
    setPanelOpen(!panel.classList.contains("open"));
  }

  function installPanelButton() {
    document.getElementById("better-spotify-panel-toggle")?.remove();
    document.getElementById("better-songify-panel-toggle")?.remove();
    if (document.getElementById("better-songify-tab-btn")) return true;
    const anchor = findLyricsControlButton();
    if (!anchor?.parentElement) return false;

    const button = document.createElement("button");
    button.id = "better-songify-tab-btn";
    button.type = "button";
    button.textContent = "BetterSongify";
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      togglePanel();
    });

    anchor.parentElement.insertBefore(button, anchor);
    return true;
  }

  function findLyricsControlButton() {
    const buttons = [...document.querySelectorAll(SELECTORS.lyricsButton)];
    if (!buttons.length) return null;

    const playerBar = document.querySelector(SELECTORS.playerBar);
    const playerButton = playerBar ? buttons.find((button) => playerBar.contains(button)) : null;
    if (playerButton) return playerButton;

    return (
      buttons.find((button) => {
        const rect = button.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && rect.top > window.innerHeight * 0.55;
      }) || null
    );
  }

  function startUiPlacementRetry() {
    installPanelButton();
    if (state.uiPlacementTimer) return;

    state.uiPlacementTimer = window.setInterval(() => {
      installPanelButton();
      const toggles = enforceVideoFeatures();
      enforceLyricsOpen(toggles);
      scheduleSongChangeNotification();
    }, 2000);
  }

  // Matches the aria-label/text of Spotify's native video/audio pill as of
  // July 2026 — English clients only. Spotify shows "from now on" toasts but
  // actually reverts to audio every track; the sticky-preference feature below
  // exists to compensate.
  const VIDEO_TOGGLE_PATTERNS = {
    video: /switch to video/i,
    audio: /switch to audio/i,
  };

  // Remote playback (Spotify Connect): while casting, the player bar shows a
  // "Playing on <device>" text-link button (verified on open.spotify.com
  // July 2026 — an encore textLink with no testid and no aria-label, so this
  // English-only text is the only hook, like the pill patterns above).
  const REMOTE_PLAYBACK_PATTERN = /^\s*playing on\b/i;

  function isPlayingRemotely() {
    const bar = document.querySelector(SELECTORS.playerBar);
    if (!bar) return false;
    for (const button of bar.querySelectorAll("button")) {
      if (REMOTE_PLAYBACK_PATTERN.test(button.textContent || "")) return true;
    }
    return false;
  }

  function videoToggleKind(button) {
    const label = `${button.getAttribute("aria-label") || ""} ${button.textContent || ""}`;
    if (VIDEO_TOGGLE_PATTERNS.video.test(label)) return "video";
    if (VIDEO_TOGGLE_PATTERNS.audio.test(label)) return "audio";
    return null;
  }

  // aria-labels of the expanded Now Playing view toggles as of July 2026 —
  // English clients only, like VIDEO_TOGGLE_PATTERNS. These buttons carry no
  // testid, so the label is the only hook.
  const NPV_EXPAND_PATTERNS = {
    expand: /expand now playing view/i,
    minimize: /minimize now playing view/i,
  };

  // One pass over all buttons finds every control we enforce with — the two
  // video pill states and the expanded-NPV toggles — so mutation bursts
  // still cost at most one button scan per animation frame (see
  // setupVideoObserver).
  function findVideoToggles() {
    const toggles = { video: null, audio: null, expand: null, minimize: null };
    for (const button of document.querySelectorAll("button")) {
      const kind = videoToggleKind(button);
      if (kind && !toggles[kind]) toggles[kind] = button;
      const aria = button.getAttribute("aria-label") || "";
      if (!toggles.expand && NPV_EXPAND_PATTERNS.expand.test(aria)) toggles.expand = button;
      if (!toggles.minimize && NPV_EXPAND_PATTERNS.minimize.test(aria)) toggles.minimize = button;
    }
    return toggles;
  }

  function findVideoToggle(kind) {
    return findVideoToggles()[kind];
  }

  function handleVideoToggleClick(event) {
    // Only real user clicks set the preferences; our programmatic
    // clicks (isTrusted === false) must not re-trigger them.
    if (!event.isTrusted) return;
    const button = event.target.closest?.("button");
    if (!button) return;

    // Clicks on Spotify's own lyrics button mirror into Auto-Open Lyrics,
    // same philosophy as the video pill: opening lyrics turns it on, closing
    // turns it off; the panel toggle is a mirror. This runs in the capture
    // phase, before Spotify flips the button, so the pre-click active state
    // gives the direction. A disabled button (track has no lyrics) toggles
    // nothing, so it must not flip the setting.
    if (button.matches?.(SELECTORS.lyricsButton)) {
      if (button.disabled) return;
      const wasOpen =
        button.getAttribute("aria-pressed") === "true" || button.dataset.active === "true";
      appSettings.autoOpenLyrics = !wasOpen;
      // The user just took manual control for this track — consume the key
      // so a same-track enforcement pass can't fight the choice.
      state.lastLyricsAutoOpenKey = getNowPlayingKey();
      syncSettingCheckbox("better-songify-auto-open", appSettings.autoOpenLyrics);
      return;
    }

    const kind = videoToggleKind(button);
    if (kind) {
      appSettings.preferVideo = kind === "video";
      syncSettingCheckbox("better-songify-prefer-video", appSettings.preferVideo);
      return;
    }

    // Mirror Spotify's own expand/minimize controls into the expand
    // preference — but only while a video is actually playing: expanding
    // album art on an audio-only track says nothing about videos. The
    // button scan only runs when the clicked button matched the patterns,
    // so ordinary clicks stay cheap.
    const aria = button.getAttribute("aria-label") || "";
    const expandKind = NPV_EXPAND_PATTERNS.expand.test(aria)
      ? "expand"
      : NPV_EXPAND_PATTERNS.minimize.test(aria)
        ? "minimize"
        : null;
    if (!expandKind) return;
    if (!findVideoToggle("audio")) return;
    appSettings.preferVideoExpanded = expandKind === "expand";
    // The user just took manual control of this track's view state —
    // consume the key so enforcement can't fight the choice mid-track.
    state.lastExpandAutoKey = getNowPlayingKey();
    syncSettingCheckbox("better-songify-expand-video", appSettings.preferVideoExpanded);
  }

  function syncSettingCheckbox(id, checked) {
    const input = document.getElementById(id);
    if (input) input.checked = checked;
  }

  // Runs both video enforcements off a single button scan; returns the scan
  // so callers (the 2s interval) can feed enforceLyricsOpen without a second one.
  // While playback is on another device (Spotify Connect), both enforcements
  // stand down: the pill and expand buttons still render locally (verified
  // July 2026) but clicking them sends commands to the casting device —
  // enforcement would fight switches the user makes there. The preference
  // still only changes via local trusted clicks (handleVideoToggleClick);
  // a remote audio-switch is indistinguishable from Spotify's own per-track
  // auto-revert, so it must never be captured as a preference signal.
  function enforceVideoFeatures() {
    const toggles = findVideoToggles();
    toggles.remote = isPlayingRemotely();
    if (!toggles.remote) {
      enforceVideoPreference(toggles.video);
      enforceVideoExpanded(toggles);
    }
    return toggles;
  }

  function enforceVideoPreference(videoToggle) {
    if (!appSettings.preferVideo) return;
    // Spotify reverts to audio on every track change; if a "Switch to
    // video" button is showing, the current track has a video but is
    // playing audio, so honor the sticky preference. A brief audio-first
    // blip is irreducible with this approach: Spotify starts every track
    // in audio and the pill must render before we can click it. Removing
    // the blip entirely would mean hooking Spotify's private player
    // internals, which breaks far harder than DOM clicking.
    if (!videoToggle) return;
    // Capped per track: if the pill keeps reverting to "Switch to video",
    // the video is failing to load, and every retry makes Spotify pop its
    // "can't play this right now" toast — don't hammer it all track long.
    const key = getNowPlayingKey();
    if (key !== state.videoAutoClickKey) {
      state.videoAutoClickKey = key;
      state.videoAutoClickCount = 0;
    }
    if (state.videoAutoClickCount >= 3) return;
    const now = Date.now();
    if (now - state.lastVideoAutoClick < 3000) return;
    state.lastVideoAutoClick = now;
    state.videoAutoClickCount += 1;
    videoToggle.click();
  }

  function isNowPlayingExpanded() {
    const main = document.querySelector(SELECTORS.mainView);
    return !!main && main.getBoundingClientRect().width === 0;
  }

  // Expand music video: Spotify collapses the expanded Now Playing view when
  // a track without a video interrupts, and never restores it. This is the
  // in-app expanded view ("Expand Now Playing view"), deliberately NOT
  // fullscreen-mode-button — OS fullscreen is not what users mean, and the
  // web player rejects untrusted fullscreen anyway (user-activation rule).
  // Once per track (same keying as auto-open lyrics), and only while a
  // video is actually playing — toggles.audio ("Switch to audio") present
  // means video mode is active. The key is not consumed before then, so
  // this naturally waits for sticky video to switch streams first.
  // Clicking expand while already expanded is a no-op (verified July
  // 2026), so a stale "already expanded" read is harmless.
  //
  // The key is consumed only when the expanded state is actually OBSERVED,
  // never right after clicking: track-change re-renders (especially coming
  // off the lyrics page, which also navigates) can swap the button out
  // between scan and click, silently no-opping it — consuming on click
  // would strand the video in the side panel for the whole track. Failed
  // clicks retry on a 3s debounce instead. Minimizing mid-track is still
  // respected: a manual (trusted) minimize consumes the key via the
  // click-capture in handleVideoToggleClick, and an Esc-close is covered
  // because the expansion mutation makes this observe-and-consume almost
  // immediately, before a human can press Esc.
  function enforceVideoExpanded(toggles) {
    if (!appSettings.preferVideoExpanded) return;
    const key = getNowPlayingKey();
    if (!key || key === state.lastExpandAutoKey) return;
    if (!toggles.audio) return; // not in video mode (yet) — keep retrying this track

    if (isNowPlayingExpanded()) {
      state.lastExpandAutoKey = key;
      return;
    }
    if (!toggles.expand) return; // control not rendered yet — retry next tick
    // Retries are capped per track: if expansion is never observed the
    // zero-width-main signal is probably broken (web-verified only), and
    // an unbounded click loop against an unknown desktop DOM is worse
    // than giving up on the track.
    if (key !== state.expandAutoClickKey) {
      state.expandAutoClickKey = key;
      state.expandAutoClickCount = 0;
    }
    if (state.expandAutoClickCount >= 3) return;
    const now = Date.now();
    if (now - state.lastExpandAutoClick < 3000) return;
    state.lastExpandAutoClick = now;
    state.expandAutoClickCount += 1;
    synthesizeClick(toggles.expand);
  }

  // Event-driven trigger: reacts the moment Spotify renders the "Switch to
  // video" pill after a track change, instead of waiting for the 2s interval.
  // document.body sees Spotify's constant UI churn (progress bar, animations),
  // so the callback must stay cheap: mutation bursts collapse into at most one
  // button scan per animation frame via scheduleVideoEnforce. Never scan
  // per-mutation. The 2s interval (startUiPlacementRetry) stays as a backstop —
  // if the auto-switch delay regresses to ~2s, this observer has stopped
  // seeing the pill render (e.g. Spotify moved it into a shadow root or an
  // overlay outside body); fix by re-pointing what this observes.
  function setupVideoObserver() {
    if (state.videoObserver) state.videoObserver.disconnect();
    state.videoObserver = new MutationObserver((mutations) => {
      if (mutations.some((m) => m.type === "childList" && m.addedNodes.length > 0)) {
        scheduleVideoEnforce();
      }
    });
    state.videoObserver.observe(document.body, { childList: true, subtree: true });
  }

  function scheduleVideoEnforce() {
    if (state.videoRafQueued) return;
    state.videoRafQueued = true;
    requestAnimationFrame(() => {
      state.videoRafQueued = false;
      // Lyrics enforcement rides the same single button scan — running it
      // here (not just the 2s interval) is what keeps the video-precedence
      // grace in enforceLyricsOpen short.
      const toggles = enforceVideoFeatures();
      enforceLyricsOpen(toggles);
      scheduleSongChangeNotification();
    });
  }

  function renderSettingsView() {
    const panel = document.getElementById("better-songify-panel-aside");
    if (!panel) return;

    const languageOptions = LANGUAGE_CODES
      .map((code) => {
        const selected = code === appSettings.targetLang ? " selected" : "";
        return `<option value="${code}"${selected}>${escapeHtml(getLanguageLabel(code))}</option>`;
      })
      .join("");

    const fontOptions = LYRIC_FONTS
      .map((font) => {
        const selected = font.value === appSettings.lyricsFont ? " selected" : "";
        return `<option value="${escapeHtml(font.value)}"${selected}>${escapeHtml(font.label)}</option>`;
      })
      .join("");

    const lyricsScale = Number(appSettings.lyricsScale) || 100;

    panel.innerHTML = `
      <div class="better-songify-panel-header">
        <div class="better-songify-panel-title">BetterSongify</div>
        <button class="better-songify-btn-text" id="better-songify-close-panel">Close</button>
      </div>
      <div class="better-songify-panel-body">
        <div class="better-songify-section">
          <div class="better-songify-section-title">Lyrics</div>
          ${toggleRow("Auto-Open Lyrics", "autoOpenLyrics", "better-songify-auto-open")}
          ${toggleRow("Original Text", "showOriginal", "better-songify-original")}
          ${toggleRow("Pronunciation", "showTransliteration", "better-songify-transliteration")}
          ${toggleRow("Translation", "showTranslation", "better-songify-translation")}
          <div class="better-songify-row better-songify-row-sub${appSettings.showTranslation ? "" : " better-songify-row-disabled"}">
            <span class="better-songify-row-label">Language</span>
            <select class="better-songify-select" id="better-songify-lang" aria-label="Translation language">${languageOptions}</select>
          </div>
          <div class="better-songify-row">
            <span class="better-songify-row-label">Text Size</span>
            <input type="range" class="better-songify-range" id="better-songify-scale" min="50" max="150" step="5" value="${lyricsScale}" aria-label="Lyrics text size">
            <span class="better-songify-range-value" id="better-songify-scale-value">${lyricsScale}%</span>
          </div>
          <div class="better-songify-row">
            <span class="better-songify-row-label">Font</span>
            <select class="better-songify-select" id="better-songify-font" aria-label="Lyrics font">${fontOptions}</select>
          </div>
        </div>

        <div class="better-songify-section">
          <div class="better-songify-section-title">Music Video</div>
          ${toggleRow("Prefer Music Video", "preferVideo", "better-songify-prefer-video")}
          ${toggleRow("Expand Music Video", "preferVideoExpanded", "better-songify-expand-video")}
        </div>

        <div class="better-songify-section">
          <div class="better-songify-section-title">Recommendations</div>
          ${toggleRow("Hide Playlist Recommendations", "hideRecommendations", "better-songify-hide-recs")}
          ${toggleRow("Hide Home Audiobooks", "hideHomeAudiobooks", "better-songify-hide-audiobooks")}
          ${toggleRow("Hide Home Podcasts", "hideHomePodcasts", "better-songify-hide-podcasts")}
        </div>

        <div class="better-songify-section">
          <div class="better-songify-section-title">Notifications</div>
          ${toggleRow("Notify On Song Change", "songChangeNotifications", "better-songify-song-notify")}
          ${isExtensionRuntime() ? "" : toggleRow("Show Song In Menu Bar", "menuBarSong", "better-songify-menu-bar")}
        </div>

        <div class="better-songify-section" style="margin-top:auto">
          <button class="better-songify-btn better-songify-btn-primary" id="better-songify-btn-download">Download Lyrics</button>
          <button class="better-songify-btn better-songify-btn-secondary" id="better-songify-btn-restore">Restore Defaults</button>
        </div>
      </div>
    `;

    bindSettingsEvents(panel);
  }

  function toggleRow(label, setting, id) {
    return `
      <div class="better-songify-row">
        <span class="better-songify-row-label">${label}</span>
        <label class="better-songify-toggle">
          <input type="checkbox" id="${id}" data-setting="${setting}" ${appSettings[setting] ? "checked" : ""}>
          <div class="better-songify-toggle-track"></div><div class="better-songify-toggle-knob"></div>
        </label>
      </div>
    `;
  }

  function bindSettingsEvents(panel) {
    panel.querySelector("#better-songify-close-panel")?.addEventListener("click", () => setPanelOpen(false));
    panel.querySelector("#better-songify-lang")?.addEventListener("change", (event) => {
      appSettings.targetLang = event.target.value;
      state.trackKey = "";
      scheduleRefresh();
    });
    const scaleInput = panel.querySelector("#better-songify-scale");
    scaleInput?.addEventListener("input", () => {
      appSettings.lyricsScale = Number(scaleInput.value) || 100;
      const value = panel.querySelector("#better-songify-scale-value");
      if (value) value.textContent = `${appSettings.lyricsScale}%`;
      applyLyricsAppearance();
    });
    panel.querySelector("#better-songify-font")?.addEventListener("change", (event) => {
      appSettings.lyricsFont = event.target.value;
      applyLyricsAppearance();
    });
    panel.querySelectorAll("[data-setting]").forEach((input) => {
      input.addEventListener("change", () => {
        appSettings[input.dataset.setting] = input.checked;
        if (input.dataset.setting === "showOriginal" || input.dataset.setting === "showTranslation") {
          // Layer guard: at least one text layer stays visible — turning
          // the last one off flips the other back on.
          if (!appSettings.showOriginal && !appSettings.showTranslation) {
            const other = input.dataset.setting === "showOriginal" ? "showTranslation" : "showOriginal";
            appSettings[other] = true;
          }
          updateBodyMode();
          scheduleRefresh();
          renderSettingsView(); // re-syncs both layer toggles + language row dim
          return;
        }
        if (input.dataset.setting === "showTransliteration") scheduleRefresh();
        if (input.dataset.setting === "preferVideo") {
          if (input.checked) {
            state.videoAutoClickKey = ""; // explicit request — reset the per-track retry cap
            enforceVideoFeatures();
          } else findVideoToggle("audio")?.click();
        }
        if (input.dataset.setting === "preferVideoExpanded") {
          if (input.checked) {
            state.lastExpandAutoKey = "";
            state.expandAutoClickKey = "";
            enforceVideoFeatures();
          } else if (isNowPlayingExpanded()) {
            // mirror the preferVideo toggle: turning it off collapses the view.
            // The minimize button stays mounted even when not expanded (web
            // player), hence the isNowPlayingExpanded gate.
            const minimize = findVideoToggle("minimize");
            if (minimize) synthesizeClick(minimize);
          }
        }
        if (input.dataset.setting === "autoOpenLyrics" && input.checked) {
          state.lastLyricsAutoOpenKey = "";
          enforceLyricsOpen();
        }
        if (
          input.dataset.setting === "hideRecommendations"
          || input.dataset.setting === "hideHomeAudiobooks"
          || input.dataset.setting === "hideHomePodcasts"
        ) applyLyricsAppearance();
        // Say so when the companion isn't listening, rather than leaving a
        // toggle that visibly does nothing — same reasoning as the notification
        // probe below.
        if (input.dataset.setting === "menuBarSong") syncMenuBarVisibility({ announce: true });
        if (input.dataset.setting === "songChangeNotifications") {
          if (!input.checked) {
            clearTimeout(state.notifyTimer);
            state.notifyPendingKey = "";
            return;
          }
          // Seed with whatever is playing right now so enabling the setting
          // doesn't immediately notify for a track the user is already looking
          // at — same reasoning as NOTIFY_STARTUP_GRACE_MS.
          state.notifiedTrackKey = getNowPlayingKey();
          // Desktop only: say so up front if the companion that posts real macOS
          // notifications isn't listening, rather than letting the user
          // discover it one silent track change at a time. The Chrome build
          // needs no such check — its permission comes from the manifest.
          if (!isExtensionRuntime()) {
            probeLocalNotifier().then((running) => {
              if (running) return;
              notify("Notifier companion isn't running — song changes will show here instead.");
            });
          }
        }
      });
    });
    panel.querySelector("#better-songify-btn-restore")?.addEventListener("click", () => {
      Object.assign(settingsData, DEFAULTS);
      removeStorage(SETTINGS_KEY);
      removeStorage(CACHE_KEY);
      PRE_RENAME_SETTINGS_KEYS.forEach(removeStorage);
      Object.values(LEGACY_SETTING_KEYS).forEach(removeStorage);
      state.cache.clear();
      state.trackKey = "";
      syncMenuBarVisibility();
      notify("Settings restored to defaults.");
      scheduleRefresh();
      renderSettingsView();
    });
    bindDownloadButton(panel.querySelector("#better-songify-btn-download"), exportTextFile);
  }

  function getExportRows() {
    return state.transcript
      .filter((row) => row.text)
      .map((row) => ({
        id: row.id,
        text: row.text,
        pronunciation: row.pronunciation || "",
        translation: row.translation || "",
      }));
  }

  function bindDownloadButton(button, handler) {
    if (!button) return;
    button.addEventListener("click", async () => {
      if (button.disabled) return;

      const label = button.textContent;
      button.disabled = true;
      button.textContent = "Working…";

      try {
        await handler();
      } catch (error) {
        console.error("[BetterSongify] Export failed", error);
        notify(error?.message || "Export failed.");
      } finally {
        button.disabled = false;
        button.textContent = label;
      }
    });
  }

  function sanitizeFilename(value) {
    return (
      String(value || "lyrics")
        .replace(/[<>:"/\\|?*\x00-\x1F]/g, "")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/[. ]+$/g, "") || "lyrics"
    );
  }

  function normalizeExtension(extension) {
    return extension.startsWith(".") ? extension : `.${extension}`;
  }

  async function createBlobSaver(extension, mime, filename) {
    const fileExtension = normalizeExtension(extension);
    const safeFilename = sanitizeFilename(filename || `lyrics${fileExtension}`);

    if (window.showSaveFilePicker) {
      try {
        const handle = await window.showSaveFilePicker({
          suggestedName: safeFilename,
          types: [{ description: `${fileExtension.toUpperCase()} File`, accept: { [mime]: [fileExtension] } }],
        });
        return async (blob) => {
          const writable = await handle.createWritable();
          await writable.write(blob);
          await writable.close();
          notify(`Saved ${safeFilename}.`);
        };
      } catch (error) {
        if (error?.name === "AbortError") return null;
        console.warn("[BetterSongify] Save picker unavailable, falling back to browser download.", error);
      }
    }

    return async (blob) => saveBlob(blob, safeFilename);
  }

  async function saveBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.rel = "noopener";
    link.style.display = "none";
    document.body.appendChild(link);

    try {
      link.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
      notify(`Download started: ${filename}`);
    } finally {
      window.setTimeout(() => {
        link.remove();
        URL.revokeObjectURL(url);
      }, 60000);
    }
  }

  async function exportTextFile() {
    const rows = getExportRows();
    if (!rows.length) return notify("Nothing to export — no lyric lines detected.");
    const safeTitle = sanitizeFilename(state.currentSongTitle || "lyrics");

    const save = await createBlobSaver(".txt", "text/plain", `${safeTitle}.txt`);
    if (!save) return;
    let text = `${state.currentSongTitle || "Unknown Song"} — ${state.currentArtist || "Unknown Artist"}\n\n`;
    rows.forEach((row) => {
      if (appSettings.showOriginal) text += `${row.text}\n`;
      if (appSettings.showTransliteration && row.pronunciation) text += `${row.pronunciation}\n`;
      if (appSettings.showTranslation && row.translation && !isRedundantTranslation(row.text, row.translation)) {
        text += `${row.translation}\n`;
      }
      text += "\n";
    });
    return save(new Blob([text], { type: "text/plain" }));
  }

  function init() {
    state.startedAt = Date.now();
    ensureBaseStyles();
    updateBodyMode();
    startUiPlacementRetry();
    setupLineObserver();
    setupVideoObserver();
    detectSongMetadata();
    // Push the stored preference once per injection: the panel is its owner, so
    // a companion that lost its remembered value (reinstall, cleared defaults)
    // re-syncs without the user touching the toggle.
    syncMenuBarVisibility();
    document.addEventListener("click", handleVideoToggleClick, true);
    window.addEventListener("resize", scheduleRefresh);
    scheduleRefresh();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

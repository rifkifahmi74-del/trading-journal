/* Service worker — installable & offline on iPhone/iPad.
   The page (index.html) and market-cache.js are NETWORK-FIRST so you always get
   the latest version when online (falling back to cache offline). Icons/manifest
   are cache-first. External API calls (CoinGecko, OKX, TradingView) hit the network. */
const CACHE = 'tj-cache-v11';
const SHELL = ['./', './index.html', './manifest.webmanifest',
  './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ).then(() => self.clients.claim()));
});

function networkFirst(req) {
  return fetch(req).then(r => {
    const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); return r;
  }).catch(() => caches.match(req).then(r => r || caches.match('./index.html')));
}
function cacheFirst(req) {
  return caches.match(req).then(r => r || fetch(req).then(resp => {
    const c = resp.clone(); caches.open(CACHE).then(x => x.put(req, c)); return resp;
  }));
}

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return; // external APIs go straight to network
  const isPage = e.request.mode === 'navigate'
    || url.pathname.endsWith('/') || url.pathname.endsWith('index.html');
  if (isPage || url.pathname.endsWith('market-cache.js')) {
    e.respondWith(networkFirst(e.request));   // always latest when online
  } else {
    e.respondWith(cacheFirst(e.request));     // icons, manifest, etc.
  }
});

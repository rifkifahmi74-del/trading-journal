/* Service worker — makes the dashboard installable & usable offline on iPhone/iPad.
   App shell is cached; market-cache.js is network-first so daily data stays fresh;
   external API calls (CoinGecko, OKX, etc.) always go to the network. */
const CACHE = 'tj-cache-v1';
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
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return; // let external API calls hit the network directly
  if (url.pathname.endsWith('market-cache.js')) {
    // network-first for fresh daily data, fall back to cache offline
    e.respondWith(
      fetch(e.request).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); return r; })
        .catch(() => caches.match(e.request))
    );
    return;
  }
  // cache-first for the app shell
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request).then(resp => {
    const c = resp.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); return resp;
  }).catch(() => r)));
});

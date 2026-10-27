/* Jemrix · Offline-Speicher. Die Version wird beim Bauen automatisch gesetzt. */
const CACHE = 'jemrix-b04fab95ee';
const SHELL = [
  './', 'index.html', 'jenmah.html', 'config.js', 'manifest.webmanifest',
  'icons/apple-touch-icon.png', 'icons/icon-192.png', 'icons/icon-512.png',
  'fonts/fredoka-latin-500-normal.woff2', 'fonts/fredoka-latin-600-normal.woff2', 'fonts/fredoka-latin-700-normal.woff2',
  'fonts/nunito-latin-500-normal.woff2', 'fonts/nunito-latin-700-normal.woff2', 'fonts/unbounded-latin-wght-normal.woff2', 'fonts/lilita-one-latin-400-normal.woff2'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE)
    .then(c => c.addAll(SHELL.map(u => new Request(u, { cache: 'reload' }))))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k.startsWith('jemrix-') && k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Nur gute Antworten speichern, damit eine Fehlerseite nie die Offline-Kopie ersetzt
const keep = (req, res) => { if (res && res.ok && res.type === 'basic') { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return res; };

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;            // Highscores (Supabase) immer live
  const isPage = req.mode === 'navigate' || url.pathname.endsWith('/') || url.pathname.endsWith('.html') || url.pathname.endsWith('config.js');
  if (isPage) {
    // Seite: neueste Version aus dem Netz, aber höchstens 3 s warten, sonst aus dem Speicher
    const cached = () => caches.match(req, { ignoreSearch: true }).then(r => r || (req.mode === 'navigate' ? caches.match('index.html') : undefined));
    const net = fetch(req, { cache: 'no-cache' }).then(res => keep(req, res));
    e.respondWith(new Promise(resolve => {
      let done = false;
      const fallback = () => cached().then(r => { if (!done && r) { done = true; resolve(r); } });
      const t = setTimeout(fallback, 3000);
      net.then(res => {
        clearTimeout(t);
        if (done) return;
        if (res.ok) { done = true; resolve(res); }
        else cached().then(r => { done = true; resolve(r || res); });
      }).catch(() => { clearTimeout(t); cached().then(r => { done = true; resolve(r || Response.error()); }); });
    }));
    return;
  }
  // Schriften, Icons: aus dem Speicher, sonst Netz
  e.respondWith(caches.match(req).then(r => r || fetch(req).then(res => keep(req, res))));
});

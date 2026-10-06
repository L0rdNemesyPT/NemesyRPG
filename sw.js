const CACHE_NAME = 'nemesy-rpg-v38';
const APP_SHELL = [
  './',
  './index.html',
  './email-confirmed.html',
  './supabase-config.js',
  './nemesy-theme.css',
  './Nemesy-RPG.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-512-maskable.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(key => key.startsWith('nemesy-rpg-') && key !== CACHE_NAME)
        .map(key => caches.delete(key))
    ))
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) return;

  event.respondWith((async () => {
    const requestUrl = new URL(request.url);
    const isAppShellRequest = request.mode === 'navigate' || APP_SHELL.some(path =>
      new URL(path, self.registration.scope).pathname === requestUrl.pathname
    );

    if (isAppShellRequest) {
      try {
        const response = await fetch(request, { cache: 'no-cache' });
        if (response.ok) {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(request, response.clone());
        }
        return response;
      } catch {
        const cached = await caches.match(request, { ignoreSearch: true });
        if (cached) return cached;
        if (request.mode === 'navigate') {
          return caches.match(new URL('./index.html', self.registration.scope).href);
        }
        return Response.error();
      }
    }

    const cached = await caches.match(request, { ignoreSearch: true });
    if (cached) return cached;
    try {
      const response = await fetch(request);
      if (response.ok) {
        const cache = await caches.open(CACHE_NAME);
        await cache.put(request, response.clone());
      }
      return response;
    } catch {
      if (request.mode === 'navigate') {
        return caches.match(new URL('./index.html', self.registration.scope).href);
      }
      return Response.error();
    }
  })());
});
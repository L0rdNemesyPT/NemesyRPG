const CACHE_NAME = 'nemesy-rpg-v193';
// v189: as imagens (ícones, mapas, avatares) ficam numa cache própria que NÃO é apagada nos updates.
// Cada imagem é guardada com o endereço completo (incluindo ?v=…): só se descarrega outra vez quando
// a versão dessa imagem muda, e a versão antiga é apagada nessa altura.
const IMG_CACHE = 'nemesy-img-v1';
const IMG_RE = /\/(icons|avatars)\/[^/]+\.(webp|png|jpe?g|svg|gif)$/i;
const APP_SHELL = [
  './',
  './index.html',
  './email-confirmed.html',
  './reset-password.html',
  './supabase-config.js',
  './nemesy-theme.css',
  './Nemesy-RPG.html',
  './manifest.webmanifest',
  './app-icon-192.png',
  './app-icon-512.png',
  './app-icon-512-maskable.png',
  './app-icon-180.png',
  './favicon-64.png',
  './icons/logo-nemesy.webp',
  './avatars/avatar-guerreiro.webp',
  './avatars/avatar-arqueiro.webp',
  './avatars/avatar-mago.webp',
  './avatars/avatar-paladino.webp',
  './avatars/avatar-cruzado.webp',
  './avatars/avatar-cacador.webp',
  './avatars/avatar-mercenario.webp',
  './avatars/avatar-necromante.webp',
  './avatars/avatar-feiticeiro.webp'
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
      keys.filter(key => key.startsWith('nemesy-rpg-') && key !== CACHE_NAME) // a IMG_CACHE fica
        .map(key => caches.delete(key))
    ))
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) return;

  const imgUrl = new URL(request.url);
  if (IMG_RE.test(imgUrl.pathname)) {
    event.respondWith((async () => {
      const cache = await caches.open(IMG_CACHE);
      const hit = await cache.match(request);
      if (hit) return hit;
      try {
        const response = await fetch(request);
        if (response.ok) {
          const keys = await cache.keys();
          await Promise.all(keys.filter(k => new URL(k.url).pathname === imgUrl.pathname).map(k => cache.delete(k)));
          await cache.put(request, response.clone());
        }
        return response;
      } catch {
        const old = await cache.match(request, { ignoreSearch: true }) || await caches.match(request, { ignoreSearch: true });
        return old || Response.error();
      }
    })());
    return;
  }

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
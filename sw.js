// Service worker do Nemesy RPG — cache simples para a app abrir offline
// depois da primeira visita. Muda o número da versão (CACHE_NAME) sempre
// que publicares uma atualização do jogo, para forçar o telemóvel a
// descarregar a nova versão em vez de continuar a mostrar a antiga.
const CACHE_NAME = 'nemesy-rpg-v2';
const ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './icon-512-maskable.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Cache-first: usa a cópia guardada logo de imediato (jogo abre instantâneo
// e offline); em paralelo tenta atualizar a cache a partir da rede para a
// próxima vez, sem bloquear a resposta atual.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const requestUrl = new URL(event.request.url);
  if (requestUrl.origin !== self.location.origin) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(event.request);

    if (event.request.mode === 'navigate') {
      try {
        const response = await fetch(event.request);
        if (response.ok) await cache.put(event.request, response.clone());
        return response;
      } catch (error) {
        return cached || cache.match('./index.html');
      }
    }

    if (cached) return cached;
    try {
      const response = await fetch(event.request);
      if (response.ok) await cache.put(event.request, response.clone());
      return response;
    } catch (error) {
      return Response.error();
    }
  })());
});

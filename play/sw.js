// Cache app shell only. Never cache auth tokens, dynamic Supabase responses, reward or redemption data.
const CACHE = 'yetipsy-play-static-v1-pilot-3';
const SHELL = ['./','./index.html','./styles.css','./app.js','./manifest.webmanifest','./config.js'];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(Promise.all([self.clients.claim(),caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('yetipsy-play-')&&k!==CACHE).map(k=>caches.delete(k))))])));
self.addEventListener('fetch', event => {
  const u = new URL(event.request.url);
  if(event.request.method!=='GET' || u.origin!==self.location.origin || !u.pathname.includes('/play/')) return;
  // Network-first including public config; offline falls back to the cached app shell.
  event.respondWith(fetch(event.request).then(response=>{
    if(response.ok && response.type==='basic') {const copy=response.clone(); caches.open(CACHE).then(c=>c.put(event.request,copy));}
    return response;
  }).catch(()=>caches.match(event.request)));
});

// Only cache local app shell. Never cache API, Supabase, login, wallets or redemption URLs.
const CACHE = 'yt-play-v12-20261008.1';
const SHELL = ['./','./index.html','./app.js','./styles.css','./config.js','./manifest.webmanifest','./icon-192.png','./icon-512.png'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(Promise.all([self.clients.claim(),caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('yt-play-v12-')&&k!==CACHE).map(k=>caches.delete(k))))])));
self.addEventListener('fetch',event=>{const u=new URL(event.request.url);if(event.request.method!=='GET'||u.origin!==self.location.origin||!u.pathname.includes('/play-v12/'))return;event.respondWith(fetch(event.request).then(response=>{if(response.ok&&response.type==='basic'&&!u.search){const copy=response.clone();caches.open(CACHE).then(c=>c.put(event.request,copy));}return response;}).catch(()=>caches.match(event.request)));});

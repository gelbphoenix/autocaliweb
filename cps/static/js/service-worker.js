self.addEventListener("install", (e) => self.skipWaiting());

self.addEventListener("activate", (e) => e.waitUntil(clients.claim()));

self.addEventListener("fetch", (e) => e.respondWith(fetch(e.request)));

self.addEventListener("message", (e) => {
    if (e.data && e.data.type === "SKIP_WAITING") {
        self.skipWaiting();
    }
});

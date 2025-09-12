const CACHE_NAME = "autocaliweb-cache";
const PRECACHE_URLS = [
    "/",
    "/static/icon-dark.svg",
    "/static/icon-light.svg",
    "/static/css/main.css",
    "/static/js/main.js",
];

self.addEventListener("install", (e) => {
    e.waitUntil(
        caches
            .open(CACHE_NAME)
            .then((cache) => cache.addAll(PRECACHE_URLS))
            .then(() => self.skipWaiting())
    );
});

self.addEventListener("activate", (e) => {
    e.waitUntil(
        caches
            .keys()
            .then((names) =>
                Promise.all(
                    names.map((name) => {
                        if (name !== CACHE_NAME) return caches.delete(name);
                    })
                )
            )
            .then(() => self.clients.claim())
    );
});

self.addEventListener("fetch", (e) => {
    if (e.request.mode === "navigate" || e.request.method !== "GET") {
        return;
    }

    if (
        !e.request.url.startsWith(self.location.origin) ||
        e.request.url.includes("/login") ||
        e.request.url.includes("/oauth") ||
        e.request.url.includes("/metadata")
    ) {
        return e.respondWith(fetch(e.request));
    }

    e.respondWith(
        caches.match(e.request).then(
            (cached) =>
                cached ||
                fetch(e.request).then((response) => {
                    if (
                        response.type === "opaqueredirect" ||
                        response.status === 302
                    ) {
                        return response;
                    }

                    return caches.open(CACHE_NAME).then((cache) => {
                        cache.put(e.request, response.clone());
                        return response;
                    });
                })
        )
    );
});

self.addEventListener("message", (e) => {
    if (e.data === "SKIP_WAITING") {
        self.skipWaiting();
    }
});

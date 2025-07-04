const CACHE_NAME = "acw-cache-v1";
const PRECACHE_URLS = [
    "/",
    "/static/icon-dark.svg",
    "/static/icon-light.svg",
    "/static/css/main.css",
    "/static/js/main.js",
];

self.addEventListener("install", (event) => {
    event.waitUntil(
        caches
            .open(CACHE_NAME)
            .then((cache) => cache.addAll(PRECACHE_URLS))
            .then(() => self.skipWaiting())
    );
});

self.addEventListener("activate", (event) => {
    event.waitUntil(
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

self.addEventListener("fetch", (event) => {
    if (event.request.mode === "navigate") {
        return;
    }

    if (
        !event.request.url.startsWith(self.location.origin) ||
        event.request.url.includes("/login") ||
        event.request.url.includes("/oauth")
    ) {
        return event.respondWith(fetch(event.request));
    }

    event.respondWith(
        caches.match(event.request).then(
            (cached) =>
                cached ||
                fetch(event.request).then((response) => {
                    if (
                        response.type === "opaqueredirect" ||
                        response.status === 302
                    ) {
                        return response;
                    }

                    return caches.open(CACHE_NAME).then((cache) => {
                        cache.put(event.request, response.clone());
                        return response;
                    });
                })
        )
    );
});

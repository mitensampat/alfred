// Coach Alfred — Service Worker
// Handles push notifications and offline caching for PWA experience.
// Cache version is auto-bumped by the server — no manual update needed.

const CACHE_NAME = 'alfred-v2.2.0';

// Install: skip waiting to activate immediately
self.addEventListener('install', function(event) {
    console.log('[SW] Installing service worker');
    self.skipWaiting();
});

// Activate: clean old caches
self.addEventListener('activate', function(event) {
    console.log('[SW] Activating service worker');
    event.waitUntil(
        caches.keys().then(function(names) {
            return Promise.all(
                names.filter(function(name) { return name !== CACHE_NAME; })
                     .map(function(name) { return caches.delete(name); })
            );
        })
    );
    self.clients.claim();
});

// Fetch: network-first for everything, cache as offline fallback
self.addEventListener('fetch', function(event) {
    var url = new URL(event.request.url);

    // API calls: always go to network, no caching
    if (url.pathname.startsWith('/api/')) {
        return;
    }

    // HTML/static assets: network-first, cache as fallback
    // This ensures users always get the latest version
    event.respondWith(
        fetch(event.request).then(function(response) {
            if (response.ok) {
                var clone = response.clone();
                caches.open(CACHE_NAME).then(function(cache) {
                    cache.put(event.request, clone);
                });
            }
            return response;
        }).catch(function() {
            return caches.match(event.request);
        })
    );
});

// Push: receive and display notifications
self.addEventListener('push', function(event) {
    console.log('[SW] Push received');

    var data = {};
    if (event.data) {
        try {
            data = event.data.json();
        } catch(e) {
            data = { title: 'Coach Alfred', body: event.data.text() };
        }
    }

    var options = {
        body: data.body || '',
        icon: data.icon || '/icon-192.png',
        badge: '/icon-192.png',
        tag: data.tag || 'alfred-default',
        renotify: true,
        data: {
            url: data.url || '/home.html',
            type: data.type || null
        }
    };

    event.waitUntil(
        self.registration.showNotification(data.title || 'Coach Alfred', options)
    );
});

// Notification click: focus existing PWA window if possible, post message to trigger action.
// On iOS standalone mode, clients.openWindow() can fail or open Safari instead of the PWA.
// The robust approach: find an existing window first, focus it, and message it.
self.addEventListener('notificationclick', function(event) {
    event.notification.close();

    var notifData = event.notification.data || {};
    var targetUrl = notifData.url || '/home.html';
    var notifType = notifData.type || null;

    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList) {
            // Try to find an existing Alfred window and focus it
            for (var i = 0; i < clientList.length; i++) {
                var client = clientList[i];
                if (client.url.indexOf('/home.html') !== -1) {
                    // Found existing window — focus it and tell it about the notification
                    return client.focus().then(function(focusedClient) {
                        focusedClient.postMessage({
                            type: 'notification-click',
                            notificationType: notifType,
                            url: targetUrl
                        });
                        return focusedClient;
                    });
                }
            }
            // No existing window — open a new one, preserving notification intent in URL
            var openUrl = targetUrl;
            if (notifType) {
                openUrl += (openUrl.indexOf('?') === -1 ? '?' : '&') + 'notify_action=' + encodeURIComponent(notifType);
            }
            return clients.openWindow(openUrl);
        })
    );
});

// Notification close (dismissed without clicking)
self.addEventListener('notificationclose', function(event) {
    console.log('[SW] Notification dismissed:', event.notification.tag);
});

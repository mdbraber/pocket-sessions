// Fork: this self-built app can't claim pca.st / pocketcasts.com as universal links (only the official
// app can), so hand Pocket Casts podcast and episode pages to the app through its own URL scheme.
// Home, "get the app" and other non-link pages stay in Safari so they remain reachable.
(() => {
    const host = location.hostname.toLowerCase();
    const path = location.pathname;

    let isLink;
    if (host === "pca.st") {
        isLink = path !== "" && path !== "/" && !path.startsWith("/get");
    } else {
        isLink = ["/podcast/", "/private/", "/episode/", "/social/share/"].some((prefix) => path.startsWith(prefix));
    }

    if (isLink) {
        location.replace("pktc://weblink/" + location.href);
    }
})();

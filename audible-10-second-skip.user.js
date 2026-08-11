// ==UserScript==
// @name         Audible web player - 10 second skip
// @namespace    https://github.com/VRJunkie1/audible-place-keeper
// @version      1.0
// @description  Makes the skip buttons AND the arrow keys jump 10 seconds instead of 30 in the Audible web player.
// @match        https://www.audible.com/webplayer*
// @match        https://www.audible.co.uk/webplayer*
// @match        https://www.audible.ca/webplayer*
// @run-at       document-start
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    // ------------------------------------------------------------------
    // Change this one number if you want a different jump.
    // ------------------------------------------------------------------
    const SKIP_SECONDS = 10;

    function media() {
        const m = document.querySelector('audio, video');
        return (m && isFinite(m.duration)) ? m : null;
    }

    function seek(delta) {
        const m = media();
        if (!m) return false;
        const t = m.currentTime + delta;
        m.currentTime = Math.max(0, Math.min(t, m.duration || t));
        return true;
    }

    // Audible binds the arrow keys to its OWN 30-second skip, so adding a
    // listener is not enough - both would fire and you would move 40 seconds.
    // Running in the CAPTURE phase gets us the event first, and
    // stopImmediatePropagation means Audible's handler never sees it.
    window.addEventListener('keydown', function (e) {
        if (e.altKey || e.ctrlKey || e.metaKey) return;

        // never hijack typing
        const el = e.target;
        if (el && (el.isContentEditable ||
                   /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName || ''))) return;

        let delta = 0;
        if (e.key === 'ArrowLeft')  delta = -SKIP_SECONDS;
        if (e.key === 'ArrowRight') delta =  SKIP_SECONDS;
        if (!delta) return;

        if (seek(delta)) {
            e.preventDefault();
            e.stopImmediatePropagation();
        }
    }, true);

    // Same trick for the on-screen buttons.
    window.addEventListener('click', function (e) {
        const btn = e.target && e.target.closest &&
                    e.target.closest('[aria-label*="Skip"]');
        if (!btn) return;

        const label = btn.getAttribute('aria-label') || '';
        let delta = 0;
        if (/back|backward|rewind/i.test(label))  delta = -SKIP_SECONDS;
        else if (/forward/i.test(label))          delta =  SKIP_SECONDS;
        if (!delta) return;

        if (seek(delta)) {
            e.preventDefault();
            e.stopImmediatePropagation();
        }
    }, true);

    // Relabel the buttons so they tell the truth.
    //
    // This also matters for the place-keeper watcher in this repo: it reads the
    // number off the button's label to work out how far one press moves. Leave
    // the label saying 30 while the button moves 10 and the watcher's
    // arithmetic goes wrong.
    function relabel() {
        document.querySelectorAll('[aria-label*="Skip"]').forEach(function (b) {
            const l = b.getAttribute('aria-label') || '';
            const n = l.replace(/\b\d+\s*seconds\b/i, SKIP_SECONDS + ' seconds');
            if (n !== l) b.setAttribute('aria-label', n);

            // the number drawn inside the circular arrow icon
            b.querySelectorAll('text, tspan, span').forEach(function (t) {
                if (/^\s*\d+\s*$/.test(t.textContent)) {
                    t.textContent = String(SKIP_SECONDS);
                }
            });
        });
    }

    new MutationObserver(relabel).observe(document.documentElement,
                                          { childList: true, subtree: true });
    document.addEventListener('DOMContentLoaded', relabel);
    setInterval(relabel, 2000);
})();

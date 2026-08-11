// ==UserScript==
// @name         Audible web player - 10 second skip
// @namespace    https://github.com/VRJunkie1/audible-place-keeper
// @version      1.4
// @description  Makes the skip buttons AND the arrow keys jump 10 seconds instead of 30 in the Audible web player.
// @match        *://*.audible.com/*
// @match        *://*.audible.co.uk/*
// @match        *://*.audible.ca/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    // ------------------------------------------------------------------
    // Change this one number if you want a different jump.
    // Set SHOW_BADGE to false once you are happy it works.
    // ------------------------------------------------------------------
    const SKIP_SECONDS = 10;
    const SHOW_BADGE   = true;

    // ------------------------------------------------------------------
    // WHY THIS LOOKS THE WAY IT DOES
    //
    // The skip buttons are custom elements with an OPEN SHADOW ROOT:
    //
    //   <adbl-icon-button data-testid="skip-back" name="back-30">
    //     #shadow-root (open)
    //       <button id="container">
    //         <adbl-icon aria-label="Skip back 30 seconds" name="back-30">
    //
    // document.querySelectorAll() does not descend into shadow roots. The
    // data-testid and name attributes DO sit on the host, in ordinary DOM, so
    // finding the buttons is easy - but the visible "30" and the aria-label
    // are inside the shadow tree and have to be edited there.
    //
    // The player is also a React app that renders its controls well after
    // window.load, so nothing here may assume the buttons exist yet. Anything
    // that checks once, too early, reports a false failure.
    // ------------------------------------------------------------------

    const SELECTORS = [
        '[data-testid="skip-back"], [data-testid="skip-forward"]',
        'adbl-icon-button[name^="back-"], adbl-icon-button[name^="forward-"]',
        '[name="back-30"], [name="forward-30"]'
    ];

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

    function classify(el) {
        const s = ((el.getAttribute('data-testid') || '') + ' ' +
                   (el.getAttribute('name') || '')).toLowerCase();
        if (/back|rewind/.test(s)) return -SKIP_SECONDS;
        if (/forward/.test(s))     return  SKIP_SECONDS;
        return 0;
    }

    function skipControls() {
        for (const sel of SELECTORS) {
            const hits = Array.from(document.querySelectorAll(sel))
                .map(function (el) { return { el: el, delta: classify(el), why: sel }; })
                .filter(function (c) { return c.delta !== 0; });
            if (hits.length) return hits;
        }
        return [];
    }

    function deepNodes(root, out) {
        out = out || [];
        (root.children ? Array.from(root.children) : []).forEach(function (c) {
            out.push(c);
            if (c.shadowRoot) deepNodes(c.shadowRoot, out);
            deepNodes(c, out);
        });
        return out;
    }

    // --- arrow keys -------------------------------------------------------
    window.addEventListener('keydown', function (e) {
        if (e.altKey || e.ctrlKey || e.metaKey) return;
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

    // --- the on-screen buttons -------------------------------------------
    // A click starting inside a shadow root still reports the host element in
    // composedPath(), so this catches it without piercing anything.
    window.addEventListener('click', function (e) {
        const controls = skipControls();
        if (!controls.length) return;
        const path = e.composedPath ? e.composedPath() : [e.target];
        for (const node of path) {
            const hit = controls.find(function (c) { return c.el === node; });
            if (!hit) continue;
            if (seek(hit.delta)) {
                e.preventDefault();
                e.stopImmediatePropagation();
            }
            return;
        }
    }, true);

    // --- make the buttons tell the truth ----------------------------------
    // Relabelling also keeps the place-keeper watcher in step: it reads the
    // number off the accessible name to work out how far one press moves.
    function relabel() {
        skipControls().forEach(function (c) {
            deepNodes(c.el).forEach(function (n) {
                const l = n.getAttribute && n.getAttribute('aria-label');
                if (l && /\d+\s*seconds?/i.test(l)) {
                    const nl = l.replace(/\b\d+\s*seconds?\b/i, SKIP_SECONDS + ' seconds');
                    if (nl !== l) n.setAttribute('aria-label', nl);
                }
                if (n.childElementCount === 0 && /^\s*\d{1,3}\s*$/.test(n.textContent)) {
                    if (n.textContent.trim() !== String(SKIP_SECONDS)) {
                        n.textContent = String(SKIP_SECONDS);
                    }
                }
            });
        });
    }

    // --- badge that KEEPS LOOKING -----------------------------------------
    // v1.3's badge checked once, two seconds after load, and went red because
    // the controls had not rendered yet - reporting a failure that was really
    // just impatience. This polls for 45 seconds and only calls it a failure
    // if the buttons never turn up.
    function badge() {
        if (!SHOW_BADGE) return;
        const d = document.createElement('div');
        d.style.cssText = 'position:fixed;bottom:12px;left:12px;z-index:2147483647;max-width:90vw;' +
            'color:#fff;font:13px system-ui;padding:6px 10px;border-radius:6px;opacity:.95;' +
            'background:#555';
        d.textContent = '10s skip: looking for the buttons...';
        document.body.appendChild(d);

        let tries = 0;
        const timer = setInterval(function () {
            const c = skipControls();
            tries++;
            if (c.length) {
                clearInterval(timer);
                relabel();
                d.style.background = '#1b5e20';
                d.textContent = '10s skip active - found ' + c.length + ' buttons after ' + tries + 's';
                console.log('[10s skip] controls:', c);
                setTimeout(function () { d.remove(); }, 6000);
            } else if (tries >= 45) {
                clearInterval(timer);
                d.style.background = '#b71c1c';
                d.textContent = '10s skip: arrows work, buttons NOT found after 45s';
                console.log('[10s skip] no controls. adbl elements present:',
                    Array.from(document.querySelectorAll('adbl-icon-button, [data-testid]'))
                         .map(function (e) {
                             return e.tagName + ' testid=' + e.getAttribute('data-testid') +
                                    ' name=' + e.getAttribute('name');
                         }));
                setTimeout(function () { d.remove(); }, 15000);
            }
        }, 1000);
    }

    new MutationObserver(relabel).observe(document.documentElement,
                                          { childList: true, subtree: true });
    window.addEventListener('load', function () { relabel(); badge(); });
    setInterval(relabel, 2000);
})();

// ==UserScript==
// @name         Audible web player - 10 second skip
// @namespace    https://github.com/VRJunkie1/audible-place-keeper
// @version      1.3
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
    // document.querySelectorAll() does not descend into shadow roots, so
    // versions 1.0 to 1.2 searched a tree the buttons are not in and found
    // nothing, no matter how the labels were matched.
    //
    // Two things make this easy once you know:
    //   - data-testid sits on the HOST element, in the ordinary DOM.
    //   - the shadow root is open, so its contents can be reached and edited.
    // ------------------------------------------------------------------

    const HOST_SELECTOR = '[data-testid="skip-back"], [data-testid="skip-forward"]';

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

    function skipControls() {
        return Array.from(document.querySelectorAll(HOST_SELECTOR)).map(function (el) {
            const id = el.getAttribute('data-testid') || '';
            return { el: el, delta: /back/.test(id) ? -SKIP_SECONDS : SKIP_SECONDS, why: id };
        });
    }

    // Walk an element's own shadow tree. Small and scoped - not a whole-page
    // deep crawl.
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
    // Audible binds these to its own 30-second skip, so simply adding a
    // listener would fire both and move 40 seconds. Capture phase gets the
    // event first; stopImmediatePropagation means Audible never sees it.
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
    // A click that starts inside a shadow root still reports the host element
    // in composedPath(), so this catches it without piercing anything.
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
    // The visible "30" and the aria-label both live inside the shadow root.
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

    // --- badge ------------------------------------------------------------
    function badge() {
        if (!SHOW_BADGE) return;
        const c = skipControls();
        const d = document.createElement('div');
        d.textContent = c.length
            ? '10s skip active - buttons: ' + c.map(function (x) { return x.why; }).join(', ')
            : '10s skip: arrows work, buttons NOT found';
        d.style.cssText = 'position:fixed;bottom:12px;left:12px;z-index:2147483647;max-width:90vw;' +
            'background:' + (c.length ? '#1b5e20' : '#b71c1c') + ';color:#fff;' +
            'font:13px system-ui;padding:6px 10px;border-radius:6px;opacity:.95';
        document.body.appendChild(d);
        setTimeout(function () { d.remove(); }, 8000);
        console.log('[10s skip] controls:', c);
    }

    new MutationObserver(relabel).observe(document.documentElement,
                                          { childList: true, subtree: true });
    window.addEventListener('load', function () {
        relabel();
        setTimeout(badge, 2000);
    });
    setInterval(relabel, 2000);
})();

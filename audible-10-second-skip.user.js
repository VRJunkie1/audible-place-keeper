// ==UserScript==
// @name         Audible web player - 10 second skip
// @namespace    https://github.com/VRJunkie1/audible-place-keeper
// @version      1.1
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

    // Find the skip buttons WITHOUT assuming they carry an aria-label. v1.0
    // assumed that and found nothing. Look at every label-ish source a button
    // might use, plus the digits drawn inside the icon.
    function describe(el) {
        const bits = [
            el.getAttribute('aria-label'),
            el.getAttribute('title'),
            el.getAttribute('data-testid'),
            el.getAttribute('name'),
            el.className && el.className.baseVal !== undefined
                ? el.className.baseVal : el.className,
            el.textContent
        ];
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
            labelledBy.split(/\s+/).forEach(function (id) {
                const t = document.getElementById(id);
                if (t) bits.push(t.textContent);
            });
        }
        return bits.filter(Boolean).join(' ').toLowerCase();
    }

    function skipButtons() {
        const out = [];
        document.querySelectorAll('button, [role="button"], a').forEach(function (el) {
            const d = describe(el);
            if (!/skip|forward|back|rewind/.test(d)) return;
            if (/chapter|section|speed|bookmark/.test(d)) return;   // not these
            const back = /back|rewind/.test(d);
            const fwd  = /forward/.test(d);
            if (back || fwd) out.push({ el: el, delta: back ? -SKIP_SECONDS : SKIP_SECONDS, desc: d });
        });
        return out;
    }

    // --- arrow keys -------------------------------------------------------
    // Audible binds these to its OWN 30-second skip, so simply adding a
    // listener would fire both and move 40 seconds. Capture phase gets us the
    // event first; stopImmediatePropagation means Audible never sees it.
    // NOTE: this path does not depend on finding any button, so if the arrows
    // work and the buttons do not, the script is running and only the button
    // detection is wrong.
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
    window.addEventListener('click', function (e) {
        const path = e.composedPath ? e.composedPath() : [e.target];
        for (const node of path) {
            if (!node || node.nodeType !== 1) continue;
            if (!/^(BUTTON|A)$/.test(node.tagName) &&
                node.getAttribute && node.getAttribute('role') !== 'button') continue;
            const d = describe(node);
            if (/chapter|section|speed|bookmark/.test(d)) return;
            let delta = 0;
            if (/back|rewind/.test(d))    delta = -SKIP_SECONDS;
            else if (/forward/.test(d))   delta =  SKIP_SECONDS;
            if (!delta) continue;
            if (seek(delta)) {
                e.preventDefault();
                e.stopImmediatePropagation();
            }
            return;
        }
    }, true);

    // --- make the buttons tell the truth ----------------------------------
    // Also keeps the place-keeper watcher in step: it reads the number off the
    // button label to work out how far one press moves.
    function relabel() {
        skipButtons().forEach(function (b) {
            const l = b.el.getAttribute('aria-label');
            if (l) {
                const n = l.replace(/\b\d+\s*seconds?\b/i, SKIP_SECONDS + ' seconds');
                if (n !== l) b.el.setAttribute('aria-label', n);
            }
            b.el.querySelectorAll('text, tspan, span, div').forEach(function (t) {
                if (t.children.length === 0 && /^\s*\d{1,3}\s*$/.test(t.textContent)) {
                    t.textContent = String(SKIP_SECONDS);
                }
            });
        });
    }

    // --- one-off badge so you can see whether it loaded and what it found --
    function badge() {
        if (!SHOW_BADGE) return;
        const n = skipButtons().length;
        const d = document.createElement('div');
        d.textContent = '10s skip active - found ' + n + ' skip button(s)';
        d.style.cssText = 'position:fixed;bottom:12px;left:12px;z-index:2147483647;' +
            'background:' + (n ? '#1b5e20' : '#b71c1c') + ';color:#fff;' +
            'font:13px system-ui;padding:6px 10px;border-radius:6px;opacity:.95';
        document.body.appendChild(d);
        setTimeout(function () { d.remove(); }, 6000);
    }

    new MutationObserver(relabel).observe(document.documentElement,
                                          { childList: true, subtree: true });
    window.addEventListener('load', function () {
        relabel();
        setTimeout(badge, 1500);
    });
    setInterval(relabel, 2000);
})();

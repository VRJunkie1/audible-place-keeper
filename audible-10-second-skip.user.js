// ==UserScript==
// @name         Audible web player - 10 second skip
// @namespace    https://github.com/VRJunkie1/audible-place-keeper
// @version      1.2
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

    // ------------------------------------------------------------------
    // Finding the buttons.
    //
    // v1.0 looked for [aria-label*="Skip"] and found nothing. v1.1 checked
    // more attributes but still only ON button/a/[role=button] elements, and
    // still found nothing - so the label is not on the clickable element.
    //
    // v1.2 inverts it: find the LABEL anywhere in the document, then walk UP
    // to whatever clickable thing contains it. That works whether the label
    // is an aria-label, a title, an SVG <title>, or visually-hidden text in a
    // nested span.
    // ------------------------------------------------------------------
    const LABEL_RE = /skip\s*(back|backward|forward|rewind)|(?:back|forward)\s*\d+\s*sec/i;

    function clickableAncestor(el) {
        let n = el;
        for (let i = 0; n && i < 8; i++, n = n.parentElement) {
            if (!n.tagName) continue;
            if (/^(BUTTON|A)$/.test(n.tagName)) return n;
            if (n.getAttribute && n.getAttribute('role') === 'button') return n;
            if (n.hasAttribute && n.hasAttribute('tabindex')) return n;
            try {
                if (getComputedStyle(n).cursor === 'pointer') return n;
            } catch (e) { /* ignore */ }
        }
        return null;
    }

    function skipControls() {
        const found = new Map();

        // 1. anything whose label text mentions skipping
        document.querySelectorAll('*').forEach(function (el) {
            if (el.children.length > 3) return;          // keep it to leaf-ish nodes
            const txt = [
                el.getAttribute && el.getAttribute('aria-label'),
                el.getAttribute && el.getAttribute('title'),
                el.tagName === 'title' ? el.textContent : null,
                el.childElementCount === 0 ? el.textContent : null
            ].filter(Boolean).join(' ');
            if (!txt || !LABEL_RE.test(txt)) return;
            if (/chapter|section|speed|bookmark/i.test(txt)) return;

            const btn = clickableAncestor(el);
            if (!btn || found.has(btn)) return;
            const back = /back|rewind/i.test(txt);
            found.set(btn, { el: btn, delta: back ? -SKIP_SECONDS : SKIP_SECONDS, why: txt.trim().slice(0, 40) });
        });

        if (found.size) return Array.from(found.values());

        // 2. Fallback: the number drawn inside the circular arrows. The two
        //    skip controls sit either side of Play, so in DOM order the first
        //    is back and the second is forward.
        const digits = [];
        document.querySelectorAll('text, tspan, span, div').forEach(function (el) {
            if (el.childElementCount !== 0) return;
            if (!/^\s*\d{1,3}\s*$/.test(el.textContent)) return;
            const btn = clickableAncestor(el);
            if (btn && digits.indexOf(btn) === -1) digits.push(btn);
        });
        if (digits.length === 2) {
            return [
                { el: digits[0], delta: -SKIP_SECONDS, why: 'digit-fallback (first)' },
                { el: digits[1], delta:  SKIP_SECONDS, why: 'digit-fallback (second)' }
            ];
        }
        return [];
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
    // Also keeps the place-keeper watcher in step: it reads the number off the
    // button label to work out how far one press moves.
    function relabel() {
        skipControls().forEach(function (c) {
            const l = c.el.getAttribute && c.el.getAttribute('aria-label');
            if (l) {
                const n = l.replace(/\b\d+\s*seconds?\b/i, SKIP_SECONDS + ' seconds');
                if (n !== l) c.el.setAttribute('aria-label', n);
            }
            c.el.querySelectorAll('text, tspan, span, div').forEach(function (t) {
                if (t.childElementCount === 0 && /^\s*\d{1,3}\s*$/.test(t.textContent)) {
                    t.textContent = String(SKIP_SECONDS);
                }
            });
        });
    }

    // --- badge, so it reports rather than failing silently -----------------
    function badge() {
        if (!SHOW_BADGE) return;
        const c = skipControls();
        const d = document.createElement('div');
        d.textContent = c.length
            ? '10s skip active - ' + c.length + ' button(s): ' + c.map(function (x) { return x.why; }).join(' | ')
            : '10s skip: arrows work, buttons NOT found';
        d.style.cssText = 'position:fixed;bottom:12px;left:12px;z-index:2147483647;max-width:90vw;' +
            'background:' + (c.length ? '#1b5e20' : '#b71c1c') + ';color:#fff;' +
            'font:13px system-ui;padding:6px 10px;border-radius:6px;opacity:.95';
        document.body.appendChild(d);
        setTimeout(function () { d.remove(); }, 8000);

        // Deeper detail for the console (F12), if the buttons still elude us.
        console.log('[10s skip] controls found:', c);
        if (!c.length) {
            const near = [];
            document.querySelectorAll('button,[role="button"],a,[tabindex]').forEach(function (b) {
                near.push({
                    tag: b.tagName,
                    aria: b.getAttribute('aria-label'),
                    title: b.getAttribute('title'),
                    cls: (b.className && b.className.baseVal !== undefined ? b.className.baseVal : b.className),
                    text: (b.textContent || '').trim().slice(0, 30)
                });
            });
            console.log('[10s skip] clickable elements on the page:', near);
        }
    }

    new MutationObserver(relabel).observe(document.documentElement,
                                          { childList: true, subtree: true });
    window.addEventListener('load', function () {
        relabel();
        setTimeout(badge, 2000);
    });
    setInterval(relabel, 2000);
})();

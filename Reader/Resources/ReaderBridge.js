/**
 * ReaderBridge.js
 * 
 * Optimized for "Serial Elastic Map" scroll-syncing.
 * Implements land-ownership territories with directional handover.
 * Now includes Density-Aware Allocation to ensure all markers are reachable in short chapters.
 */

// --- Constants ---
const MIN_TERRITORY_HEIGHT = 100; // Preferred minimum scroll height for each marker
const HYSTERESIS_THRESHOLD = 20;  // Pixels to 'break' focus into a new zone
const EYE_LINE_RATIO = 0.4;       // Focal point at 40% of viewport height
const VISIBILITY_BUFFER = 5;      // Pixels marker can be off-screen before clearing
const DEBUG_MODE = true;          // Visualizes territories and focus logic

// --- Global State ---
const focusState = { 
    lastScrollY: 0,
    lastVelocity: 0,
    activeIds: { annotation: null, image: null, footnote: null },
    currentStationIndex: -1,
    stations: [],      // Master Timeline of all markers
    boundaries: []     // Virtual Map boundaries
};

let scrollTicking = false;

/**
 * Programmatic Scroll & Lock Controller
 */
const programmatic = (() => {
    const state = {
        active: false,
        sticky: false, 
        targetId: null,
        targetY: null,
        expectedY: null,
        lastSetAt: 0,
        raf: null,
        timeout: null,
        sessionId: 0
    };

    const driftTolerance = 1.5; 
    const staleWriteMs = 60;

    const cancel = (silent = false) => {
        const wasLocked = state.sticky;
        if (state.raf) cancelAnimationFrame(state.raf);
        state.raf = null;
        state.active = false;
        state.sticky = false; 
        state.targetId = null;
        state.targetY = null;
        state.expectedY = null;
        state.lastSetAt = 0;
        state.sessionId++; 
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        if (wasLocked && !silent) updateFocus();
    };

    const complete = () => {
        if (state.raf) cancelAnimationFrame(state.raf);
        state.raf = null;
        state.active = false;
        state.expectedY = state.targetY; 
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        updateFocus();
    };

    const start = (targetId, targetY) => {
        cancel(true); 
        const currentSession = state.sessionId;
        const startY = window.scrollY;
        const distance = Math.abs(targetY - startY);
        
        state.active = true;
        state.sticky = true;
        state.targetId = targetId;
        state.targetY = targetY;
        state.expectedY = startY;
        state.lastSetAt = performance.now();

        updateFocus();

        if (distance < 2) {
            window.scrollTo({ top: targetY, behavior: 'auto' });
            complete();
            return;
        }

        const duration = Math.min(900, Math.max(280, distance * 0.65));
        state.timeout = setTimeout(() => {
            if (state.active && state.sessionId === currentSession) complete();
        }, duration + 500);

        const startTime = performance.now();
        const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);
        const step = (now) => {
            if (!state.active || state.sessionId !== currentSession) return;
            const progress = Math.min(1, (now - startTime) / duration);
            const eased = easeOutCubic(progress);
            const nextY = startY + (targetY - startY) * eased;
            state.expectedY = nextY;
            state.lastSetAt = performance.now();
            window.scrollTo({ top: nextY, behavior: 'auto' });
            if (progress < 1) {
                state.raf = requestAnimationFrame(step);
            } else {
                state.raf = null;
                complete();
            }
        };
        state.raf = requestAnimationFrame(step);
    };

    return {
        start,
        noteScroll: (actualY) => {
            if (!state.sticky) return;
            const drift = state.expectedY === null ? 0 : Math.abs(actualY - state.expectedY);
            const sinceWrite = performance.now() - state.lastSetAt;
            if (drift > driftTolerance || (state.active && sinceWrite > staleWriteMs)) cancel();
        },
        isActive: () => state.active,
        isSticky: () => state.sticky,
        preferredTargetId: () => state.sticky ? state.targetId : null
    };
})();

// --- Layout Logic ---

function getBlocks() {
    return Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li'));
}

function getMarkers() {
    const markers = Array.from(document.querySelectorAll('.annotation-marker, .image-marker, .footnote-ref'));
    return markers.map((m, index) => {
        const rect = m.getBoundingClientRect();
        const type = m.classList.contains('annotation-marker') ? 'annotation' : (m.classList.contains('image-marker') ? 'image' : 'footnote');
        const id = m.dataset.annotationId || m.dataset.imageId || (m.getAttribute('href')?.split('#')[1] || m.id);
        const block = m.closest('[id^="block-"]');
        const blockId = block ? parseInt(block.id.replace("block-", ""), 10) : parseInt(m.dataset.blockId || "0", 10);
        return { el: m, id, type, order: index, blockId, y: rect.top + window.scrollY + (rect.height * 0.5) };
    }).sort((a, b) => a.y - b.y || a.order - b.order);
}

/**
 * Builds the Elastic Territory Map.
 * Now adapts MIN_TERRITORY_HEIGHT to ensure all markers fit in short chapters.
 */
function buildTerritoryMap() {
    const stations = getMarkers();
    const vH = window.innerHeight;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - vH);
    const n = stations.length;

    if (n === 0) {
        focusState.stations = [];
        focusState.boundaries = [];
        return;
    }

    const pointerMin = vH * EYE_LINE_RATIO;
    const pointerMax = scrollMax + pointerMin;
    const pointerRange = pointerMax - pointerMin;

    // Density Safety: Ensure MIN_TERRITORY_HEIGHT doesn't exceed available space
    const effectiveMinHeight = Math.min(MIN_TERRITORY_HEIGHT, pointerRange / n);

    let boundaries = [];
    let cumulativeOffset = 0;

    for (let i = 0; i < n - 1; i++) {
        const naturalMidpoint = (stations[i].y + stations[i+1].y) / 2;
        const scrollRatio = naturalMidpoint / scrollHeight;
        let idealBoundary = pointerMin + (scrollRatio * pointerRange);
        let actualBoundary = idealBoundary + cumulativeOffset;
        
        const prevBoundary = i === 0 ? pointerMin : boundaries[i-1];
        
        // 1. Enforce effective minimum height (Push Down)
        if (actualBoundary < prevBoundary + effectiveMinHeight) {
            const push = (prevBoundary + effectiveMinHeight) - actualBoundary;
            actualBoundary += push;
            cumulativeOffset += push;
        } 
        // 2. Slack Absorption (Elastic Return)
        else if (cumulativeOffset > 0) {
            const slack = actualBoundary - (prevBoundary + effectiveMinHeight);
            const absorption = Math.min(cumulativeOffset, slack * 0.4);
            actualBoundary -= absorption;
            cumulativeOffset -= absorption;
        }
        
        // 3. Final Safety Clamp: Don't push boundaries past reachable pointerMax
        const remainingStations = n - 1 - i;
        const maxAllowed = pointerMax - (remainingStations * effectiveMinHeight);
        if (actualBoundary > maxAllowed) {
            const overflow = actualBoundary - maxAllowed;
            actualBoundary = maxAllowed;
            cumulativeOffset -= overflow;
        }

        boundaries.push(actualBoundary);
    }
    boundaries.push(pointerMax);

    focusState.stations = stations;
    focusState.boundaries = boundaries;
}

/**
 * Main Update Loop
 */
function updateFocus() {
    const scrollY = window.scrollY;
    const vH = window.innerHeight;
    const scrollMax = document.documentElement.scrollHeight - vH;
    const scrollPercent = scrollMax > 0 ? (scrollY / scrollMax) : 0;
    
    const currentCount = document.querySelectorAll('.annotation-marker, .image-marker, .footnote-ref').length;
    if (currentCount !== focusState.stations.length || focusState.boundaries.length === 0) {
        buildTerritoryMap();
    }

    const isLocked = programmatic.isSticky();
    const targetId = programmatic.preferredTargetId();
    
    let newStationIndex = -1;

    // Visibility Data
    const markerData = focusState.stations.map(s => {
        const rect = s.el.getBoundingClientRect();
        const isVisible = rect.bottom >= -VISIBILITY_BUFFER && rect.top <= vH + VISIBILITY_BUFFER;
        return { ...s, isVisible, rect };
    });

    if (isLocked && targetId) {
        newStationIndex = markerData.findIndex(s => (s.type + "-" + s.id) === targetId || s.id === targetId);
    } else if (markerData.length > 0) {
        const pointerY = scrollY + (vH * EYE_LINE_RATIO);
        let idx = focusState.currentStationIndex;
        
        if (idx === -1) {
            idx = focusState.boundaries.findIndex(b => pointerY <= b);
            if (idx === -1) idx = markerData.length - 1;
        } else {
            const lower = idx === 0 ? 0 : focusState.boundaries[idx - 1];
            const upper = focusState.boundaries[idx];
            
            // Instant catch-up for large moves
            if (pointerY > upper + 100 || pointerY < lower - 100) {
                idx = focusState.boundaries.findIndex(b => pointerY <= b);
                if (idx === -1) idx = markerData.length - 1;
            } else {
                if (pointerY > upper + HYSTERESIS_THRESHOLD && idx < markerData.length - 1) idx++;
                else if (pointerY < lower - HYSTERESIS_THRESHOLD && idx > 0) idx--;
            }
        }

        // Serial Visibility Gate (Dynamic Handover)
        const owner = markerData[idx];
        if (owner && owner.isVisible) {
            newStationIndex = idx;
        } else {
            if (owner && scrollY + owner.rect.bottom < 0) {
                const nextVisible = markerData.slice(idx + 1).find(m => m.isVisible);
                if (nextVisible) newStationIndex = markerData.indexOf(nextVisible);
            } else if (owner && owner.rect.top > vH) {
                const prevVisible = markerData.slice(0, idx).reverse().find(m => m.isVisible);
                if (prevVisible) newStationIndex = markerData.indexOf(prevVisible);
            }
        }
    }

    // Paragraph Tracking
    const blocks = getBlocks();
    let activeBlockIndex = -1;
    let minBlockDist = Infinity;
    const blockEyeLine = scrollY + (vH * 0.45); 
    blocks.forEach((b, i) => {
        const r = b.getBoundingClientRect();
        const top = r.top + scrollY, bot = r.bottom + scrollY;
        const d = (blockEyeLine >= top && blockEyeLine <= bot) ? 0 : Math.min(Math.abs(top - blockEyeLine), Math.abs(bot - blockEyeLine));
        if (d < minBlockDist) { minBlockDist = d; activeBlockIndex = i; }
    });

    const hasChanged = newStationIndex !== focusState.currentStationIndex;
    if (hasChanged) {
        const station = markerData[newStationIndex];
        focusState.currentStationIndex = newStationIndex;
        if (!isLocked && station && station.isVisible && focusState.lastVelocity < 40) pulseMarker(station.el);

        webkit.messageHandlers.readerBridge.postMessage({
            type: 'scrollPosition',
            annotationId: station?.type === 'annotation' ? station.id : null, 
            imageId: station?.type === 'image' ? station.id : null, 
            footnoteRefId: station?.type === 'footnote' ? station.id : null,
            blockId: activeBlockIndex + 1,
            primaryType: station?.type || null,
            scrollY: scrollY, scrollPercent: scrollPercent, viewportHeight: vH,
            isProgrammatic: isLocked
        });
    }

    if (DEBUG_MODE) updateDebugOverlay();
}

/**
 * Visualizes territories for debugging.
 */
function updateDebugOverlay() {
    let container = document.getElementById('territoryDebug');
    if (!container) {
        container = document.createElement('div');
        container.id = 'territoryDebug';
        container.style = "position:absolute; top:0; left:0; width:100%; height:100%; pointer-events:none; z-index:9999;";
        document.body.appendChild(container);
    }
    container.innerHTML = '';
    const vH = window.innerHeight;
    const scrollY = window.scrollY;
    const pointerY = scrollY + (vH * EYE_LINE_RATIO);
    
    const pLine = document.createElement('div');
    pLine.style = `position:absolute; top:${pointerY}px; left:0; width:100%; height:2px; background:rgba(255,0,0,0.6);`;
    container.appendChild(pLine);

    const pMin = vH * EYE_LINE_RATIO;
    focusState.boundaries.forEach((b, i) => {
        const start = i === 0 ? pMin : focusState.boundaries[i-1];
        const box = document.createElement('div');
        box.style = `position:absolute; top:${start}px; left:0; width:100%; height:${b - start}px; border-top:1px solid rgba(0,0,0,0.1);`;
        box.style.backgroundColor = i % 2 === 0 ? 'rgba(0, 255, 0, 0.05)' : 'rgba(0, 0, 255, 0.05)';
        const label = document.createElement('span');
        label.innerText = `T${i} (${focusState.stations[i].id})`;
        label.style = "font-size:9px; color:rgba(0,0,0,0.3); margin-left:10px;";
        box.appendChild(label);
        container.appendChild(box);
    });
}

function pulseMarker(el) {
    if (!el) return;
    const color = el.classList.contains('image-marker') ? '--iris' : '--rose';
    el.style.setProperty('--highlight-color', 'var(' + color + ')');
    el.classList.remove('marker-pulse');
    void el.offsetWidth;
    el.classList.add('marker-pulse');
    setTimeout(() => el.classList.remove('marker-pulse'), 650);
}

// --- External API ---

function performSmoothScroll(el, ratio, targetId) {
    const rect = el.getBoundingClientRect();
    const targetY = Math.max(0, window.scrollY + rect.top - (window.innerHeight * ratio));
    programmatic.start(targetId, targetY);
    if (el.classList.contains('annotation-marker') || el.classList.contains('image-marker') || el.classList.contains('footnote-ref')) {
        el.classList.add('marker-highlight');
        const color = el.classList.contains('image-marker') ? '--iris' : '--rose';
        el.style.setProperty('--highlight-color', 'var(' + color + ')');
        setTimeout(() => el.classList.remove('marker-highlight'), 1500);
    }
}

function scrollToAnnotation(id) {
    const el = document.querySelector('[data-annotation-id="' + id + '"]');
    if (el) performSmoothScroll(el, 0.4, 'annotation-' + id);
}

function scrollToBlock(id, markerId, type) {
    const blocks = getBlocks();
    if (id > 0 && id <= blocks.length) {
        const block = blocks[id-1];
        performSmoothScroll(block, 0.4, markerId && type ? `${type}-${markerId}` : `block-${id}`);
    }
}

function scrollToQuote(quote) {
    const el = document.querySelector('[href="#' + quote + '"], [id="' + quote + '"]');
    if (el) performSmoothScroll(el, 0.4, 'footnote-' + quote);
}

function scrollToPercent(p) { window.scrollTo({top: (document.documentElement.scrollHeight - window.innerHeight) * p, behavior:'auto'}); }
function scrollToOffset(o) { window.scrollTo({top: o, behavior:'auto'}); }

// --- Event Listeners ---

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;
    focusState.lastVelocity = Math.abs(scrollY - focusState.lastScrollY);
    focusState.lastScrollY = scrollY;
    programmatic.noteScroll(scrollY);
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            updateFocus();
            const scrollMax = document.documentElement.scrollHeight - window.innerHeight;
            if (scrollMax > 0 && scrollY >= scrollMax - 1) focusState.reachedBottom = true;
            else if (scrollY < scrollMax - 20) focusState.reachedBottom = false;
            if (focusState.reachedBottom && scrollY > scrollMax + 5) {
                webkit.messageHandlers.readerBridge.postMessage({type:'bottomTug'});
                focusState.reachedBottom = false; 
            }
            scrollTicking = false;
        });
    }
});

const selectionOverlay = document.getElementById('selectionOverlay');
function updateSelectionOverlay() {
    if (!selectionOverlay) return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) { selectionOverlay.innerHTML = ''; return; }
    const range = sel.getRangeAt(0);
    const rects = Array.from(range.getClientRects());
    selectionOverlay.innerHTML = '';
    rects.forEach(rect => {
        const d = document.createElement('div');
        d.className = 'selection-rect';
        d.style.left = (rect.left + window.scrollX) + 'px';
        d.style.top = (rect.top + window.scrollY) + 'px';
        d.style.width = rect.width + 'px';
        d.style.height = rect.height + 'px';
        selectionOverlay.appendChild(d);
    });
}

document.addEventListener('selectionchange', updateSelectionOverlay);
window.addEventListener('resize', () => { buildTerritoryMap(); updateFocus(); });

document.addEventListener('click', e => {
    const t = e.target;
    if (t.classList.contains('annotation-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'annotationClick', id: t.dataset.annotationId});
    if (t.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerClick', id: t.dataset.imageId});
});

document.addEventListener('dblclick', e => {
    if (e.target.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerDblClick', id: e.target.dataset.imageId});
});

document.addEventListener('mouseup', e => {
    setTimeout(() => {
        const sel = window.getSelection(), txt = sel.toString().trim(), popup = document.getElementById('wordPopup');
        if (!sel.isCollapsed && txt) {
            const container = sel.getRangeAt(0).startContainer.parentElement, blocks = getBlocks();
            const bId = blocks.findIndex(b => b.contains(container)) + 1;
            popup.style.left = e.clientX + 'px'; popup.style.top = (e.clientY + 10) + 'px'; popup.style.display = 'block';
            window.selectedWord = txt; window.selectedBlockId = bId || 1; window.selectedContext = container.textContent;
        } else if (!e.target.closest('.word-popup')) popup.style.display = 'none';
    }, 20);
});

document.addEventListener('mousedown', e => { if(!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display = 'none'; });
function handleExplain() { webkit.messageHandlers.readerBridge.postMessage({type:'explain', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }
function handleGenerateImage() { webkit.messageHandlers.readerBridge.postMessage({type:'generateImage', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }
function injectMarkerAtBlock(aId, bId) { const blocks = getBlocks(); if (bId > 0 && bId <= blocks.length) { const m = document.createElement('span'); m.className = 'annotation-marker'; m.dataset.annotationId = aId; m.dataset.blockId = bId; blocks[bId-1].appendChild(m); } }
function injectImageMarker(iId, bId) { const blocks = getBlocks(); if (bId > 0 && bId <= blocks.length) { const m = document.createElement('span'); m.className = 'image-marker'; m.dataset.imageId = iId; m.dataset.blockId = bId; blocks[bId-1].appendChild(m); } }
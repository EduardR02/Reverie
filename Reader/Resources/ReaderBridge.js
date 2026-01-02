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
const DEBUG_MODE = false;          // Visualizes territories and focus logic

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
 * Now uses a Stop-Centered approach where territories are divided based on
 * Ideal Stops (the scroll position where a marker sits at 40% height).
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
        focusState.stops = [];
        return;
    }

    // Density Safety: Ensure MIN_TERRITORY_HEIGHT doesn't exceed available scroll range
    const effectiveMinHeight = Math.min(MIN_TERRITORY_HEIGHT, scrollMax / n);

    // 1. Calculate Ideal Stops
    // The scroll position where the marker is at EYE_LINE_RATIO
    let stops = stations.map(s => {
        const ideal = s.y - (vH * EYE_LINE_RATIO);
        return Math.max(0, Math.min(scrollMax, ideal));
    });

    // 2. Enforce Minimum Spacing (Forward Pass)
    for (let i = 1; i < n; i++) {
        if (stops[i] < stops[i-1] + effectiveMinHeight) {
            stops[i] = stops[i-1] + effectiveMinHeight;
        }
    }

    // 3. Backward Pass (to respect scrollMax while maintaining spacing)
    if (stops[n-1] > scrollMax) {
        stops[n-1] = scrollMax;
        for (let i = n - 2; i >= 0; i--) {
            if (stops[i] > stops[i+1] - effectiveMinHeight) {
                stops[i] = stops[i+1] - effectiveMinHeight;
            }
        }
    }

    // 4. Calculate Boundaries (midway between adjusted stops)
    let boundaries = [];
    for (let i = 0; i < n - 1; i++) {
        boundaries.push((stops[i] + stops[i+1]) / 2);
    }
    // Final boundary is beyond the end of the scroll range
    boundaries.push(scrollMax + 1000);

    focusState.stations = stations;
    focusState.stops = stops;
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
        // Check if marker is within viewport (with a small buffer)
        const isVisible = rect.bottom >= -VISIBILITY_BUFFER && rect.top <= vH + VISIBILITY_BUFFER;
        return { ...s, isVisible, rect };
    });

    if (isLocked && targetId) {
        newStationIndex = markerData.findIndex(s => (s.type + "-" + s.id) === targetId || s.id === targetId);
    } else if (markerData.length > 0) {
        let idx = focusState.currentStationIndex;
        
        if (idx === -1) {
            idx = focusState.boundaries.findIndex(b => scrollY <= b);
            if (idx === -1) idx = markerData.length - 1;
        } else {
            const lower = idx === 0 ? 0 : focusState.boundaries[idx - 1];
            const upper = focusState.boundaries[idx];
            
            // Instant catch-up for large moves
            if (scrollY > upper + 100 || scrollY < lower - 100) {
                idx = focusState.boundaries.findIndex(b => scrollY <= b);
                if (idx === -1) idx = markerData.length - 1;
            } else {
                if (scrollY > upper + HYSTERESIS_THRESHOLD && idx < markerData.length - 1) idx++;
                else if (scrollY < lower - HYSTERESIS_THRESHOLD && idx > 0) idx--;
            }
        }

        // Serial Visibility Gate (Dynamic Handover)
        const owner = markerData[idx];
        if (owner && owner.isVisible) {
            newStationIndex = idx;
        } else {
            if (owner && owner.rect.bottom < 0) { // Off-screen Top
                const nextVisible = markerData.slice(idx + 1).find(m => m.isVisible);
                if (nextVisible) newStationIndex = markerData.indexOf(nextVisible);
            } else if (owner && owner.rect.top > vH) { // Off-screen Bottom
                const prevVisible = markerData.slice(0, idx).reverse().find(m => m.isVisible);
                if (prevVisible) newStationIndex = markerData.indexOf(prevVisible);
            }
        }
    }

    // Paragraph Tracking
    const blocks = getBlocks();
    let activeBlockIndex = -1;
    let minBlockDist = Infinity;
    const blockEyeLine = scrollY + (vH * EYE_LINE_RATIO); 
    blocks.forEach((b, i) => {
        const r = b.getBoundingClientRect();
        const top = r.top + scrollY, bot = r.bottom + scrollY;
        const d = (blockEyeLine >= top && blockEyeLine <= bot) ? 0 : Math.min(Math.abs(top - blockEyeLine), Math.abs(bot - blockEyeLine));
        if (d < minBlockDist) { minBlockDist = d; activeBlockIndex = i; }
    });

    const hasChanged = newStationIndex !== focusState.currentStationIndex;
    const significantScroll = Math.abs(scrollY - (focusState.lastReportedScrollY || 0)) > 30;

    if (hasChanged || significantScroll) {
        const station = markerData[newStationIndex];
        focusState.currentStationIndex = newStationIndex;
        focusState.lastReportedScrollY = scrollY;
        
        if (hasChanged && !isLocked && station && station.isVisible && focusState.lastVelocity < 40) {
            pulseMarker(station.el);
        }

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
 * Provides a sidebar mini-map and in-situ highlights.
 */
function updateDebugOverlay() {
    let container = document.getElementById('territoryDebug');
    if (!container) {
        container = document.createElement('div');
        container.id = 'territoryDebug';
        container.style = "position:absolute; top:0; left:0; width:100%; height:100%; pointer-events:none; z-index:9999; font-family:monospace;";
        document.body.appendChild(container);
    }
    container.innerHTML = '';
    
    const vH = window.innerHeight;
    const scrollY = window.scrollY;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - vH);
    
    // --- 1. Sidebar Mini-map (Fixed) ---
    const sidebarWidth = 60;
    const sidebar = document.createElement('div');
    sidebar.style = `position:fixed; top:0; right:0; width:${sidebarWidth}px; height:100vh; background:rgba(0,0,0,0.05); border-left:1px solid rgba(0,0,0,0.1); z-index:10001;`;
    container.appendChild(sidebar);

    // Current Scroll Indicator in Sidebar
    const scrollIndicator = document.createElement('div');
    const scrollPosRatio = scrollY / scrollMax;
    scrollIndicator.style = `position:absolute; top:${scrollPosRatio * 100}%; right:0; width:100%; height:2px; background:red; z-index:10002;`;
    sidebar.appendChild(scrollIndicator);

    // --- 2. Territories & Stops ---
    focusState.boundaries.forEach((b, i) => {
        const start = i === 0 ? 0 : focusState.boundaries[i-1];
        const height = b - start;
        if (height <= 0) return;

        const isActive = scrollY >= start && scrollY < b;
        const color = i % 2 === 0 ? '0, 255, 0' : '0, 0, 255';
        const opacity = isActive ? '0.1' : '0.03';

        // A. In-situ Box (Full Width)
        const box = document.createElement('div');
        box.style = `position:absolute; top:${start}px; left:0; width:100%; height:${height}px; border-top:1px solid rgba(0,0,0,0.05); box-sizing:border-box;`;
        box.style.backgroundColor = `rgba(${color}, ${opacity})`;
        
        if (isActive) {
            box.style.borderLeft = "4px solid red";
        }

        const label = document.createElement('span');
        label.innerText = `T${i}:${focusState.stations[i].type.charAt(0)} Stop:${Math.round(focusState.stops[i])}`;
        label.style = `font-size:10px; color:${isActive ? 'red' : 'rgba(0,0,0,0.4)'}; font-weight:${isActive ? 'bold' : 'normal'}; margin-left:10px; position:absolute; top:4px; background:rgba(255,255,255,0.7); padding:2px; border-radius:2px;`;
        box.appendChild(label);

        // B. Mini-map Segment
        const segment = document.createElement('div');
        const segTop = (start / scrollMax) * 100;
        const segHeight = (height / scrollMax) * 100;
        segment.style = `position:absolute; top:${segTop}%; left:0; width:100%; height:${segHeight}%; background:rgba(${color}, 0.2); border-bottom:1px solid rgba(0,0,0,0.1); box-sizing:border-box;`;
        
        const stopDot = document.createElement('div');
        const stopRatio = (focusState.stops[i] / scrollMax) * 100;
        stopDot.style = `position:absolute; top:${(stopRatio - segTop) / segHeight * 100}%; left:0; width:100%; height:2px; background:magenta;`;
        segment.appendChild(stopDot);
        
        sidebar.appendChild(segment);

        // C. Draw the Stop line in-situ
        const stopY = focusState.stops[i];
        const stopLine = document.createElement('div');
        stopLine.style = `position:absolute; top:${stopY}px; left:0; width:100%; height:1px; border-top:1px dashed rgba(255,0,255,0.4);`;
        container.appendChild(stopLine);

        container.appendChild(box);
    });

    // Info Panel
    const info = document.createElement('div');
    info.style = "position:fixed; bottom:20px; right:70px; padding:10px; background:white; border:1px solid #ccc; font-size:11px; z-index:10003; box-shadow:0 2px 10px rgba(0,0,0,0.1); border-radius:4px;";
    info.innerHTML = `
        <b>Debug Map</b><br>
        Active: T${focusState.currentStationIndex}<br>
        ScrollY: ${Math.round(scrollY)}<br>
        <span style="color:magenta">---</span> Ideal Stop<br>
        <span style="background:rgba(0,255,0,0.2)">T(even)</span> <span style="background:rgba(0,0,255,0.2)">T(odd)</span>
    `;
    container.appendChild(info);
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
/**
 * ReaderBridge.js - Absolute Optimization Edition
 * 
 * CORE ARCHITECTURE:
 * - "Stop-Centered" logic: Precision focus targets at 40% height.
 * - Semantic Diffing: Minimizes bridge overhead by only reporting meaningful changes.
 * - Layout-Aware: Uses ResizeObserver for automatic map stability.
 * - Performance: O(log N) focus search and O(1) block detection.
 */

// --- Configuration ---
const MIN_TERRITORY_HEIGHT = 100;
const HYSTERESIS_THRESHOLD = 20;
const EYE_LINE_RATIO = 0.4;
const VISIBILITY_BUFFER = 5;
const BLOCK_OFFSET_BUCKETS = 10;
const HEARTBEAT_MS = 5000;

// --- Global State ---
const focusState = { 
    lastScrollY: 0,
    lastVelocity: 0,
    lastReportedScrollY: 0,
    lastReportedTime: 0,
    lastBlockCheckY: 0,
    currentStationIndex: -1,
    currentBlockIndex: -1,
    currentBlockOffset: 0,
    stations: [],
    boundaries: [],
    stops: [],
    scrollHeight: 0,
    viewportHeight: 0,
    eyeLineY: 0,
    reachedBottom: false,
    mapBuilt: false,
    mapPending: false,
    idleTimeout: null,
    // Semantic Diff Cache to prevent SwiftUI over-rendering
    lastSent: {
        annotationId: null,
        imageId: null,
        footnoteRefId: null,
        blockId: null,
        blockOffsetBucket: null,
        scrollPercent: -1,
        isLocked: false
    }
};

let scrollTicking = false;

/**
 * Fast binary search for sorted arrays
 */
function binarySearch(arr, val) {
    let low = 0, high = arr.length - 1;
    while (low <= high) {
        const mid = (low + high) >>> 1;
        if (arr[mid] < val) low = mid + 1;
        else high = mid - 1;
    }
    return low;
}

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

    const driftTolerance = 4.0;
    const staleWriteMs = 150;

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
        if (wasLocked && !silent) updateFocus(true);
    };

    const complete = () => {
        if (state.raf) cancelAnimationFrame(state.raf);
        state.raf = null;
        state.active = false;
        state.expectedY = state.targetY; 
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        updateFocus(true);
    };

    const start = (targetId, targetY) => {
        cancel(true); 
        const currentSession = state.sessionId;
        const startY = window.scrollY;
        const vh = focusState.viewportHeight || window.innerHeight;
        const scrollMax = Math.max(1, (focusState.scrollHeight || document.documentElement.scrollHeight) - vh);
        const safeTargetY = Math.max(0, Math.min(scrollMax, targetY));
        const distance = Math.abs(safeTargetY - startY);
        
        state.active = true;
        state.sticky = true;
        state.targetId = targetId;
        state.targetY = safeTargetY;
        state.expectedY = startY; 
        state.lastSetAt = performance.now();

        // Update focus immediately to lock onto the target
        updateFocus();

        if (distance < 2) {
            // SNAP: Update expectation BEFORE the synchronous call to prevent drift trigger
            state.expectedY = safeTargetY;
            window.scrollTo({ top: safeTargetY, behavior: 'auto' });
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
            
            const elapsed = now - startTime;
            const progress = Math.min(1, elapsed / duration);
            const eased = easeOutCubic(progress);
            const nextY = startY + (safeTargetY - startY) * eased;
            
            // IMPORTANT: Update expectedY BEFORE scrolling so noteScroll (which fires on scroll event)
            // sees the value we intended to reach.
            state.expectedY = nextY;
            state.lastSetAt = performance.now();
            
            window.scrollTo({ top: nextY, behavior: 'auto' });
            
            if (progress < 1) state.raf = requestAnimationFrame(step);
            else { state.raf = null; complete(); }
        };
        
        state.raf = requestAnimationFrame(step);
    };

    return {
        start,
        noteScroll: (actualY) => {
            if (!state.sticky) return;
            const drift = state.expectedY === null ? 0 : Math.abs(actualY - state.expectedY);
            const timeSinceLastWrite = performance.now() - state.lastSetAt;
            if (drift > driftTolerance || (state.active && timeSinceLastWrite > staleWriteMs)) cancel();
        },
        isActive: () => state.active,
        isSticky: () => state.sticky,
        preferredTargetId: () => state.sticky ? state.targetId : null
    };
})();

// --- DOM Queries ---

function getBlockByIdOrIndex(blockId) {
    if (!blockId || blockId <= 0) return null;
    const byId = document.getElementById(`block-${blockId}`);
    if (byId) return byId;
    const idBlocks = document.querySelectorAll('[id^="block-"]');
    if (idBlocks.length >= blockId) return idBlocks[blockId - 1];
    const generic = document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li');
    return generic[blockId - 1] || null;
}

function getMarkers() {
    const selector = '.annotation-marker, .image-marker, .footnote-ref';
    const markerElements = document.querySelectorAll(selector);
    const scrollY = window.scrollY;
    
    return Array.from(markerElements).map((element, index) => {
        const rect = element.getBoundingClientRect();
        let type = 'annotation';
        if (element.classList.contains('image-marker')) type = 'image';
        else if (element.classList.contains('footnote-ref')) type = 'footnote';

        const id = element.dataset.annotationId || element.dataset.imageId || 
                   (element.getAttribute('href')?.split('#')[1]) || element.id;

        const block = element.closest('[id^="block-"]');
        const blockId = block ? parseInt(block.id.replace("block-", ""), 10) : 
                                parseInt(element.dataset.blockId || "0", 10);

        return { element, id, type, order: index, blockId, y: rect.top + scrollY + (rect.height * 0.5) };
    }).sort((a, b) => (a.y !== b.y) ? a.y - b.y : a.order - b.order);
}

// --- Territory Logic ---

function buildTerritoryMap() {
    const stations = getMarkers();
    const vh = window.innerHeight;
    const sh = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, sh - vh);
    
    focusState.viewportHeight = vh;
    focusState.scrollHeight = sh;
    focusState.eyeLineY = vh * EYE_LINE_RATIO;

    if (stations.length === 0) {
        focusState.stations = []; focusState.boundaries = []; focusState.stops = [];
        focusState.mapBuilt = true; focusState.mapPending = false; return;
    }

    const minH = Math.min(MIN_TERRITORY_HEIGHT, scrollMax / stations.length);
    let stops = stations.map(s => Math.max(0, Math.min(scrollMax, s.y - focusState.eyeLineY)));

    for (let i = 1; i < stations.length; i++) {
        if (stops[i] < stops[i - 1] + minH) stops[i] = stops[i - 1] + minH;
    }
    if (stops[stations.length - 1] > scrollMax) {
        stops[stations.length - 1] = scrollMax;
        for (let i = stations.length - 2; i >= 0; i--) {
            if (stops[i] > stops[i + 1] - minH) stops[i] = stops[i + 1] - minH;
        }
    }

    let boundaries = [];
    for (let i = 0; i < stations.length - 1; i++) boundaries.push((stops[i] + stops[i + 1]) / 2);
    boundaries.push(scrollMax + 1000);

    focusState.stations = stations;
    focusState.stops = stops;
    focusState.boundaries = boundaries;
    focusState.mapBuilt = true;
    focusState.mapPending = false;
}

function scheduleMapRebuild() {
    if (focusState.mapPending) return;
    focusState.mapPending = true;
    (window.requestIdleCallback || ((cb) => setTimeout(cb, 50)))(() => {
        buildTerritoryMap();
        updateFocus(true);
    });
}

/**
 * Synchronizes Focus with Scroll Position
 */
function updateFocus(forceReport = false) {
    const scrollY = window.scrollY;
    const now = performance.now();
    
    // Ensure map is built if we have no stations, even if a lazy rebuild is pending
    if (!focusState.mapBuilt || (focusState.stations.length === 0 && !focusState.mapPending)) {
        buildTerritoryMap();
    }

    const vh = focusState.viewportHeight || window.innerHeight;
    const sh = focusState.scrollHeight || document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, sh - vh);
    const scrollPercent = scrollY / scrollMax;

    const isLocked = programmatic.isSticky();
    const isAnimating = programmatic.isActive();
    const targetId = programmatic.preferredTargetId();
    
    let newStationIndex = -1;
    let activeBlockIndex = -1;

    // 1. Focus Determination (Binary Search)
    if (isLocked && targetId) {
        // Robust matching for various ID formats (string/number/prefixed)
        newStationIndex = focusState.stations.findIndex(s => {
            const fullId = s.type + "-" + s.id;
            return fullId === targetId || String(s.id) === String(targetId) || s.id == targetId;
        });
    } else if (!isAnimating && focusState.stations.length > 0) {
        let idx = focusState.currentStationIndex;
        const b = focusState.boundaries;
        const lowB = idx <= 0 ? 0 : b[idx - 1];
        const upB = idx === -1 ? -1 : b[idx];
        
        if (idx === -1 || scrollY > upB + HYSTERESIS_THRESHOLD || scrollY < lowB - HYSTERESIS_THRESHOLD) {
            idx = binarySearch(b, scrollY);
            if (idx >= focusState.stations.length) idx = focusState.stations.length - 1;
        }

        const owner = focusState.stations[idx];
        if (owner && owner.y >= scrollY - VISIBILITY_BUFFER && owner.y <= scrollY + vh + VISIBILITY_BUFFER) {
            newStationIndex = idx;
        } else if (owner) {
            // Zero-allocation visibility check
            if (owner.y < scrollY) {
                for (let i = idx + 1; i < focusState.stations.length; i++) {
                    const m = focusState.stations[i];
                    if (m.y >= scrollY - VISIBILITY_BUFFER && m.y <= scrollY + vh + VISIBILITY_BUFFER) { newStationIndex = i; break; }
                    if (m.y > scrollY + vh + VISIBILITY_BUFFER) break;
                }
            } else {
                for (let i = idx - 1; i >= 0; i--) {
                    const m = focusState.stations[i];
                    if (m.y >= scrollY - VISIBILITY_BUFFER && m.y <= scrollY + vh + VISIBILITY_BUFFER) { newStationIndex = i; break; }
                    if (m.y < scrollY - VISIBILITY_BUFFER) break;
                }
            }
        }
    }

    // 2. Block Tracking (Spatial Throttling)
    if (!isAnimating) {
        if (Math.abs(scrollY - focusState.lastBlockCheckY) > 20 || focusState.currentBlockIndex === -1) {
            const eyeLine = focusState.eyeLineY || (vh * EYE_LINE_RATIO);
            const el = document.elementFromPoint(window.innerWidth / 2, eyeLine);
            const block = el?.closest('[id^="block-"]');
            if (block) {
                activeBlockIndex = parseInt(block.id.replace("block-", ""), 10) - 1;
                const rect = block.getBoundingClientRect();
                if (rect.height > 0) {
                    const rawOffset = (eyeLine - rect.top) / rect.height;
                    focusState.currentBlockOffset = Math.max(0, Math.min(1, rawOffset));
                }
            } else {
                activeBlockIndex = focusState.currentBlockIndex;
            }
            focusState.lastBlockCheckY = scrollY;
        } else activeBlockIndex = focusState.currentBlockIndex;
    }

    const hasChangedFocus = newStationIndex !== focusState.currentStationIndex;
    const hasChangedBlock = activeBlockIndex !== -1 && activeBlockIndex !== focusState.currentBlockIndex;
    
    focusState.currentStationIndex = newStationIndex;
    if (activeBlockIndex !== -1) focusState.currentBlockIndex = activeBlockIndex;

    const timeSinceLast = now - focusState.lastReportedTime;
    const movedFar = Math.abs(scrollY - focusState.lastReportedScrollY) > 300;
    
    const shouldHeartbeat = !isLocked && (now - focusState.lastReportedTime) > HEARTBEAT_MS;
    const shouldReport = forceReport || hasChangedFocus || hasChangedBlock || movedFar || shouldHeartbeat || isLocked;
    const shouldForce = forceReport || hasChangedBlock || movedFar || shouldHeartbeat || isLocked;

    if (shouldReport) {
        reportToNative(scrollY, scrollPercent, vh, isLocked, hasChangedFocus, shouldForce);
    }

    // 4. Debounced Heartbeat
    if (forceReport || hasChangedFocus || hasChangedBlock || timeSinceLast > 1000) {
        clearTimeout(focusState.idleTimeout);
        focusState.idleTimeout = setTimeout(() => {
            const curY = window.scrollY;
            const curMax = Math.max(1, (focusState.scrollHeight || document.documentElement.scrollHeight) - (focusState.viewportHeight || window.innerHeight));
            if (Math.abs(curY - focusState.lastReportedScrollY) > 5) {
                reportToNative(curY, curY / curMax, focusState.viewportHeight || window.innerHeight, programmatic.isSticky(), false, false);
            }
        }, 1000);
    }
}

/**
 * Optimized bridge communicator with Semantic Diffing
 */
function reportToNative(scrollY, scrollPercent, vh, isLocked, shouldPulse, forceReport) {
    const s = focusState.stations[focusState.currentStationIndex];
    const aId = s?.type === 'annotation' ? s.id : null;
    const iId = s?.type === 'image' ? s.id : null;
    const fId = s?.type === 'footnote' ? s.id : null;
    const bId = focusState.currentBlockIndex !== -1 ? focusState.currentBlockIndex + 1 : null;
    const bOffset = typeof focusState.currentBlockOffset === 'number' ? focusState.currentBlockOffset : null;
    const offsetBucket = bOffset === null ? null : Math.floor(bOffset * BLOCK_OFFSET_BUCKETS);
    const roundedP = Math.round(scrollPercent * 1000) / 1000;

    // SEMANTIC DIFF: Don't hit the bridge if nothing native cares about has changed.
    const isLockedChanged = isLocked !== focusState.lastSent.isLocked;
    if (!forceReport && !shouldPulse && !isLockedChanged && !isLocked && 
        aId === focusState.lastSent.annotationId && 
        iId === focusState.lastSent.imageId && 
        fId === focusState.lastSent.footnoteRefId && 
        bId === focusState.lastSent.blockId && 
        offsetBucket === focusState.lastSent.blockOffsetBucket &&
        Math.abs(roundedP - focusState.lastSent.scrollPercent) < 0.005
    ) return;

    // VERIFIER FIX: Update reporting state ONLY when message actually clears the filter.
    // This fixes the "Movement Dead Zone" for slow scrolls.
    focusState.lastReportedScrollY = scrollY;
    focusState.lastReportedTime = performance.now();
    focusState.lastSent = { 
        annotationId: aId, imageId: iId, footnoteRefId: fId, 
        blockId: bId, blockOffsetBucket: offsetBucket, scrollPercent: roundedP, isLocked: isLocked 
    };

    if (shouldPulse && !isLocked && s?.element && focusState.lastVelocity < 40) {
        if (s.y >= scrollY - VISIBILITY_BUFFER && s.y <= scrollY + vh + VISIBILITY_BUFFER) pulseMarker(s.element);
    }

    webkit.messageHandlers.readerBridge.postMessage({
        type: 'scrollPosition', annotationId: aId, imageId: iId, footnoteRefId: fId,
        blockId: bId, blockOffset: bOffset, primaryType: s?.type || null, scrollY, scrollPercent: roundedP,
        viewportHeight: vh, isProgrammatic: isLocked
    });
}

function pulseMarker(el) {
    if (!el) return;
    el.style.setProperty('--highlight-color', 'var(' + (el.classList.contains('image-marker') ? '--iris' : '--rose') + ')');
    el.classList.remove('marker-pulse');
    requestAnimationFrame(() => {
        el.classList.add('marker-pulse');
        setTimeout(() => el.classList.remove('marker-pulse'), 650);
    });
}

function highlightMarker(el) {
    if (!el) return;
    el.classList.add('marker-highlight');
    el.style.setProperty('--highlight-color', 'var(' + (el.classList.contains('image-marker') ? '--iris' : '--rose') + ')');
    setTimeout(() => el.classList.remove('marker-highlight'), 1500);
}

function highlightBlock(el) {
    if (!el) return;
    el.classList.add('highlight-active');
    el.style.backgroundColor = 'var(--rose)'; el.style.color = 'var(--base)'; el.style.transition = 'none';
    setTimeout(() => {
        el.style.transition = 'background-color 1.5s ease-out, color 1.5s ease-out';
        el.style.backgroundColor = ''; el.style.color = '';
        setTimeout(() => el.classList.remove('highlight-active'), 1500);
    }, 400);
}

function performSmoothScroll(el, ratio, targetId) {
    const vh = window.innerHeight;
    const sh = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, sh - vh);
    let ty = null;
    if (focusState.stations.length > 0) {
        const idx = focusState.stations.findIndex(s => (s.type + "-" + s.id) === targetId || s.id === targetId);
        if (idx !== -1 && focusState.stops[idx] !== undefined) ty = focusState.stops[idx];
    }
    if (ty === null) ty = window.scrollY + el.getBoundingClientRect().top - (vh * ratio);
    programmatic.start(targetId, Math.max(0, Math.min(scrollMax, ty)));
}

function scrollToAnnotation(id) {
    const el = document.querySelector(`[data-annotation-id="${id}"]`);
    if (el) { performSmoothScroll(el, EYE_LINE_RATIO, 'annotation-' + id); highlightMarker(el); }
}

function scrollToBlock(id, mId, type) {
    const b = getBlockByIdOrIndex(id);
    if (!b) return;
    const tId = mId && type ? `${type}-${mId}` : `block-${id}`;
    performSmoothScroll(b, EYE_LINE_RATIO, tId);
    if (mId && type) {
        const m = document.querySelector(`[data-${type}-id="${mId}"]`);
        if (m) highlightMarker(m);
    } else highlightBlock(b);
}

function scrollToQuote(qId) {
    const el = document.querySelector(`[href="#${qId}"], [id="${qId}"]`);
    if (el) {
        performSmoothScroll(el, EYE_LINE_RATIO, 'footnote-' + qId);
        if (el.classList.contains('footnote-ref')) highlightMarker(el);
        else highlightBlock(el);
    }
}

function scrollToPercent(p) { 
    window.scrollTo({ top: (document.documentElement.scrollHeight - window.innerHeight) * p, behavior: 'auto' }); 
}

function scrollToOffset(o) { window.scrollTo({ top: o, behavior: 'auto' }); }

// --- Event Listeners ---

window.addEventListener('scroll', () => {
    const sy = window.scrollY;
    focusState.lastVelocity = Math.abs(sy - focusState.lastScrollY);
    focusState.lastScrollY = sy;
    programmatic.noteScroll(sy);
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            updateFocus();
            const max = document.documentElement.scrollHeight - window.innerHeight;
            if (max > 0 && sy >= max - 1) focusState.reachedBottom = true;
            else if (sy < max - 20) focusState.reachedBottom = false;
            if (focusState.reachedBottom && sy > max + 5) {
                webkit.messageHandlers.readerBridge.postMessage({ type: 'bottomTug' });
                focusState.reachedBottom = false; 
            }
            scrollTicking = false;
        });
    }
});

const selectionOverlay = document.getElementById('selectionOverlay');
let selectionTicking = false;
function updateSelectionOverlay() {
    if (!selectionOverlay || selectionTicking) return;
    selectionTicking = true;
    window.requestAnimationFrame(() => {
        const sel = window.getSelection();
        if (!sel || sel.isCollapsed) { selectionOverlay.innerHTML = ''; selectionTicking = false; return; }
        const rects = sel.getRangeAt(0).getClientRects();
        selectionOverlay.innerHTML = '';
        for (const r of rects) {
            const d = document.createElement('div');
            d.className = 'selection-rect';
            d.style.left = (r.left + window.scrollX) + 'px';
            d.style.top = (r.top + window.scrollY) + 'px';
            d.style.width = r.width + 'px'; d.style.height = r.height + 'px';
            selectionOverlay.appendChild(d);
        }
        selectionTicking = false;
    });
}

document.addEventListener('selectionchange', updateSelectionOverlay);

// High-precision Layout Monitoring
const layoutObserver = new ResizeObserver(() => scheduleMapRebuild());
layoutObserver.observe(document.body);

document.addEventListener('click', e => {
    const t = e.target;
    if (t.classList.contains('annotation-marker')) webkit.messageHandlers.readerBridge.postMessage({ type: 'annotationClick', id: t.dataset.annotationId });
    if (t.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({ type: 'imageMarkerClick', id: t.dataset.imageId });
});

document.addEventListener('dblclick', e => {
    if (e.target.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({ type: 'imageMarkerDblClick', id: e.target.dataset.imageId });
});

document.addEventListener('mouseup', e => {
    setTimeout(() => {
        const sel = window.getSelection();
        const text = sel.toString().trim();
        const popup = document.getElementById('wordPopup');
        if (!sel.isCollapsed && text) {
            const container = sel.getRangeAt(0).startContainer.parentElement;
            // OPTIMIZED O(1) Lookup
            const block = container.closest('[id^="block-"]');
            const bId = block ? parseInt(block.id.replace("block-", ""), 10) : 1;
            popup.style.left = e.clientX + 'px'; popup.style.top = (e.clientY + 10) + 'px'; popup.style.display = 'block';
            window.selectedWord = text; window.selectedBlockId = bId; window.selectedContext = container.textContent;
        } else if (!e.target.closest('.word-popup')) popup.style.display = 'none';
    }, 20);
});

document.addEventListener('mousedown', e => { if (!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display = 'none'; });

function handleExplain() { 
    webkit.messageHandlers.readerBridge.postMessage({ type: 'explain', word: window.selectedWord, context: window.selectedContext, blockId: window.selectedBlockId }); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

function handleGenerateImage() { 
    webkit.messageHandlers.readerBridge.postMessage({ type: 'generateImage', word: window.selectedWord, context: window.selectedContext, blockId: window.selectedBlockId }); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

function injectMarkerAtBlock(aId, bIdx) { 
    const b = getBlockByIdOrIndex(bIdx);
    if (b) {
        const m = document.createElement('span'); m.className = 'annotation-marker'; 
        m.dataset.annotationId = aId; m.dataset.blockId = bIdx; b.appendChild(m);
        scheduleMapRebuild();
    } 
}

function injectImageMarker(iId, bIdx) { 
    const b = getBlockByIdOrIndex(bIdx);
    if (b) {
        const m = document.createElement('span'); m.className = 'image-marker'; 
        m.dataset.imageId = iId; m.dataset.blockId = bIdx; b.appendChild(m);
        scheduleMapRebuild();
    } 
}

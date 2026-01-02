/**
 * ReaderBridge.js
 * 
 * Core synchronization bridge between the book content (WebView) and the native app.
 * Optimized for high-precision scroll tracking and "Sticky Intent" selection.
 */

// --- Global State ---

const focusState = { 
    reachedBottom: false,
    lastScrollY: 0,
    lastVelocity: 0,
    activeIds: { annotation: null, image: null, footnote: null },
    primaryKey: null
};

let scrollTicking = false;

/**
 * Programmatic Scroll & Lock Controller
 * Implements "Sticky Intent": Locks focus to a target until the user manually scrolls.
 */
const programmatic = (() => {
    const state = {
        active: false,    // Scroll animation is currently running
        sticky: false,    // Selection is locked to a target
        targetId: null,   // The ID of the locked item
        targetY: null,    // The scroll destination
        expectedY: null,  // Expected Y position for drift detection
        lastSetAt: 0,
        raf: null,
        timeout: null,
        sessionId: 0      // Unique ID to track the current scroll session
    };

    const driftTolerance = 1.5; 
    const staleWriteMs = 60;

    /**
     * Fully releases all locks and cancels pending animations.
     */
    const cancel = (silent = false) => {
        const wasLocked = state.sticky;
        
        if (state.raf) cancelAnimationFrame(state.raf);
        state.raf = null;
        
        state.active = false;
        state.sticky = false; 
        state.targetId = null;
        state.targetY = null;
        state.expectedY = null;
        state.sessionId++; // Invalidate stale animation frame callbacks
        
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        
        // Notify Swift that the lock is released
        if (wasLocked && !silent) {
            updateFocus();
        }
    };

    /**
     * Called when the scroll animation successfully reaches its destination.
     */
    const complete = () => {
        if (state.raf) cancelAnimationFrame(state.raf);
        state.raf = null;
        
        state.active = false;
        state.expectedY = state.targetY; // Preserve for drift detection while stationary
        
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        
        updateFocus();
    };

    /**
     * Starts a smooth programmatic scroll to a target ID.
     */
    const start = (targetId, targetY) => {
        cancel(true); // Clear any existing sessions silently
        
        const currentSession = state.sessionId;
        const startY = window.scrollY;
        const distance = Math.abs(targetY - startY);
        
        state.active = true;
        state.sticky = true;
        state.targetId = targetId;
        state.targetY = targetY;
        state.expectedY = startY;
        state.lastSetAt = performance.now();

        // Lock Swift UI to the target immediately on frame zero
        updateFocus();

        // If very close, just jump and complete
        if (distance < 2) {
            window.scrollTo({ top: targetY, behavior: 'auto' });
            complete();
            return;
        }

        const duration = Math.min(900, Math.max(280, distance * 0.65));
        
        // Watchdog: Ensure state is never stuck if RAF fails
        state.timeout = setTimeout(() => {
            if (state.active && state.sessionId === currentSession) {
                complete();
            }
        }, duration + 500);

        const startTime = performance.now();
        const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);

        const step = (now) => {
            if (!state.active || state.sessionId !== currentSession) return;

            const progress = Math.min(1, (now - startTime) / duration);
            const easedProgress = easeOutCubic(progress);
            const nextY = startY + (targetY - startY) * easedProgress;
            
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

    /**
     * Checks if the user has manually interrupted the scroll or lock.
     */
    const noteScroll = (actualY) => {
        if (!state.sticky) return;
        
        const drift = state.expectedY === null ? 0 : Math.abs(actualY - state.expectedY);
        const timeSinceLastUpdate = performance.now() - state.lastSetAt;

        // User interaction detected if actual Y deviates from expected Y
        if (drift > driftTolerance || (state.active && timeSinceLastUpdate > staleWriteMs)) {
            cancel();
        }
    };

    return {
        start,
        noteScroll,
        isActive: () => state.active,
        isSticky: () => state.sticky,
        preferredTargetId: () => state.sticky ? state.targetId : null
    };
})();

// --- Layout & DOM Helpers ---

function getBlocks() {
    return Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li'));
}

function getMarkers() {
    return Array.from(document.querySelectorAll('.annotation-marker, .image-marker, .footnote-ref'));
}

function isVisibleWithMargin(rect, viewportHeight, extraTop, extraBottom) {
    return rect.bottom >= -extraTop && rect.top <= viewportHeight + extraBottom;
}

function selectionThreshold(scrollPercent, viewportHeight) {
    const base = Math.max(160, viewportHeight * 0.6);
    const edgeBoost = (scrollPercent < 0.05 || scrollPercent > 0.95) ? viewportHeight * 0.25 : 0;
    return base + edgeBoost;
}

function parseTargetId(targetId) {
    if (!targetId) return null;
    const dashIndex = targetId.indexOf("-");
    if (dashIndex <= 0) return null;
    return {
        type: targetId.slice(0, dashIndex),
        id: targetId.slice(dashIndex + 1)
    };
}

/**
 * Ensures markers are vertically spaced to prevent proximity jitter.
 */
function computeVirtualPositions(items, minSpacing, minBound, maxBound) {
    const ordered = items.slice().sort((a, b) => (a.y - b.y) || (a.order - b.order));
    
    if (ordered.length <= 1) {
        if (ordered[0]) {
            ordered[0].virtualY = Math.min(maxBound, Math.max(minBound, ordered[0].y));
        }
        return ordered;
    }

    const minY = ordered[0].y;
    const maxY = ordered[ordered.length - 1].y;
    const span = Math.max(1, maxY - minY);
    const requiredSpan = minSpacing * (ordered.length - 1);
    const extra = Math.max(0, requiredSpan - span);
    
    let targetMin = minY - extra * 0.5;
    let targetMax = maxY + extra * 0.5;

    if (targetMin < minBound) {
        const shift = minBound - targetMin;
        targetMin += shift;
        targetMax += shift;
    }
    if (targetMax > maxBound) {
        const shift = targetMax - maxBound;
        targetMin -= shift;
        targetMax -= shift;
    }

    const positions = ordered.map(item => item.y);
    positions[0] = Math.max(positions[0], targetMin);
    
    for (let i = 1; i < positions.length; i++) {
        positions[i] = Math.max(positions[i], positions[i - 1] + minSpacing);
    }
    
    if (positions[positions.length - 1] > targetMax) {
        positions[positions.length - 1] = targetMax;
    }
    
    for (let i = positions.length - 2; i >= 0; i--) {
        positions[i] = Math.min(positions[i], positions[i + 1] - minSpacing);
    }
    
    for (let i = 0; i < ordered.length; i++) {
        ordered[i].virtualY = Math.min(maxBound, Math.max(minBound, positions[i]));
    }
    return ordered;
}

/**
 * Selects the marker closest to the focus line, with sticky focus to prevent jitter.
 */
function selectMarker(items, focusLine, minSpacing, maxDistance, lastKey, keyForItem, edgeHoldBoost) {
    if (items.length === 0) return null;

    const ordered = items.slice().sort((a, b) => {
        const aY = a.virtualY ?? a.y;
        const bY = b.virtualY ?? b.y;
        return (aY - bY) || (a.order - b.order);
    });

    let bestItem = ordered[0];
    bestItem.distance = Math.abs((bestItem.virtualY ?? bestItem.y) - focusLine);

    for (const item of ordered) {
        const distance = Math.abs((item.virtualY ?? item.y) - focusLine);
        item.distance = distance;
        if (distance < bestItem.distance - 0.5) {
            bestItem = item;
        }
    }

    if (bestItem.distance > maxDistance) return null;

    // Sticky Proximity Selection logic
    if (lastKey) {
        const lastItem = ordered.find(item => keyForItem(item) === lastKey);
        if (lastItem) {
            const lastIdx = ordered.indexOf(lastItem);
            const prevItem = lastIdx > 0 ? ordered[lastIdx - 1] : null;
            const nextItem = lastIdx < ordered.length - 1 ? ordered[lastIdx + 1] : null;
            
            const lastY = lastItem.virtualY ?? lastItem.y;
            const lowerBound = prevItem ? ((prevItem.virtualY ?? prevItem.y) + lastY) * 0.5 : -Infinity;
            const upperBound = nextItem ? ((nextItem.virtualY ?? nextItem.y) + lastY) * 0.5 : Infinity;
            
            const stickinessMargin = Math.max(26, minSpacing * 0.32) * edgeHoldBoost;
            if (focusLine >= lowerBound - stickinessMargin && focusLine <= upperBound + stickinessMargin) {
                return lastItem;
            }
        }
    }

    return bestItem;
}

// --- UI Logic ---

function pulseMarker(el) {
    if (!el) return;
    const isImage = el.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    el.style.setProperty('--highlight-color', 'var(' + colorVar + ')');
    el.classList.remove('marker-pulse');
    void el.offsetWidth; // Trigger layout
    el.classList.add('marker-pulse');
    setTimeout(() => el.classList.remove('marker-pulse'), 650);
}

function highlightMarker(el) {
    if (!el) return;
    const isImage = el.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    el.classList.add('marker-highlight');
    el.style.setProperty('--highlight-color', 'var(' + colorVar + ')');
    setTimeout(() => el.classList.remove('marker-highlight'), 1500);
}

/**
 * Main Update Loop: Calculates focus based on scroll position.
 */
function updateFocus() {
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const scrollMax = document.documentElement.scrollHeight - viewportHeight;
    const scrollPercent = scrollMax > 0 ? (scrollY / scrollMax) : 0;
    const minSpacing = Math.max(140, viewportHeight * 0.22);
    
    // 1. Adaptive Eye Line Calculation
    let eyeRatio = 0.45;
    const edgeThreshold = viewportHeight * 0.6;
    if (scrollY < edgeThreshold) {
        eyeRatio -= (1 - (scrollY / edgeThreshold)) * 0.12;
    } else if (scrollY > scrollMax - edgeThreshold) {
        eyeRatio += ((scrollY - (scrollMax - edgeThreshold)) / edgeThreshold) * 0.18;
    }
    
    let focusLine = scrollY + (eyeRatio * viewportHeight);

    // 2. Edge Zone Behavior
    const edgeZone = 0.08;
    const topFactor = scrollPercent < edgeZone ? 1 - (scrollPercent / edgeZone) : 0;
    const bottomFactor = scrollPercent > 1 - edgeZone ? 1 - ((1 - scrollPercent) / edgeZone) : 0;
    
    if (topFactor > 0) {
        const topBand = (viewportHeight * 0.12) * (1 + topFactor * 0.4);
        focusLine = Math.min(focusLine, scrollY + topBand);
    }
    if (bottomFactor > 0) {
        const bottomBand = (viewportHeight * 0.12) * (1 - bottomFactor * 0.4);
        focusLine = Math.max(focusLine, scrollY + viewportHeight - bottomBand);
    }

    const markers = getMarkers();
    const isLocked = programmatic.isSticky();

    // Fallback path: No markers in chapter
    if (markers.length === 0) {
        const blocks = getBlocks();
        let activeBlockIndex = -1;
        let minBlockDist = Infinity;
        blocks.forEach((block, index) => {
            const rect = block.getBoundingClientRect();
            const top = rect.top + scrollY, bottom = rect.bottom + scrollY;
            const dist = (focusLine >= top && focusLine <= bottom) ? 0 : Math.min(Math.abs(top - focusLine), Math.abs(bottom - focusLine));
            if (dist < minBlockDist) { minBlockDist = dist; activeBlockIndex = index; }
        });
        sendScrollMessage(null, null, null, activeBlockIndex + 1, null, null, null, null, null, null, null, scrollY, scrollPercent, viewportHeight, isLocked);
        return;
    }

    // 3. Normal Path: Map marker data and calculate selection
    const extraTop = topFactor * Math.max(24, minSpacing * 0.35);
    const extraBottom = bottomFactor * Math.max(80, minSpacing * 1.15);

    const markerData = markers.map((m, index) => {
        const rect = m.getBoundingClientRect();
        const type = m.classList.contains('annotation-marker') ? 'annotation' : (m.classList.contains('image-marker') ? 'image' : 'footnote');
        const id = m.dataset.annotationId || m.dataset.imageId || (type === 'footnote' ? (m.getAttribute('href')?.split('#')[1] || m.id) : null);
        return { 
            el: m, id, type, order: index, 
            y: rect.top + scrollY + (rect.height * 0.5), 
            isVisible: isVisibleWithMargin(rect, viewportHeight, extraTop, extraBottom),
            blockId: parseInt(m.dataset.blockId || "0", 10) 
        };
    });

    const target = parseTargetId(programmatic.preferredTargetId());
    let bestA = null, bestI = null, bestF = null, primaryType = null;

    if (isLocked && target) {
        // --- STICKY LOCK MODE ---
        const match = markerData.find(m => m.type === target.type && m.id === target.id);
        if (target.type === 'annotation') bestA = match || { id: target.id, distance: 0 };
        if (target.type === 'image') bestI = match || { id: target.id, distance: 0 };
        if (target.type === 'footnote') bestF = match || { id: target.id, distance: 0 };
        primaryType = target.type;
    } else {
        // --- PROXIMITY SELECTION MODE ---
        const byType = { annotation: [], image: [], footnote: [] };
        markerData.forEach(m => { if (m.id) byType[m.type].push(m); });

        const maxD = selectionThreshold(scrollPercent, viewportHeight);
        const visibleAll = markerData.filter(item => item.id && item.isVisible);
        
        if (visibleAll.length > 0) {
            computeVirtualPositions(visibleAll, minSpacing, 0, scrollMax + viewportHeight);
        }
        
        const edgeHoldBoost = 1 + Math.max(topFactor, bottomFactor) * 0.8;
        const select = (type, items) => {
            const visible = items.filter(m => m.isVisible);
            if (visible.length === 0) return null;
            return selectMarker(visible, focusLine, minSpacing, maxD, focusState.activeIds[type], m => m.id, edgeHoldBoost);
        };
        
        bestA = select('annotation', byType.annotation);
        bestI = select('image', byType.image);
        bestF = select('footnote', byType.footnote);
        
        const primary = selectMarker(visibleAll, focusLine, minSpacing, maxD, focusState.primaryKey, m => `${m.type}:${m.id}`, edgeHoldBoost);
        primaryType = primary?.type || null;

        // Visual Pulse feedback on manual selection change
        if (focusState.lastVelocity < 40) {
            const prev = focusState.activeIds;
            if (bestA && bestA.id !== prev.annotation) pulseMarker(bestA.el);
            if (bestI && bestI.id !== prev.image) pulseMarker(bestI.el);
            if (bestF && bestF.id !== prev.footnote) pulseMarker(bestF.el);
        }
    }

    // Commit selection to state
    focusState.activeIds = { annotation: bestA?.id || null, image: bestI?.id || null, footnote: bestF?.id || null };
    focusState.primaryKey = primaryType ? `${primaryType}:${(bestA||bestI||bestF)?.id}` : null;

    // Send final state to Swift
    sendScrollMessage(
        bestA?.id || null, bestI?.id || null, bestF?.id || null, -1, 
        bestA?.distance || null, bestI?.distance || null, bestF?.distance || null,
        bestA?.blockId || null, bestI?.blockId || null, bestF?.blockId || null,
        primaryType, scrollY, scrollPercent, viewportHeight, isLocked
    );
}

// --- Communication Out ---

function sendScrollMessage(aId, iId, fId, bId, aD, iD, fD, aB, iB, fB, pT, sY, sP, vH, isP) {
    webkit.messageHandlers.readerBridge.postMessage({ 
        type: 'scrollPosition', 
        annotationId: aId, imageId: iId, footnoteRefId: fId, blockId: bId, 
        annotationDist: aD, imageDist: iD, footnoteDist: fD, 
        annotationBlockId: aB, imageBlockId: iB, footnoteBlockId: fB, 
        primaryType: pT, scrollY: sY, scrollPercent: sP, viewportHeight: vH, 
        isProgrammatic: isP 
    });
}

function performSmoothScroll(element, ratio, targetId) {
    const rect = element.getBoundingClientRect();
    const target = Math.max(0, window.scrollY + rect.top - (window.innerHeight * ratio));
    programmatic.start(targetId, target);
}

// --- External API (Called from Swift) ---

function scrollToAnnotation(id) {
    const el = document.querySelector('[data-annotation-id="' + id + '"]');
    if (el) { performSmoothScroll(el, 0.4, 'annotation-' + id); highlightMarker(el); }
}

function scrollToBlock(id, markerId, type) {
    const blocks = getBlocks();
    if (id > 0 && id <= blocks.length) {
        const block = blocks[id-1];
        const targetKey = markerId && type ? `${type}-${markerId}` : `block-${id}`;
        performSmoothScroll(block, 0.4, targetKey);
        
        if (markerId && type) {
            const marker = document.querySelector('[data-' + type + '-id="' + markerId + '"]');
            if (marker) highlightMarker(marker);
        } else {
            block.classList.add('highlight-active');
            block.style.backgroundColor = 'var(--rose)';
            setTimeout(() => {
                block.style.transition = 'background-color 1.0s ease-out';
                block.style.backgroundColor = '';
                setTimeout(() => { block.classList.remove('highlight-active'); block.style.transition = ''; }, 1000);
            }, 400);
        }
    }
}

function scrollToQuote(quote) {
    const el = document.querySelector('[href="#' + quote + '"], [id="' + quote + '"]');
    if (el) { 
        performSmoothScroll(el, 0.4, 'footnote-' + quote); 
        if (el.classList.contains('footnote-ref')) highlightMarker(el);
    }
}

function scrollToPercent(p) { 
    const scrollMax = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo({top: scrollMax * p, behavior:'auto'}); 
}

function scrollToOffset(o) { 
    window.scrollTo({top: o, behavior:'auto'}); 
}

// --- Dynamic Injection ---

function injectMarkerAtBlock(aId, bId) {
    const blocks = getBlocks();
    if (bId > 0 && bId <= blocks.length) {
        const marker = document.createElement('span');
        marker.className = 'annotation-marker';
        marker.dataset.annotationId = aId;
        marker.dataset.blockId = bId;
        blocks[bId-1].appendChild(marker);
    }
}

function injectImageMarker(iId, bId) {
    const blocks = getBlocks();
    if (bId > 0 && bId <= blocks.length) {
        const marker = document.createElement('span');
        marker.className = 'image-marker';
        marker.dataset.imageId = iId;
        marker.dataset.blockId = bId;
        blocks[bId-1].appendChild(marker);
    }
}

// --- Event Handlers ---

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;
    focusState.lastVelocity = Math.abs(scrollY - focusState.lastScrollY);
    focusState.lastScrollY = scrollY;
    
    // Check for manual drift from programmatic intent
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

document.addEventListener('click', e => {
    const target = e.target;
    if (target.classList.contains('annotation-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({type:'annotationClick', id: target.dataset.annotationId});
    } else if (target.classList.contains('image-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerClick', id: target.dataset.imageId});
    }
});

document.addEventListener('dblclick', e => {
    if (e.target.classList.contains('image-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerDblClick', id: e.target.dataset.imageId});
    }
});

document.addEventListener('mouseup', e => {
    setTimeout(() => {
        const sel = window.getSelection();
        const txt = sel.toString().trim();
        const p = document.getElementById('wordPopup');
        
        if (!sel.isCollapsed && txt) {
            const container = sel.getRangeAt(0).startContainer.parentElement;
            const blocks = getBlocks();
            let blockId = 1;
            for(let i=0; i<blocks.length; i++) { if(blocks[i].contains(container)) { blockId = i+1; break; } }
            
            p.style.left = e.clientX+'px'; p.style.top = (e.clientY+10)+'px'; p.style.display = 'block';
            window.selectedWord = txt; window.selectedBlockId = blockId; window.selectedContext = container.textContent;
        } else if (!e.target.closest('.word-popup')) {
            p.style.display = 'none';
        }
    }, 20);
});

document.addEventListener('mousedown', e => { 
    if(!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display='none'; 
});

function handleExplain() { 
    webkit.messageHandlers.readerBridge.postMessage({type:'explain', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

function handleGenerateImage() { 
    webkit.messageHandlers.readerBridge.postMessage({type:'generateImage', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

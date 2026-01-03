/**
 * ReaderBridge.js
 * 
 * Optimized for "Stop-Centered" scroll-syncing.
 * Implements land-ownership territories with directional handover.
 * Provides density-aware allocation to ensure all markers are reachable.
 * 
 * CORE ARCHITECTURE:
 * - "Ideal Stops": Every marker has a specific scroll position where it sits at 40% height.
 * - "Territories": Document space is divided halfway between these stops.
 * - "Elastic Spacing": Same-line markers are pushed apart to create distinct landing strips.
 */

// --- Configuration ---
const MIN_TERRITORY_HEIGHT = 100; // Minimum scroll height in pixels for each marker's land
const HYSTERESIS_THRESHOLD = 20;  // Movement buffer to prevent jitter when switching focus
const EYE_LINE_RATIO = 0.4;       // The vertical 'focal point' (40% of viewport height)
const VISIBILITY_BUFFER = 5;      // Margin for off-screen detection
const DEBUG_MODE = false;         // Enable to visualize territories and stops

// --- Global State ---
const focusState = { 
    lastScrollY: 0,
    lastVelocity: 0,
    lastReportedScrollY: 0,
    lastReportedTime: 0,
    currentStationIndex: -1,
    currentBlockIndex: -1,
    stations: [],       // List of all markers (getMarkers())
    boundaries: [],     // Territory division lines in scrollY space
    stops: [],          // Ideal scroll positions for each marker
    blockPositions: [], // Cached absolute Y positions of blocks
    reachedBottom: false,
    mapBuilt: false,
    idleTimeout: null
};

let scrollTicking = false;

/**
 * Programmatic Scroll & Lock Controller
 * Manages smooth scrolls and prevents focus-tracking from overriding intentional navigation.
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

    const driftTolerance = 4.0; // Max pixels user can scroll before breaking sticky lock
    const staleWriteMs = 150;   // Time after which a scroll is considered manual if no updates (increased for robustness)

    const cancel = (silent = false) => {
        const wasLocked = state.sticky;
        
        if (state.raf) {
            cancelAnimationFrame(state.raf);
        }
        
        state.raf = null;
        state.active = false;
        state.sticky = false; 
        state.targetId = null;
        state.targetY = null;
        state.expectedY = null;
        state.lastSetAt = 0;
        state.sessionId++; 
        
        if (state.timeout) {
            clearTimeout(state.timeout);
        }
        state.timeout = null;

        if (wasLocked && !silent) {
            // Force an update to notify Swift that the lock is released
            updateFocus(true);
        }
    };

    const complete = () => {
        if (state.raf) {
            cancelAnimationFrame(state.raf);
        }
        state.raf = null;
        state.active = false;
        state.expectedY = state.targetY; 
        
        if (state.timeout) {
            clearTimeout(state.timeout);
        }
        state.timeout = null;
        
        // Force an update to notify Swift that the animation is done
        updateFocus(true);
    };

    const start = (targetId, targetY) => {
        // Cancel existing sessions silently
        cancel(true); 

        const currentSession = state.sessionId;
        const startY = window.scrollY;
        
        // Ensure targetY is reachable to prevent drift-induced lock breaks
        const viewportHeight = window.innerHeight;
        const scrollMax = Math.max(1, document.documentElement.scrollHeight - viewportHeight);
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

        // If very close, just snap
        if (distance < 2) {
            window.scrollTo({ top: safeTargetY, behavior: 'auto' });
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
            if (!state.active || state.sessionId !== currentSession) {
                return;
            }

            const elapsed = now - startTime;
            const progress = Math.min(1, elapsed / duration);
            const eased = easeOutCubic(progress);
            const nextY = startY + (safeTargetY - startY) * eased;
            
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
            const timeSinceLastWrite = performance.now() - state.lastSetAt;
            
            // If user scrolled away or if programmatic engine stalled, break lock
            if (drift > driftTolerance || (state.active && timeSinceLastWrite > staleWriteMs)) {
                cancel();
            }
        },
        isActive: () => state.active,
        isSticky: () => state.sticky,
        preferredTargetId: () => state.sticky ? state.targetId : null
    };
})();

// --- DOM Queries ---

/**
 * Returns all potential "anchor" blocks (paragraphs, headers, etc.)
 */
function getBlocks() {
    const selector = 'p, h1, h2, h3, h4, h5, h6, blockquote, li';
    return Array.from(document.querySelectorAll(selector));
}

/**
 * Gathers all insight markers and calculates their physical positions.
 */
function getMarkers() {
    const selector = '.annotation-marker, .image-marker, .footnote-ref';
    const markerElements = Array.from(document.querySelectorAll(selector));
    
    const markers = markerElements.map((element, index) => {
        const rect = element.getBoundingClientRect();
        
        // Identify Type
        let type = 'annotation';
        if (element.classList.contains('image-marker')) {
            type = 'image';
        } else if (element.classList.contains('footnote-ref')) {
            type = 'footnote';
        }

        // Extract ID
        const id = element.dataset.annotationId || 
                   element.dataset.imageId || 
                   (element.getAttribute('href')?.split('#')[1]) || 
                   element.id;

        // Find Parent Block
        const block = element.closest('[id^="block-"]');
        const blockId = block ? 
            parseInt(block.id.replace("block-", ""), 10) : 
            parseInt(element.dataset.blockId || "0", 10);

        // Calculate absolute vertical center
        const centerY = rect.top + window.scrollY + (rect.height * 0.5);

        return { 
            element: element, 
            id: id, 
            type: type, 
            order: index, 
            blockId: blockId, 
            y: centerY 
        };
    });

    // Sort markers by document order (vertical position)
    return markers.sort((a, b) => {
        if (a.y !== b.y) {
            return a.y - b.y;
        }
        return a.order - b.order;
    });
}

// --- Territory Logic ---

/**
 * Builds the Stop-Centered Territory Map.
 * Calculates where every marker 'wants' to sit and divides land between them.
 */
function buildTerritoryMap() {
    const stations = getMarkers();
    const viewportHeight = window.innerHeight;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - viewportHeight);
    const stationCount = stations.length;

    // Cache block positions while we're doing layout work anyway
    const blocks = getBlocks();
    focusState.blockPositions = blocks.map(block => {
        const rect = block.getBoundingClientRect();
        return {
            top: rect.top + window.scrollY,
            bottom: rect.bottom + window.scrollY
        };
    });

    if (stationCount === 0) {
        focusState.stations = [];
        focusState.boundaries = [];
        focusState.stops = [];
        focusState.mapBuilt = true;
        return;
    }

    // Ensure markers don't overlap territories if possible
    const effectiveMinHeight = Math.min(MIN_TERRITORY_HEIGHT, scrollMax / stationCount);

    // 1. Calculate Ideal Stops (Scroll position where marker is at 40% height)
    let stops = stations.map(station => {
        const idealPosition = station.y - (viewportHeight * EYE_LINE_RATIO);
        // Clamp to reachable scroll range
        return Math.max(0, Math.min(scrollMax, idealPosition));
    });

    // 2. Forward Pass: Enforce minimum spacing (virtual depth for same-line markers)
    for (let i = 1; i < stationCount; i++) {
        const minPos = stops[i - 1] + effectiveMinHeight;
        if (stops[i] < minPos) {
            stops[i] = minPos;
        }
    }

    // 3. Backward Pass: If spacing pushed us past scrollMax, push back up
    if (stops[stationCount - 1] > scrollMax) {
        stops[stationCount - 1] = scrollMax;
        for (let i = stationCount - 2; i >= 0; i--) {
            const maxPos = stops[i + 1] - effectiveMinHeight;
            if (stops[i] > maxPos) {
                stops[i] = maxPos;
            }
        }
    }

    // 4. Calculate Boundaries (Midway points between stops)
    let boundaries = [];
    for (let i = 0; i < stationCount - 1; i++) {
        const midpoint = (stops[i] + stops[i + 1]) / 2;
        boundaries.push(midpoint);
    }
    
    // Final boundary covers the rest of the document
    boundaries.push(scrollMax + 1000);

    focusState.stations = stations;
    focusState.stops = stops;
    focusState.boundaries = boundaries;
    focusState.mapBuilt = true;
}

/**
 * Synchronizes Focus with Scroll Position
 */
function updateFocus(forceReport = false) {
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - viewportHeight);
    const scrollPercent = scrollY / scrollMax;
    const now = performance.now();
    
    if (!focusState.mapBuilt) {
        buildTerritoryMap();
    }

    const isLocked = programmatic.isSticky();
    const isAnimating = programmatic.isActive();
    const targetId = programmatic.preferredTargetId();
    
    let newStationIndex = -1;
    let activeBlockIndex = -1;

    // --- 1. Focus Determination ---
    if (isLocked && targetId) {
        newStationIndex = focusState.stations.findIndex(s => (s.type + "-" + s.id) === targetId || s.id === targetId);
    } else if (!isAnimating && focusState.stations.length > 0) {
        let idx = focusState.currentStationIndex;
        if (idx === -1) {
            idx = focusState.boundaries.findIndex(b => scrollY <= b);
            if (idx === -1) idx = focusState.stations.length - 1;
        } else {
            const lowerBound = idx === 0 ? 0 : focusState.boundaries[idx - 1];
            const upperBound = focusState.boundaries[idx];
            if (scrollY > upperBound + 100 || scrollY < lowerBound - 100) {
                idx = focusState.boundaries.findIndex(b => scrollY <= b);
                if (idx === -1) idx = focusState.stations.length - 1;
            } else {
                if (scrollY > upperBound + HYSTERESIS_THRESHOLD && idx < focusState.stations.length - 1) idx++;
                else if (scrollY < lowerBound - HYSTERESIS_THRESHOLD && idx > 0) idx--;
            }
        }

        const owner = focusState.stations[idx];
        const isOwnerVisible = (owner.y >= scrollY - VISIBILITY_BUFFER) && 
                               (owner.y <= scrollY + viewportHeight + VISIBILITY_BUFFER);
        
        if (isOwnerVisible) {
            newStationIndex = idx;
        } else if (owner) {
            if (owner.y < scrollY) {
                const nextVisible = focusState.stations.slice(idx + 1).find(m => 
                    (m.y >= scrollY - VISIBILITY_BUFFER) && (m.y <= scrollY + viewportHeight + VISIBILITY_BUFFER)
                );
                if (nextVisible) newStationIndex = focusState.stations.indexOf(nextVisible);
            } else {
                const prevVisible = focusState.stations.slice(0, idx).reverse().find(m => 
                    (m.y >= scrollY - VISIBILITY_BUFFER) && (m.y <= scrollY + viewportHeight + VISIBILITY_BUFFER)
                );
                if (prevVisible) newStationIndex = focusState.stations.indexOf(prevVisible);
            }
        }
    }

    // --- 2. Block Tracking ---
    if (!isAnimating) {
        const blockEyeLine = scrollY + (viewportHeight * EYE_LINE_RATIO); 
        let minBlockDist = Infinity;
        
        focusState.blockPositions.forEach((pos, i) => {
            const top = pos.top;
            const bottom = pos.bottom;
            let distance = 0;
            if (blockEyeLine < top) distance = top - blockEyeLine;
            else if (blockEyeLine > bottom) distance = blockEyeLine - bottom;
            
            if (distance < minBlockDist) { 
                minBlockDist = distance; 
                activeBlockIndex = i; 
            }
        });
    }

    // --- 3. Lazy Reporting Logic ---
    const hasChangedFocus = newStationIndex !== focusState.currentStationIndex;
    const hasChangedBlock = activeBlockIndex !== -1 && activeBlockIndex !== focusState.currentBlockIndex;
    
    // Always keep state indices current so Heartbeat is accurate
    focusState.currentStationIndex = newStationIndex;
    if (activeBlockIndex !== -1) focusState.currentBlockIndex = activeBlockIndex;

    // Efficiency Math:
    const timeSinceLastReport = now - focusState.lastReportedTime;
    const movedFarEnough = Math.abs(scrollY - focusState.lastReportedScrollY) > 300;
    
    // PRIORITY 0: Forced Report or Focus Change (Must be immediate for UI consistency)
    if (forceReport || hasChangedFocus) {
        focusState.lastReportedScrollY = scrollY;
        focusState.lastReportedTime = now;
        reportToNative(scrollY, scrollPercent, viewportHeight, isLocked, hasChangedFocus);
    } 
    // PRIORITY 2: Block Change or Large Move (Gated by time to prevent spam during fast scrolls)
    else if ((hasChangedBlock || movedFarEnough || isLocked) && timeSinceLastReport > 150) {
        focusState.lastReportedScrollY = scrollY;
        focusState.lastReportedTime = now;
        reportToNative(scrollY, scrollPercent, viewportHeight, isLocked, false);
    }

    // --- 4. Idle Heartbeat (Final persistence safety) ---
    clearTimeout(focusState.idleTimeout);
    focusState.idleTimeout = setTimeout(() => {
        const latestScrollY = window.scrollY;
        const scrollMaxLatest = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
        const latestScrollPercent = latestScrollY / scrollMaxLatest;
        
        // Final sync if we've moved since the last report
        if (Math.abs(latestScrollY - focusState.lastReportedScrollY) > 5) {
            reportToNative(latestScrollY, latestScrollPercent, window.innerHeight, programmatic.isSticky(), false);
        }
    }, 1000);
}

function reportToNative(scrollY, scrollPercent, viewportHeight, isLocked, shouldPulse) {
    const station = focusState.stations[focusState.currentStationIndex];
    
    // Trigger pulse on manual entry ONLY if the focus actually changed and we have a station
    if (shouldPulse && !isLocked && station && station.element && focusState.lastVelocity < 40) {
        const isVisible = (station.y >= scrollY - VISIBILITY_BUFFER) && 
                          (station.y <= scrollY + viewportHeight + VISIBILITY_BUFFER);
        if (isVisible) pulseMarker(station.element);
    }

    webkit.messageHandlers.readerBridge.postMessage({
        type: 'scrollPosition',
        annotationId: station?.type === 'annotation' ? station.id : null, 
        imageId: station?.type === 'image' ? station.id : null, 
        footnoteRefId: station?.type === 'footnote' ? station.id : null,
        blockId: focusState.currentBlockIndex !== -1 ? focusState.currentBlockIndex + 1 : null,
        primaryType: station?.type || null,
        scrollY: scrollY, 
        scrollPercent: scrollPercent, 
        viewportHeight: viewportHeight,
        isProgrammatic: isLocked
    });
}

/**
 * Visualizes territories for debugging.
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
    
    const viewportHeight = window.innerHeight;
    const scrollY = window.scrollY;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - viewportHeight);
    
    // Sidebar Mini-map
    const sidebarWidth = 60;
    const sidebar = document.createElement('div');
    sidebar.style = `position:fixed; top:0; right:0; width:${sidebarWidth}px; height:100vh; background:rgba(0,0,0,0.05); border-left:1px solid rgba(0,0,0,0.1); z-index:10001;`;
    container.appendChild(sidebar);

    const scrollIndicator = document.createElement('div');
    const scrollPosRatio = scrollY / scrollMax;
    scrollIndicator.style = `position:absolute; top:${scrollPosRatio * 100}%; right:0; width:100%; height:2px; background:red; z-index:10002;`;
    sidebar.appendChild(scrollIndicator);

    // Territories
    focusState.boundaries.forEach((boundary, i) => {
        const start = i === 0 ? 0 : focusState.boundaries[i - 1];
        const height = boundary - start;
        if (height <= 0) return;

        const isActive = scrollY >= start && scrollY < boundary;
        const color = i % 2 === 0 ? '0, 255, 0' : '0, 0, 255';
        const opacity = isActive ? '0.1' : '0.03';

        // In-situ visualization
        const box = document.createElement('div');
        box.style = `position:absolute; top:${start}px; left:0; width:100%; height:${height}px; border-top:1px solid rgba(0,0,0,0.05); box-sizing:border-box;`;
        box.style.backgroundColor = `rgba(${color}, ${opacity})`;
        
        if (isActive) {
            box.style.borderLeft = "4px solid red";
        }

        const label = document.createElement('span');
        const markerType = focusState.stations[i].type.charAt(0).toUpperCase();
        label.innerText = `T${i}:${markerType} Stop:${Math.round(focusState.stops[i])}`;
        label.style = `font-size:10px; color:${isActive ? 'red' : 'rgba(0,0,0,0.4)'}; font-weight:${isActive ? 'bold' : 'normal'}; margin-left:10px; position:absolute; top:4px; background:rgba(255,255,255,0.7); padding:2px; border-radius:2px;`;
        box.appendChild(label);

        // Sidebar Segment
        const segment = document.createElement('div');
        const segTop = (start / scrollMax) * 100;
        const segHeight = (height / scrollMax) * 100;
        segment.style = `position:absolute; top:${segTop}%; left:0; width:100%; height:${segHeight}%; background:rgba(${color}, 0.2); border-bottom:1px solid rgba(0,0,0,0.1); box-sizing:border-box;`;
        
        const stopDot = document.createElement('div');
        const stopRatio = (focusState.stops[i] / scrollMax) * 100;
        stopDot.style = `position:absolute; top:${(stopRatio - segTop) / segHeight * 100}%; left:0; width:100%; height:2px; background:magenta;`;
        segment.appendChild(stopDot);
        sidebar.appendChild(segment);

        // Ideal Stop Line
        const stopY = focusState.stops[i];
        const stopLine = document.createElement('div');
        stopLine.style = `position:absolute; top:${stopY}px; left:0; width:100%; height:1px; border-top:1px dashed rgba(255,0,255,0.4);`;
        container.appendChild(stopLine);
        container.appendChild(box);
    });
}

/**
 * Triggers a visual pulse on a marker
 */
function pulseMarker(element) {
    if (!element) return;
    const colorVariable = element.classList.contains('image-marker') ? '--iris' : '--rose';
    element.style.setProperty('--highlight-color', 'var(' + colorVariable + ')');
    element.classList.remove('marker-pulse');
    void element.offsetWidth; // Trigger reflow
    element.classList.add('marker-pulse');
    setTimeout(() => {
        element.classList.remove('marker-pulse');
    }, 650);
}

/**
 * Triggers the persistent highlight animation for markers (dots)
 */
function highlightMarker(element) {
    if (!element) return;
    const isImage = element.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    
    element.classList.add('marker-highlight');
    element.style.setProperty('--highlight-color', 'var(' + colorVar + ')');
    
    setTimeout(() => {
        element.classList.remove('marker-highlight');
    }, 1500);
}

/**
 * Triggers the flash-and-fade highlight animation for content blocks
 */
function highlightBlock(element) {
    if (!element) return;
    
    element.classList.add('highlight-active');
    
    // Force immediate flash state
    element.style.backgroundColor = 'var(--rose)';
    element.style.color = 'var(--base)';
    element.style.transition = 'none';

    setTimeout(() => {
        // Start smooth fade-out
        element.style.transition = 'background-color 1.5s ease-out, color 1.5s ease-out';
        element.style.backgroundColor = '';
        element.style.color = '';
        
        setTimeout(() => {
            element.classList.remove('highlight-active');
            element.style.transition = '';
        }, 1500);
    }, 400);
}

// --- Smooth Scrolling API ---

/**
 * Performs a smooth scroll to a specific element.
 */
function performSmoothScroll(element, viewportRatio, targetId) {
    const viewportHeight = window.innerHeight;
    const scrollHeight = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, scrollHeight - viewportHeight);
    
    let targetY = null;
    
    // Try to find the pre-calculated 'ideal stop' for this specific marker.
    // This ensures we land in the dead center of its territory.
    if (focusState.stations.length > 0) {
        const index = focusState.stations.findIndex(station => 
            (station.type + "-" + station.id) === targetId || station.id === targetId
        );
        
        if (index !== -1 && focusState.stops[index] !== undefined) {
            targetY = focusState.stops[index];
        }
    }
    
    // Fallback to physical calculation if no pre-calculated stop exists (e.g. raw block)
    if (targetY === null) {
        const rect = element.getBoundingClientRect();
        targetY = window.scrollY + rect.top - (viewportHeight * viewportRatio);
    }
    
    // CRITICAL: Clamp targetY to reachable range to prevent drift from breaking the lock.
    const safeTargetY = Math.max(0, Math.min(scrollMax, targetY));
    
    programmatic.start(targetId, safeTargetY);
}

function scrollToAnnotation(id) {
    const element = document.querySelector('[data-annotation-id="' + id + '"]');
    if (element) {
        performSmoothScroll(element, EYE_LINE_RATIO, 'annotation-' + id);
        highlightMarker(element);
    }
}

function scrollToBlock(id, markerId, type) {
    const blocks = getBlocks();
    if (id > 0 && id <= blocks.length) {
        const block = blocks[id - 1];
        const targetId = markerId && type ? `${type}-${markerId}` : `block-${id}`;
        
        performSmoothScroll(block, EYE_LINE_RATIO, targetId);
        
        // Target Hijacking: If this scroll is for a specific insight/image, highlight the marker instead of the block
        if (markerId && type) {
            const marker = document.querySelector(`[data-${type}-id="${markerId}"]`);
            if (marker) {
                highlightMarker(marker);
            }
        } else {
            highlightBlock(block);
        }
    }
}

function scrollToQuote(quoteId) {
    const selector = '[href="#' + quoteId + '"], [id="' + quoteId + '"]';
    const element = document.querySelector(selector);
    if (element) {
        performSmoothScroll(element, EYE_LINE_RATIO, 'footnote-' + quoteId);
        
        // If it's a marker (footnote ref), use marker highlight
        if (element.classList.contains('footnote-ref')) {
            highlightMarker(element);
        } else {
            highlightBlock(element);
        }
    }
}

function scrollToPercent(percent) { 
    const scrollMax = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo({ 
        top: scrollMax * percent, 
        behavior: 'auto' 
    }); 
}

function scrollToOffset(offset) { 
    window.scrollTo({ 
        top: offset, 
        behavior: 'auto' 
    }); 
}

// --- Event Listeners ---

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;
    
    // Update velocity tracking
    focusState.lastVelocity = Math.abs(scrollY - focusState.lastScrollY);
    focusState.lastScrollY = scrollY;
    
    // Inform programmatic engine
    programmatic.noteScroll(scrollY);
    
    // Throttled update loop
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            updateFocus();
            
            // Bottom-tug detection
            const scrollMax = document.documentElement.scrollHeight - window.innerHeight;
            if (scrollMax > 0 && scrollY >= scrollMax - 1) {
                focusState.reachedBottom = true;
            } else if (scrollY < scrollMax - 20) {
                focusState.reachedBottom = false;
            }
            
            if (focusState.reachedBottom && scrollY > scrollMax + 5) {
                webkit.messageHandlers.readerBridge.postMessage({ type: 'bottomTug' });
                focusState.reachedBottom = false; 
            }
            
            scrollTicking = false;
        });
    }
});

// Selection Overlay Logic
const selectionOverlay = document.getElementById('selectionOverlay');
function updateSelectionOverlay() {
    if (!selectionOverlay) return;
    
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) { 
        selectionOverlay.innerHTML = ''; 
        return; 
    }
    
    const range = selection.getRangeAt(0);
    const rects = Array.from(range.getClientRects());
    
    selectionOverlay.innerHTML = '';
    rects.forEach(rect => {
        const div = document.createElement('div');
        div.className = 'selection-rect';
        div.style.left = (rect.left + window.scrollX) + 'px';
        div.style.top = (rect.top + window.scrollY) + 'px';
        div.style.width = rect.width + 'px';
        div.style.height = rect.height + 'px';
        selectionOverlay.appendChild(div);
    });
}

document.addEventListener('selectionchange', updateSelectionOverlay);

window.addEventListener('resize', () => { 
    buildTerritoryMap(); 
    updateFocus(); 
});

// Click Interactions
document.addEventListener('click', event => {
    const target = event.target;
    if (target.classList.contains('annotation-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({ 
            type: 'annotationClick', 
            id: target.dataset.annotationId 
        });
    }
    if (target.classList.contains('image-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({ 
            type: 'imageMarkerClick', 
            id: target.dataset.imageId 
        });
    }
});

document.addEventListener('dblclick', event => {
    if (event.target.classList.contains('image-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({ 
            type: 'imageMarkerDblClick', 
            id: event.target.dataset.imageId 
        });
    }
});

// Context Menu / Word Popup Logic
document.addEventListener('mouseup', event => {
    // Delay to allow selection to finalize
    setTimeout(() => {
        const selection = window.getSelection();
        const text = selection.toString().trim();
        const popup = document.getElementById('wordPopup');
        
        if (!selection.isCollapsed && text) {
            const range = selection.getRangeAt(0);
            const container = range.startContainer.parentElement;
            const blocks = getBlocks();
            const blockId = blocks.findIndex(block => block.contains(container)) + 1;
            
            popup.style.left = event.clientX + 'px'; 
            popup.style.top = (event.clientY + 10) + 'px'; 
            popup.style.display = 'block';
            
            // Store global context for popup actions
            window.selectedWord = text; 
            window.selectedBlockId = blockId || 1; 
            window.selectedContext = container.textContent;
        } else if (!event.target.closest('.word-popup')) {
            popup.style.display = 'none';
        }
    }, 20);
});

document.addEventListener('mousedown', event => { 
    if (!event.target.closest('.word-popup')) {
        document.getElementById('wordPopup').style.display = 'none'; 
    }
});

// Popup Handlers
function handleExplain() { 
    webkit.messageHandlers.readerBridge.postMessage({
        type: 'explain', 
        word: window.selectedWord, 
        context: window.selectedContext, 
        blockId: window.selectedBlockId
    }); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

function handleGenerateImage() { 
    webkit.messageHandlers.readerBridge.postMessage({
        type: 'generateImage', 
        word: window.selectedWord, 
        context: window.selectedContext, 
        blockId: window.selectedBlockId
    }); 
    document.getElementById('wordPopup').style.display = 'none'; 
}

// Marker Injections (Triggered by Native App)
function injectMarkerAtBlock(annotationId, blockIndex) { 
    const blocks = getBlocks(); 
    if (blockIndex > 0 && blockIndex <= blocks.length) { 
        const marker = document.createElement('span'); 
        marker.className = 'annotation-marker'; 
        marker.dataset.annotationId = annotationId; 
        marker.dataset.blockId = blockIndex; 
        
        blocks[blockIndex - 1].appendChild(marker);
        
        // Rebuild map as DOM has changed
        buildTerritoryMap();
        updateFocus();
    } 
}

function injectImageMarker(imageId, blockIndex) { 
    const blocks = getBlocks(); 
    if (blockIndex > 0 && blockIndex <= blocks.length) { 
        const marker = document.createElement('span'); 
        marker.className = 'image-marker'; 
        marker.dataset.imageId = imageId; 
        marker.dataset.blockId = blockIndex; 
        
        blocks[blockIndex - 1].appendChild(marker);
        
        // Rebuild map as DOM has changed
        buildTerritoryMap();
        updateFocus();
    } 
}
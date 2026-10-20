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
    bottomArrivalTime: 0,
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
let isInitializingReader = false;

// The same logical document is either vertically scrolled or flowed into columns.
// Page-mode offsets are virtual vertical coordinates: pageIndex * viewportHeight.
// This keeps existing progress/back-navigation consumers on the scroll bridge.
const pagination = {
    mode: 'scroll',
    layout: 'spread',
    capacity: 1,
    gap: 1,
    pageIndex: 0,
    pageCount: 1,
    pitch: 1,
    width: 1,
    height: 1,
    insetX: 60,
    insetY: 40,
    anchor: null,
    scrollAnchorY: null,
    needsAnchor: true,
    reflowFrame: null,
    wheelTimer: null,
    wheelDelta: 0,
    wheelConsumed: false
};

function pageMetadata() {
    return {
        pageIndex: pagination.pageIndex,
        pageCount: pagination.pageCount,
        visiblePageCount: Math.min(pagination.capacity, pagination.pageCount - pagination.pageIndex),
        pageCapacity: pagination.capacity,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight,
        pageWidth: pagination.width,
        pageHeight: pagination.height,
        pageGap: pagination.gap,
        pagePitch: pagination.pitch,
        insetX: pagination.insetX,
        insetY: pagination.insetY,
        layout: pagination.layout,
        effectiveLayout: pagination.capacity === 2 ? 'spread' : 'single'
    };
}

function spreadStart(index) {
    const lastStart = Math.floor((pagination.pageCount - 1) / pagination.capacity) * pagination.capacity;
    return Math.max(0, Math.min(lastStart, Math.floor(index / pagination.capacity) * pagination.capacity));
}

async function measurePagination({ offscreen = false } = {}) {
    if (document.fonts) await document.fonts.ready;
    await Promise.all(Array.from(document.querySelectorAll('#readerContent img'), image => {
        // Hidden whole-book measurement must load offscreen EPUB images too.
        image.loading = 'eager';
        if (image.complete) return Promise.resolve();
        return new Promise(resolve => {
            const finished = () => {
                image.removeEventListener('load', finished);
                image.removeEventListener('error', finished);
                resolve();
            };
            image.addEventListener('load', finished);
            image.addEventListener('error', finished);
        });
    }));
    // Hidden WKWebViews may suspend their animation clock. Forced geometry reads
    // in rebuildPages still perform the same layout after fonts/images settle.
    if (!offscreen) {
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    }
    if (pagination.mode === 'pages') rebuildPages();
    return pageMetadata();
}

function installPageStyle() {
    const content = document.getElementById('readerContent');
    if (!document.getElementById('readerPageWindow')) {
        const pageWindow = document.createElement('div');
        pageWindow.id = 'readerPageWindow';
        content.before(pageWindow);
        pageWindow.appendChild(content);
    }
    if (document.getElementById('readerPageStyle')) return;
    const style = document.createElement('style');
    style.id = 'readerPageStyle';
    style.textContent = `
        #readerPageWindow { display: contents; }
        html.reader-pages #readerPageWindow {
            display: block;
            width: var(--reader-window-width); height: var(--reader-page-height);
            overflow: hidden; overflow: clip;
        }
        html.reader-pages, html.reader-pages body {
            width: 100%; height: 100%; overflow: hidden !important;
            overscroll-behavior: none; scroll-behavior: auto !important;
        }
        html.reader-pages body {
            box-sizing: border-box;
            padding: var(--reader-inset-y) var(--reader-inset-x) !important;
        }
        html.reader-pages #readerContent {
            width: var(--reader-page-width); height: var(--reader-page-height);
            max-width: none !important; max-height: none !important;
            column-width: var(--reader-page-width); column-count: auto;
            column-gap: var(--reader-page-gap); column-fill: auto;
            overflow: visible; overflow-wrap: anywhere;
        }
        html.reader-pages #readerContent [data-reader-block-id],
        html.reader-pages #readerContent [id^="block-"] {
            break-inside: auto !important; page-break-inside: auto !important;
            orphans: 2; widows: 2;
        }
        html.reader-pages #readerContent img,
        html.reader-pages #readerContent svg,
        html.reader-pages #readerContent video,
        html.reader-pages #readerContent canvas {
            max-width: 100% !important;
            max-height: calc(var(--reader-page-height) - 2em) !important;
            object-fit: contain; box-sizing: border-box;
            break-inside: avoid; page-break-inside: avoid;
        }
        html.reader-pages #readerContent .generated-image { margin: 1em 0; }
        html.reader-pages #readerContent pre { white-space: pre-wrap; }
        html.reader-pages #readerContent table { max-width: 100%; table-layout: fixed; }
        html.reader-pages .selection-overlay { position: fixed; }
    `;
    document.head.appendChild(style);
}

function rectIsOnPage(rect) {
    if (rect.width <= 0 || rect.height <= 0 ||
        rect.bottom <= pagination.insetY || rect.top >= pagination.insetY + pagination.height) return false;
    const span = Math.min(pagination.capacity, pagination.pageCount - pagination.pageIndex);
    for (let column = 0; column < span; column++) {
        const left = pagination.insetX + column * pagination.pitch;
        if (rect.right > left && rect.left < left + pagination.width) return true;
    }
    return false;
}

function elementIsOnPage(element) {
    for (const rect of element.getClientRects()) {
        if (rectIsOnPage(rect)) return true;
    }
    return false;
}

function pageForRect(rect) {
    const documentX = rect.left + pagination.pageIndex * pagination.pitch - pagination.insetX;
    return Math.max(0, Math.floor((documentX + Math.min(rect.width / 2, 1)) / pagination.pitch));
}

function firstElementRect(element) {
    const rects = element.getClientRects();
    for (const rect of rects) {
        if (rect.width > 0 && rect.height > 0) return rect;
    }
    return element.getBoundingClientRect();
}

// A text fraction, unlike a paragraph's bounding box, remains meaningful when a
// paragraph spans several columns. Ranges give the actual fragment at that offset.
function rangeAtBlockOffset(block, offset) {
    const length = block.textContent.length;
    if (!length) return null;
    let remaining = Math.min(length - 1, Math.max(0, Math.floor(length * offset)));
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
        if (remaining < node.length) {
            const range = document.createRange();
            range.setStart(node, remaining);
            range.setEnd(node, remaining + 1);
            return range;
        }
        remaining -= node.length;
    }
    return null;
}

function anchorFromCaret(x, y) {
    let range;
    if (document.caretRangeFromPoint) {
        range = document.caretRangeFromPoint(x, y);
    } else if (document.caretPositionFromPoint) {
        const position = document.caretPositionFromPoint(x, y);
        if (position) {
            range = document.createRange();
            range.setStart(position.offsetNode, position.offset);
            range.collapse(true);
        }
    }
    if (!range) return null;
    const block = getClosestBlock(range.startContainer.nodeType === Node.ELEMENT_NODE
        ? range.startContainer : range.startContainer.parentElement);
    const blockId = blockIdFromElement(block);
    if (!blockId) return null;
    const prefix = document.createRange();
    prefix.selectNodeContents(block);
    prefix.setEnd(range.startContainer, range.startOffset);
    const offset = block.textContent.length ? prefix.toString().length / block.textContent.length : 0;
    const character = rangeAtBlockOffset(block, offset);
    const rect = character ? firstElementRect(character) : firstElementRect(block);
    if (pagination.mode === 'pages' && !rectIsOnPage(rect)) return null;
    if (pagination.mode !== 'pages' && (rect.bottom < 0 || rect.top > window.innerHeight)) return null;
    return { blockId, offset };
}

function anchorForElement(element) {
    let block = getClosestBlock(element) || getBlockByIdOrIndex(element.dataset.blockId);
    if (!block) {
        for (const candidate of document.querySelectorAll(BLOCK_SELECTOR)) {
            if (element.compareDocumentPosition(candidate) & Node.DOCUMENT_POSITION_PRECEDING) block = candidate;
            else if (!block) { block = candidate; break; }
            else break;
        }
    }
    let offset = element === block ? 0 : 1;
    if (block?.contains(element) && element !== block && block.textContent.length) {
        const prefix = document.createRange();
        prefix.selectNodeContents(block);
        prefix.setEndBefore(element);
        offset = prefix.toString().length / block.textContent.length;
    }
    // A fragmented block can own an empty box before its first text line
    // (orphans/widows). Restore text blocks through a character Range instead.
    return { blockId: blockIdFromElement(block), offset,
        element: element === block && block.textContent.length ? null : element };
}

function offsetAtEyeLine(block, fragment) {
    const length = block.textContent.length;
    if (!length) return 0;
    const targetPage = pagination.mode === 'pages' ? pageForRect(fragment) : 0;
    let low = 0;
    let high = length - 1;
    while (low < high) {
        const middle = (low + high) >>> 1;
        const rect = firstElementRect(rangeAtBlockOffset(block, middle / length));
        const page = pagination.mode === 'pages' ? pageForRect(rect) : 0;
        if (page < targetPage || (page === targetPage && rect.bottom < window.innerHeight * EYE_LINE_RATIO)) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low / length;
}

function captureReadingAnchor() {
    const eyeLine = window.innerHeight * EYE_LINE_RATIO;
    const firstColumnCenter = pagination.mode === 'pages'
        ? pagination.insetX + pagination.width / 2 : window.innerWidth / 2;
    const elementAtEyeLine = document.elementFromPoint(firstColumnCenter, eyeLine);
    if (elementAtEyeLine instanceof HTMLImageElement) return anchorForElement(elementAtEyeLine);
    for (const x of [firstColumnCenter, pagination.insetX + 4, window.innerWidth - pagination.insetX - 4]) {
        const anchor = anchorFromCaret(x, eyeLine);
        if (anchor) return anchor;
    }

    // Image-only pages and whitespace between blocks have no text caret.
    let best = null;
    let bestDistance = Infinity;
    for (const element of document.querySelectorAll(`${BLOCK_SELECTOR}, #readerContent img`)) {
        const elementAnchor = anchorForElement(element);
        const rects = element.getClientRects();
        for (let index = 0; index < rects.length; index++) {
            const rect = rects[index];
            const visible = pagination.mode === 'pages' ? rectIsOnPage(rect)
                : rect.bottom > 0 && rect.top < window.innerHeight;
            if (!visible) continue;
            const distance = Math.abs(Math.max(rect.top, Math.min(rect.bottom, eyeLine)) - eyeLine);
            if (distance >= bestDistance) continue;
            bestDistance = distance;
            best = element.matches('img') ? elementAnchor : {
                blockId: elementAnchor.blockId,
                offset: offsetAtEyeLine(element, rect)
            };
        }
    }
    return best;
}

function anchorRect(anchor) {
    if (!anchor) return null;
    if (anchor.element?.isConnected) return firstElementRect(anchor.element);
    const block = getBlockByIdOrIndex(anchor.blockId);
    if (!block) return null;
    const range = rangeAtBlockOffset(block, anchor.offset);
    return firstElementRect(range || block);
}

function renderPage() {
    const content = document.getElementById('readerContent');
    content.style.transform = `translateX(${-pagination.pageIndex * pagination.pitch}px)`;
    // A browser's fragment navigation/selection must not leave a hidden scroll
    // offset on either the viewport or the multicolumn element.
    window.scrollTo(0, 0);
    content.scrollLeft = 0;
    content.scrollTop = 0;
}

function rebuildPages(anchor = pagination.anchor) {
    if (pagination.reflowFrame !== null) {
        cancelAnimationFrame(pagination.reflowFrame);
        pagination.reflowFrame = null;
    }
    const root = document.documentElement;
    const content = document.getElementById('readerContent');
    // Keep the column width and gap integral. WebKit quantizes fractional CSS
    // lengths independently; that tiny stride error otherwise accumulates into
    // a wrong page index near the end of a long chapter.
    const viewportWidth = Math.floor(window.innerWidth);
    const outerMargin = Math.floor(Math.min(60, Math.max(24, viewportWidth * 0.055)));
    const spreadGap = Math.floor(Math.min(56, Math.max(32, viewportWidth * 0.05)));
    pagination.capacity = pagination.layout === 'spread' &&
        viewportWidth - outerMargin * 2 - spreadGap >= 280 * 2 ? 2 : 1;
    pagination.width = Math.max(1, Math.floor(
        (viewportWidth - outerMargin * 2 - (pagination.capacity - 1) * spreadGap) / pagination.capacity));
    const spreadWidth = pagination.width * pagination.capacity + (pagination.capacity - 1) * spreadGap;
    pagination.insetX = Math.floor((viewportWidth - spreadWidth) / 2);
    pagination.insetY = Math.floor(Math.min(40, Math.max(12, window.innerHeight * 0.06)));
    pagination.height = Math.max(1, Math.floor(window.innerHeight) - pagination.insetY * 2);
    pagination.gap = pagination.capacity === 2 ? spreadGap : pagination.insetX * 2;
    pagination.pitch = pagination.width + pagination.gap;
    root.style.setProperty('--reader-inset-x', `${pagination.insetX}px`);
    root.style.setProperty('--reader-inset-y', `${pagination.insetY}px`);
    root.style.setProperty('--reader-page-width', `${pagination.width}px`);
    root.style.setProperty('--reader-page-height', `${pagination.height}px`);
    root.style.setProperty('--reader-page-gap', `${pagination.gap}px`);
    root.style.setProperty('--reader-window-width', `${spreadWidth}px`);
    renderPage();
    pagination.pageCount = Math.max(1, Math.ceil(
        (content.scrollWidth + pagination.gap - 1) / pagination.pitch));
    const rect = anchorRect(anchor);
    pagination.pageIndex = spreadStart(rect ? pageForRect(rect) : pagination.pageIndex);
    pagination.anchor = anchor;
    pagination.needsAnchor = !anchor;
    renderPage();
    buildTerritoryMap();
    updateFocus(true);
    updateSelectionOverlay();
    postToNative({ type: 'pageMetadata', ...pageMetadata() });
    return pageMetadata();
}

function schedulePageReflow() {
    if (pagination.reflowFrame !== null) return;
    pagination.reflowFrame = requestAnimationFrame(() => {
        pagination.reflowFrame = null;
        if (pagination.mode === 'pages') rebuildPages();
    });
}

function flushPageReflow() {
    if (pagination.mode !== 'pages' || pagination.reflowFrame === null) return;
    cancelAnimationFrame(pagination.reflowFrame);
    pagination.reflowFrame = null;
    rebuildPages();
}

function setPageLayout(layout) {
    if ((layout !== 'single' && layout !== 'spread') || layout === pagination.layout) return pageMetadata();
    flushPageReflow();
    pagination.layout = layout;
    if (pagination.mode === 'pages') return rebuildPages();
    return pageMetadata();
}

function setReadingMode(mode) {
    if (mode !== 'pages' && mode !== 'scroll') return pageMetadata();
    flushPageReflow();
    if (mode === pagination.mode) return pageMetadata();
    // Retain the exact character through an immediate round trip. Re-capturing
    // a nearby caret can otherwise land just across a column boundary.
    const anchor = pagination.mode === 'pages' ||
        (pagination.scrollAnchorY !== null && Math.abs(window.scrollY - pagination.scrollAnchorY) < 1)
        ? pagination.anchor : captureReadingAnchor();
    const wasLocked = programmatic.isSticky();
    const targetId = programmatic.preferredTargetId();
    programmatic.cancel(true);
    clearTimeout(focusState.idleTimeout);
    focusState.idleTimeout = null;
    pagination.mode = mode;
    pagination.anchor = anchor;
    pagination.needsAnchor = !anchor;
    installPageStyle();
    document.documentElement.classList.toggle('reader-pages', mode === 'pages');
    focusState.currentBlockIndex = -1;
    focusState.currentStationIndex = -1;
    focusState.mapBuilt = false;
    if (wasLocked) programmatic.lock(targetId);
    if (mode === 'pages') {
        for (const block of document.querySelectorAll('.highlight-active')) block.classList.remove('highlight-active');
        return rebuildPages(anchor);
    }

    document.getElementById('readerContent').style.removeProperty('transform');
    const rect = anchorRect(anchor);
    if (rect) window.scrollTo(0, Math.max(0, window.scrollY + rect.top - window.innerHeight * EYE_LINE_RATIO));
    if (wasLocked) programmatic.lock(targetId);
    focusState.lastBlockCheckY = -Infinity;
    buildTerritoryMap();
    updateFocus(true);
    pagination.scrollAnchorY = window.scrollY;
    updateSelectionOverlay();
    return pageMetadata();
}

function navigateToPage(index, targetId = null, anchor = null, locked = true) {
    if (locked) programmatic.lock(targetId);
    else programmatic.cancel(true);
    pagination.pageIndex = spreadStart(Math.round(index));
    pagination.anchor = anchor;
    pagination.needsAnchor = !anchor;
    renderPage();
    focusState.lastVelocity = 0;
    updateFocus(true);
    updateSelectionOverlay();
    const popup = document.getElementById('wordPopup');
    if (popup) popup.style.display = 'none';
    return pageMetadata();
}

function turnPage(delta) {
    if (pagination.mode !== 'pages' || !Number.isFinite(delta)) return pageMetadata();
    flushPageReflow();
    const step = Math.trunc(delta);
    if (step > 0 && pagination.pageIndex + pagination.capacity >= pagination.pageCount) {
        // Arrival never opens the quiz. Only a separate deliberate advance does.
        postToNative({ type: 'bottomTug' });
    }
    if (step < 0 && pagination.pageIndex === 0) {
        postToNative({ type: 'topTug' });
    }
    if (step !== 0) return navigateToPage(pagination.pageIndex + step * pagination.capacity, null, null, false);
    return pageMetadata();
}

function updatePageFocus(forceReport) {
    if (!focusState.mapBuilt) buildTerritoryMap();
    if (pagination.needsAnchor) {
        pagination.anchor = captureReadingAnchor();
        pagination.needsAnchor = false;
    }
    const anchor = pagination.anchor;
    focusState.currentBlockIndex = anchor?.blockId ? anchor.blockId - 1 : -1;
    focusState.currentBlockOffset = anchor?.offset || 0;

    const targetId = programmatic.preferredTargetId();
    let stationIndex = -1;
    let bestDistance = Infinity;
    let low = 0;
    let high = focusState.stations.length;
    while (low < high) {
        const middle = (low + high) >>> 1;
        if (focusState.stations[middle].pageIndex < pagination.pageIndex) low = middle + 1;
        else high = middle;
    }
    for (let index = low; index < focusState.stations.length; index++) {
        const station = focusState.stations[index];
        if (station.pageIndex < pagination.pageIndex) continue;
        if (station.pageIndex >= pagination.pageIndex + pagination.capacity) break;
        if (!elementIsOnPage(station.element)) continue;
        if (programmatic.isSticky()) {
            if (`${station.type}-${station.id}` === targetId || String(station.id) === String(targetId)) {
                stationIndex = index;
                break;
            }
        } else {
            const distance = Math.abs(station.y % window.innerHeight - window.innerHeight * EYE_LINE_RATIO);
            if (distance < bestDistance) {
                stationIndex = index;
                bestDistance = distance;
            }
        }
    }
    const changed = stationIndex !== focusState.currentStationIndex;
    focusState.currentStationIndex = stationIndex;
    const atBottom = pagination.pageIndex + pagination.capacity >= pagination.pageCount;
    if (atBottom && !focusState.reachedBottom) focusState.bottomArrivalTime = Date.now();
    focusState.reachedBottom = atBottom;
    const progress = atBottom ? 1 : pagination.pageIndex / (pagination.pageCount - 1);
    reportToNative(pagination.pageIndex * window.innerHeight, progress, window.innerHeight,
        pagination.pageCount * window.innerHeight, programmatic.isSticky(), changed, forceReport);
}

function postToNative(message) {
    webkit.messageHandlers.readerBridge.postMessage({
        ...message,
        documentToken: window.__readerDocumentToken || null
    });
}

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
        // Note: active stays true until after updateFocus so reportToNative sees isProgrammatic
        state.expectedY = state.targetY; 
        if (state.timeout) clearTimeout(state.timeout);
        state.timeout = null;
        updateFocus(true);
        state.active = false;
        // Note: sticky stays true until next scroll or explicit cancel
        // This allows the focus to remain locked on the target after animation
    };

    const start = (targetId, targetY) => {
        if (pagination.mode === 'pages') {
            navigateToPage(targetY / window.innerHeight, targetId);
            return;
        }
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
        cancel,
        lock: (targetId) => {
            cancel(true);
            state.sticky = true;
            state.targetId = targetId;
            state.expectedY = window.scrollY;
            state.lastSetAt = performance.now();
        },
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

const BLOCK_SELECTOR = '[data-reader-block-id], [id^="block-"]';

function blockIdFromElement(element) {
    if (!element) return null;
    const dataId = parseInt(element.dataset.readerBlockId || "0", 10);
    if (dataId > 0) return dataId;

    const match = element.id?.match(/^block-(\d+)$/);
    if (!match) return null;

    const id = parseInt(match[1], 10);
    return id > 0 ? id : null;
}

function getClosestBlock(element) {
    return element?.closest?.(BLOCK_SELECTOR) || null;
}

function getBlockByIdOrIndex(blockId) {
    const id = parseInt(blockId, 10);
    if (!Number.isInteger(id) || id <= 0) return null;

    const byData = document.querySelector(`[data-reader-block-id="${id}"]`);
    if (byData) return byData;

    const idMatches = Array.from(document.querySelectorAll(`[id="block-${id}"]`));
    const explicitMatch = idMatches.find(element => element.dataset.readerBlockId === String(id));
    if (explicitMatch) return explicitMatch;

    const compatibleMatches = idMatches.filter(element => !element.dataset.readerBlockId);
    return compatibleMatches.length === 1 ? compatibleMatches[0] : null;
}

function getMarkers() {
    const selector = '.annotation-marker, .image-marker, .footnote-ref';
    const markerElements = document.querySelectorAll(selector);
    const scrollY = window.scrollY;
    
    return Array.from(markerElements).map((element, index) => {
        const rect = firstElementRect(element);
        let type = 'annotation';
        if (element.classList.contains('image-marker')) type = 'image';
        else if (element.classList.contains('footnote-ref')) type = 'footnote';

        const id = element.dataset.annotationId || element.dataset.imageId || 
                   (element.getAttribute('href')?.split('#')[1]) || element.id;

        const block = getClosestBlock(element);
        const blockId = blockIdFromElement(block) || parseInt(element.dataset.blockId || "0", 10);

        const pageIndex = pagination.mode === 'pages' ? pageForRect(rect) : null;
        const y = pageIndex === null ? rect.top + scrollY + rect.height * 0.5
            : pageIndex * window.innerHeight + rect.top + rect.height * 0.5;
        return { element, id, type, order: index, blockId, y, pageIndex };
    }).sort((a, b) => (a.y !== b.y) ? a.y - b.y : a.order - b.order);
}

// --- Territory Logic ---

function buildTerritoryMap() {
    const stations = getMarkers();
    const vh = window.innerHeight;
    const sh = pagination.mode === 'pages' ? pagination.pageCount * vh : document.documentElement.scrollHeight;
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

    // Report markers to native
    postToNative({
        type: 'markersUpdated',
        stations: focusState.stations.map(s => ({
            id: String(s.id),
            type: s.type,
            y: s.y,
            blockId: s.blockId
        }))
    });
}

function scheduleMapRebuild() {
    if (isInitializingReader) return;
    if (pagination.mode === 'pages') {
        schedulePageReflow();
        return;
    }
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
    if (pagination.mode === 'pages') {
        updatePageFocus(forceReport);
        return;
    }
    const scrollY = window.scrollY;
    const now = performance.now();
    
    // Ensure map is built if we have no stations, even if a lazy rebuild is pending
    if (!focusState.mapBuilt || (focusState.stations.length === 0 && !focusState.mapPending)) {
        buildTerritoryMap();
    }

    const vh = focusState.viewportHeight || window.innerHeight;
    const sh = focusState.scrollHeight || document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, sh - vh);
    let scrollPercent = scrollMax <= 1 ? 1 : Math.min(1, scrollY / scrollMax);
    // Snap to 1.0 if within 2 pixels of bottom
    if ((scrollMax - scrollY) <= 2) scrollPercent = 1;

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
    // Completion reports still carry isProgrammatic, but must measure the final
    // text position even while the animation controller owns the focus lock.
    if (!isAnimating || forceReport) {
        if (forceReport || Math.abs(scrollY - focusState.lastBlockCheckY) > 20 || focusState.currentBlockIndex === -1) {
            const anchor = captureReadingAnchor();
            if (anchor) {
                activeBlockIndex = anchor.blockId - 1;
                focusState.currentBlockOffset = anchor.offset;
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
        reportToNative(scrollY, scrollPercent, vh, sh, isLocked, hasChangedFocus, shouldForce);
    }

    // 4. Debounced Heartbeat
    if (forceReport || hasChangedFocus || hasChangedBlock || timeSinceLast > 1000) {
        clearTimeout(focusState.idleTimeout);
        focusState.idleTimeout = setTimeout(() => {
            if (pagination.mode === 'pages') return;
            const curY = window.scrollY;
            const curMax = Math.max(1, (focusState.scrollHeight || document.documentElement.scrollHeight) - (focusState.viewportHeight || window.innerHeight));
            if (Math.abs(curY - focusState.lastReportedScrollY) > 5) {
                const curSh = focusState.scrollHeight || document.documentElement.scrollHeight;
                reportToNative(curY, curY / curMax, focusState.viewportHeight || window.innerHeight, curSh, programmatic.isSticky(), false, false);
            }
        }, 1000);
    }
}

/**
 * Optimized bridge communicator with Semantic Diffing
 */
function reportToNative(scrollY, scrollPercent, vh, sh, isLocked, shouldPulse, forceReport) {
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

    postToNative({
        type: 'scrollPosition', annotationId: aId, imageId: iId, footnoteRefId: fId,
        blockId: bId, blockOffset: bOffset, primaryType: s?.type || null, scrollY, scrollPercent: roundedP,
        viewportHeight: vh, viewportWidth: window.innerWidth, scrollHeight: sh,
        isProgrammatic: programmatic.isActive() || (pagination.mode === 'pages' && isLocked),
        ...(pagination.mode === 'pages' ? {
            ...pageMetadata(),
            visibleAnnotationIds: Array.from(new Set(focusState.stations
                .filter(station => station.type === 'annotation' &&
                    station.pageIndex >= pagination.pageIndex &&
                    station.pageIndex < pagination.pageIndex + pagination.capacity &&
                    elementIsOnPage(station.element))
                .map(station => String(station.id)))),
            visibleImageIds: Array.from(new Set(focusState.stations
                .filter(station => station.type === 'image' && elementIsOnPage(station.element))
                .map(station => String(station.id))))
        } : {})
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
    if (pagination.mode !== 'pages') el.classList.add('highlight-active');
    el.style.backgroundColor = 'var(--rose)'; el.style.color = 'var(--base)'; el.style.transition = 'none';
    setTimeout(() => {
        el.style.transition = 'background-color 1.5s ease-out, color 1.5s ease-out';
        el.style.backgroundColor = ''; el.style.color = '';
        setTimeout(() => el.classList.remove('highlight-active'), 1500);
    }, 400);
}

function performSmoothScroll(el, ratio, targetId) {
    if (pagination.mode === 'pages') {
        flushPageReflow();
        const station = focusState.stations.find(s => `${s.type}-${s.id}` === targetId);
        const target = station?.element || el;
        const anchor = anchorForElement(target);
        return navigateToPage(pageForRect(anchorRect(anchor) || firstElementRect(target)), targetId, anchor);
    }
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

function scrollToBlock(id, mId, type, blockOffset, highlight = true) {
    flushPageReflow();
    const b = getBlockByIdOrIndex(id);
    if (!b) return;
    const tId = mId && type ? `${type}-${mId}` : `block-${id}`;
    if (Number.isFinite(blockOffset) && !mId) {
        const anchor = { blockId: Number(id), offset: Math.max(0, Math.min(1, blockOffset)) };
        const rect = anchorRect(anchor);
        if (rect && pagination.mode === 'pages') {
            navigateToPage(pageForRect(rect), tId, anchor);
        } else if (rect) {
            programmatic.start(tId, window.scrollY + rect.top - window.innerHeight * EYE_LINE_RATIO);
        }
    } else {
        performSmoothScroll(b, EYE_LINE_RATIO, tId);
    }
    if (!highlight) return;
    if (mId && type) {
        const m = document.querySelector(`[data-${type}-id="${mId}"]`);
        if (m) highlightMarker(m);
    } else highlightBlock(b);
}

// Saved semantic positions share navigation geometry, not source-jump emphasis.
function restoreReadingLocation(id, blockOffset) {
    scrollToBlock(id, null, null, blockOffset, false);
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
    if (pagination.mode === 'pages') {
        flushPageReflow();
        return navigateToPage(Math.max(0, Math.min(1, p)) * (pagination.pageCount - 1));
    }
    const vh = window.innerHeight;
    const sh = document.documentElement.scrollHeight;
    const scrollMax = Math.max(1, sh - vh);
    programmatic.start(null, scrollMax * p);
}

function scrollToOffset(o) {
    flushPageReflow();
    programmatic.start(null, o);
}

function applyReaderStyle(style) {
    if (!style) return;
    const anchor = pagination.mode === 'pages' ? pagination.anchor : captureReadingAnchor();

    const root = document.documentElement;
    root.style.setProperty('--base', style.themeBase);
    root.style.setProperty('--surface', style.themeSurface);
    root.style.setProperty('--text', style.themeText);
    root.style.setProperty('--muted', style.themeMuted);
    root.style.setProperty('--rose', style.themeRose);
    root.style.setProperty('--iris', style.themeIris);

    document.body.style.fontFamily = `"${style.fontFamily}", sans-serif`;
    document.body.style.fontSize = `${style.fontSize}px`;
    document.body.style.lineHeight = String(style.lineSpacing);

    if (pagination.mode === 'pages') {
        rebuildPages(anchor);
    } else {
        pagination.scrollAnchorY = null;
        const rect = anchorRect(anchor);
        if (rect) window.scrollTo(0, Math.max(0, window.scrollY + rect.top - window.innerHeight * EYE_LINE_RATIO));
        focusState.lastBlockCheckY = -Infinity;
        scheduleMapRebuild();
    }
}

function syncMarkerGroup(items, selector, datasetKey, className) {
    const existing = new Map(
        Array.from(document.querySelectorAll(selector)).map(el => [String(el.dataset[datasetKey]), el])
    );
    const markersByBlock = new Map();

    for (const item of items) {
        const id = String(item[datasetKey]);
        const block = getBlockByIdOrIndex(item.sourceBlockId);
        if (!block) continue;

        let marker = existing.get(id);
        if (!marker) {
            marker = document.createElement('span');
            marker.className = className;
        }

        marker.dataset[datasetKey] = id;
        marker.dataset.blockId = String(item.sourceBlockId);
        existing.delete(id);

        if (!markersByBlock.has(block)) markersByBlock.set(block, []);
        markersByBlock.get(block).push(marker);
    }

    for (const marker of existing.values()) marker.remove();
    for (const [block, markers] of markersByBlock.entries()) {
        for (const marker of markers) block.appendChild(marker);
    }
}

function syncInlineImages(payload) {
    const existingInlineImages = new Map(
        Array.from(document.querySelectorAll('.generated-image[data-inline-image-key]')).map(el => [el.dataset.inlineImageKey, el])
    );

    if (!payload.inlineAIImagesEnabled) {
        for (const image of existingInlineImages.values()) image.remove();
        scheduleMapRebuild();
        return;
    }

    const anchors = new Map();
    for (const image of payload.inlineImages) {
        const block = getBlockByIdOrIndex(image.sourceBlockId);
        if (!block) continue;

        let img = existingInlineImages.get(image.key);
        if (!img) {
            img = document.createElement('img');
            img.className = 'generated-image';
            img.dataset.inlineImageKey = image.key;
        }

        img.dataset.blockId = String(image.sourceBlockId);
        if (image.imageId !== null && image.imageId !== undefined) {
            img.dataset.imageId = String(image.imageId);
        } else {
            delete img.dataset.imageId;
        }
        if (img.src !== image.imageURL) img.src = image.imageURL;
        img.alt = 'AI Image';

        const anchor = anchors.get(image.sourceBlockId) || block;
        if (anchor.nextElementSibling !== img) {
            anchor.insertAdjacentElement('afterend', img);
        }
        anchors.set(image.sourceBlockId, img);
        existingInlineImages.delete(image.key);
    }

    for (const image of existingInlineImages.values()) image.remove();
    scheduleMapRebuild();
}

function syncMarkers(payload) {
    const annotations = Array.isArray(payload?.annotations) ? payload.annotations : [];
    const imageMarkers = Array.isArray(payload?.imageMarkers) ? payload.imageMarkers : [];

    syncMarkerGroup(annotations, '.annotation-marker', 'annotationId', 'annotation-marker');
    syncMarkerGroup(imageMarkers, '.image-marker', 'imageId', 'image-marker');
    scheduleMapRebuild();
}

function syncDecorations(payload) {
    syncMarkers(payload || { annotations: [], imageMarkers: [] });
    syncInlineImages(payload || { inlineAIImagesEnabled: false, inlineImages: [] });
}

// Called by the main-frame document-end user script before the first paint.
// Configure decorations and typography before enabling columns, so the initial
// chapter is laid out once in its actual reading mode rather than flashing scroll.
function initializeReader(style, markers, images, layout, mode) {
    isInitializingReader = true;
    try {
        applyReaderStyle(style);
        syncMarkers(markers);
        syncInlineImages(images);
        setPageLayout(layout);
        setReadingMode(mode);
    } finally {
        isInitializingReader = false;
    }
    if (mode === 'scroll') scheduleMapRebuild();
}

// --- Event Listeners ---

window.addEventListener('scroll', () => {
    if (pagination.mode === 'pages') {
        if (window.scrollX !== 0 || window.scrollY !== 0) renderPage();
        return;
    }
    const sy = window.scrollY;
    focusState.lastVelocity = Math.abs(sy - focusState.lastScrollY);
    focusState.lastScrollY = sy;
    programmatic.noteScroll(sy);
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            if (pagination.mode === 'pages') {
                scrollTicking = false;
                return;
            }
            const sy = window.scrollY;
            updateFocus();
            const max = document.documentElement.scrollHeight - window.innerHeight;
            // Two-step tug: first arrival at bottom doesn't trigger, only deliberate second tug after settling
            if (max > 0 && sy >= max - 1) {
                if (!focusState.reachedBottom) {
                    focusState.reachedBottom = true;
                    focusState.bottomArrivalTime = Date.now();
                }
            } else if (sy < max - 20) {
                focusState.reachedBottom = false;
                focusState.bottomArrivalTime = 0;
            }
            // Only fire tug if settled at bottom for at least 300ms (prevents first-arrival overshoot)
            if (focusState.reachedBottom && sy > max + 5) {
                const timeSinceArrival = Date.now() - focusState.bottomArrivalTime;
                if (timeSinceArrival > 300) {
                    postToNative({ type: 'bottomTug' });
                }
                focusState.reachedBottom = false;
                focusState.bottomArrivalTime = 0;
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
            if (pagination.mode === 'pages' && !rectIsOnPage(r)) continue;
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

// Native reader shortcuts must leave WebKit's selection and embedded EPUB
// editors alone. Report state only; keyboard/navigation still has one owner.
function reportReaderInteractionState() {
    const selection = window.getSelection();
    const active = document.activeElement;
    postToNative({
        type: 'readerInteractionState',
        hasSelection: !!selection && !selection.isCollapsed,
        isEditing: !!active && (active.matches('input, textarea, select') || active.isContentEditable)
    });
}
document.addEventListener('selectionchange', reportReaderInteractionState);
document.addEventListener('focusin', reportReaderInteractionState);
document.addEventListener('focusout', () => {
    queueMicrotask(reportReaderInteractionState);
});

// High-precision Layout Monitoring
const layoutObserver = new ResizeObserver(() => scheduleMapRebuild());
layoutObserver.observe(document.body);
window.addEventListener('resize', scheduleMapRebuild);
document.addEventListener('load', event => {
    if (event.target instanceof HTMLImageElement) scheduleMapRebuild();
}, true);
if (document.fonts) {
    document.fonts.ready.then(scheduleMapRebuild);
    document.fonts.addEventListener('loadingdone', scheduleMapRebuild);
}

// One turn per wheel gesture, including its momentum tail. Keyboard handling is
// deliberately owned by the native reader, not duplicated in the web view.
document.addEventListener('wheel', event => {
    if (pagination.mode !== 'pages' || event.ctrlKey ||
        event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])')) return;
    event.preventDefault();
    clearTimeout(pagination.wheelTimer);
    pagination.wheelTimer = setTimeout(() => {
        pagination.wheelDelta = 0;
        pagination.wheelConsumed = false;
    }, 200);
    if (pagination.wheelConsumed) return;
    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
    const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
    pagination.wheelDelta += delta * scale;
    if (Math.abs(pagination.wheelDelta) < 24) return;
    pagination.wheelConsumed = true;
    turnPage(Math.sign(pagination.wheelDelta));
}, { passive: false });

document.addEventListener('click', e => {
    const t = e.target;
    if (pagination.mode === 'pages') {
        const marker = t.closest('.annotation-marker, .image-marker, .footnote-ref');
        if (marker) {
            const type = marker.classList.contains('annotation-marker') ? 'annotation'
                : marker.classList.contains('image-marker') ? 'image' : 'footnote';
            const id = marker.dataset.annotationId || marker.dataset.imageId || marker.getAttribute('href')?.split('#')[1];
            programmatic.lock(`${type}-${id}`);
            pagination.anchor = anchorForElement(marker);
            pagination.needsAnchor = false;
            updateFocus(true);
        }
        const link = t.closest('a[href]');
        const href = link?.getAttribute('href');
        const isSameDocument = link && link.origin === location.origin &&
            link.pathname === location.pathname && link.search === location.search;
        if (href?.startsWith('#') || (isSameDocument && link.hash)) {
            const fragment = href.startsWith('#') ? href.slice(1) : link.hash.slice(1);
            let id = fragment;
            try { id = decodeURIComponent(fragment); } catch { /* EPUBs may contain literal percent signs in IDs. */ }
            const target = document.getElementById(id);
            if (target) {
                e.preventDefault();
                performSmoothScroll(target, EYE_LINE_RATIO, null);
            }
        }
    }
    if (t.classList.contains('annotation-marker')) postToNative({ type: 'annotationClick', id: t.dataset.annotationId });
    if (t.classList.contains('image-marker')) postToNative({ type: 'imageMarkerClick', id: t.dataset.imageId });
});

document.addEventListener('dblclick', e => {
    if (e.target.classList.contains('image-marker')) postToNative({ type: 'imageMarkerDblClick', id: e.target.dataset.imageId });
});

document.addEventListener('mouseup', e => {
    setTimeout(() => {
        const sel = window.getSelection();
        const text = sel.toString().trim();
        const popup = document.getElementById('wordPopup');
        if (!sel.isCollapsed && text) {
            const container = sel.getRangeAt(0).startContainer.parentElement;
            // OPTIMIZED O(1) Lookup
            const block = getClosestBlock(container);
            const bId = blockIdFromElement(block) || 1;
            popup.style.left = e.clientX + 'px'; popup.style.top = (e.clientY + 10) + 'px'; popup.style.display = 'block';
            window.selectedWord = text; window.selectedBlockId = bId; window.selectedContext = container.textContent;
        } else if (!e.target.closest('.word-popup')) popup.style.display = 'none';
    }, 20);
});

document.addEventListener('mousedown', e => { if (!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display = 'none'; });

function handleExplain() { 
    postToNative({ type: 'explain', word: window.selectedWord, context: window.selectedContext, blockId: window.selectedBlockId });
    document.getElementById('wordPopup').style.display = 'none'; 
}

function handleGenerateImage() { 
    postToNative({ type: 'generateImage', word: window.selectedWord, context: window.selectedContext, blockId: window.selectedBlockId });
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

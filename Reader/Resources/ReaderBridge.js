const focusState = { 
    isProgrammaticScroll: false, 
    lastTargetId: null, 
    targetY: null,
    timeout: null,
    reachedBottom: false,
    lastScrollY: 0,
    lastVelocity: 0,
    activeIds: { annotation: null, image: null, footnote: null },
    primaryKey: null
};
let scrollTicking = false;

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

function parseTargetId() {
    if (!focusState.isProgrammaticScroll || !focusState.lastTargetId) return null;
    const dashIndex = focusState.lastTargetId.indexOf("-");
    if (dashIndex <= 0) return null;
    return {
        type: focusState.lastTargetId.slice(0, dashIndex),
        id: focusState.lastTargetId.slice(dashIndex + 1)
    };
}

function preferredIdForType(type) {
    const parsed = parseTargetId();
    if (!parsed || parsed.type !== type) return null;
    return parsed.id;
}

function blockIdForElement(el) {
    if (el.dataset.blockId) {
        const parsed = parseInt(el.dataset.blockId, 10);
        return Number.isFinite(parsed) ? parsed : null;
    }
    const block = el.closest('[id^="block-"]');
    if (!block) return null;
    const raw = block.id.replace("block-", "");
    const parsed = parseInt(raw, 10);
    if (Number.isFinite(parsed)) {
        el.dataset.blockId = String(parsed);
        return parsed;
    }
    return null;
}

function computeVirtualPositions(items, minSpacing, minBound, maxBound) {
    const ordered = items.slice().sort((a, b) => (a.y - b.y) || (a.order - b.order));
    if (ordered.length <= 1) {
        if (ordered[0]) {
            const clamped = Math.min(maxBound, Math.max(minBound, ordered[0].y));
            ordered[0].virtualY = clamped;
        }
        return ordered;
    }

    const minY = ordered[0].y;
    const maxY = ordered[ordered.length - 1].y;
    const span = Math.max(1, maxY - minY);
    const requiredSpan = minSpacing * Math.max(1, ordered.length - 1);
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
    targetMin = Math.min(targetMin, targetMax);
    targetMax = Math.max(targetMin, targetMax);

    const v = ordered.map(item => item.y);
    v[0] = Math.max(v[0], targetMin);
    for (let i = 1; i < v.length; i++) {
        v[i] = Math.max(v[i], v[i - 1] + minSpacing);
    }
    if (v[v.length - 1] > targetMax) v[v.length - 1] = targetMax;
    for (let i = v.length - 2; i >= 0; i--) {
        v[i] = Math.min(v[i], v[i + 1] - minSpacing);
    }
    if (v[0] < targetMin) {
        const shift = targetMin - v[0];
        for (let i = 0; i < v.length; i++) v[i] += shift;
        const overshoot = v[v.length - 1] - targetMax;
        if (overshoot > 0) {
            for (let i = 0; i < v.length; i++) v[i] -= overshoot;
        }
    }

    for (let i = 0; i < ordered.length; i++) {
        ordered[i].virtualY = Math.min(maxBound, Math.max(minBound, v[i]));
    }
    return ordered;
}

function selectMarker(items, focusLine, minSpacing, maxDistance, lastKey, preferredKey, keyForItem) {
    if (items.length === 0) return null;
    if (preferredKey) {
        const preferred = items.find(item => keyForItem(item) === preferredKey);
        if (preferred) {
            const preferredY = preferred.virtualY ?? preferred.y;
            preferred.distance = Math.abs(preferredY - focusLine);
            return preferred;
        }
    }

    const ordered = items.slice().sort((a, b) => {
        const aY = a.virtualY ?? a.y;
        const bY = b.virtualY ?? b.y;
        return (aY - bY) || (a.order - b.order);
    });
    let best = ordered[0];
    best.distance = Math.abs((best.virtualY ?? best.y) - focusLine);
    for (const item of ordered) {
        const distance = Math.abs((item.virtualY ?? item.y) - focusLine);
        item.distance = distance;
        if (distance < best.distance - 0.5) {
            best = item;
        }
    }
    if (best.distance > maxDistance) return null;

    if (lastKey) {
        const lastItem = ordered.find(item => keyForItem(item) === lastKey);
        if (lastItem) {
            const lastIndex = ordered.indexOf(lastItem);
            const prev = lastIndex > 0 ? ordered[lastIndex - 1] : null;
            const next = lastIndex < ordered.length - 1 ? ordered[lastIndex + 1] : null;
            const lastY = lastItem.virtualY ?? lastItem.y;
            const lower = prev ? ((prev.virtualY ?? prev.y) + lastY) * 0.5 : -Infinity;
            const upper = next ? ((next.virtualY ?? next.y) + lastY) * 0.5 : Infinity;
            const margin = Math.max(26, minSpacing * 0.32);
            if (focusLine >= lower - margin && focusLine <= upper + margin) {
                return lastItem;
            }
        }
    }

    return best;
}

function pulseMarker(el) {
    if (!el) return;
    const isImage = el.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    el.style.setProperty('--highlight-color', 'var(' + colorVar + ')');
    el.classList.remove('marker-pulse');
    void el.offsetWidth; // Force reflow
    el.classList.add('marker-pulse');
    setTimeout(() => el.classList.remove('marker-pulse'), 650);
}

function setProgrammaticScroll(targetId, targetY) {
    focusState.isProgrammaticScroll = true;
    focusState.lastTargetId = targetId;
    focusState.targetY = targetY;
    if (focusState.timeout) clearTimeout(focusState.timeout);
    focusState.timeout = setTimeout(() => {
        focusState.isProgrammaticScroll = false;
    }, 1500); 
}

function performSmoothScroll(element, ratio, targetId) {
    const rect = element.getBoundingClientRect();
    const target = window.scrollY + rect.top - (window.innerHeight * ratio);
    const finalTarget = Math.max(0, target);
    setProgrammaticScroll(targetId, finalTarget);
    window.scrollTo({ top: finalTarget, behavior: 'smooth' });
}

function highlightElement(el, colorVar) {
    if (!el) return;
    el.classList.add('highlight-active');
    el.style.backgroundColor = 'var(' + colorVar + ')';
    setTimeout(() => {
        el.style.transition = 'background-color 1.0s ease-out';
        el.style.backgroundColor = '';
        setTimeout(() => {
            el.classList.remove('highlight-active');
            el.style.transition = '';
        }, 1000);
    }, 400);
}

function highlightMarker(el) {
    if (!el) return;
    const isImage = el.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    el.classList.add('marker-highlight');
    el.style.setProperty('--highlight-color', 'var(' + colorVar + ')');
    setTimeout(() => el.classList.remove('marker-highlight'), 1500);
}

function scrollToAnnotation(id) {
    const el = document.querySelector('[data-annotation-id="' + id + '"]');
    if (el) {
        performSmoothScroll(el, 0.4, 'annotation-' + id);
        highlightMarker(el);
    }
}

function scrollToBlock(id, markerId, type) {
    const blocks = getBlocks();
    if (id > 0 && id <= blocks.length) {
        const block = blocks[id-1];
        performSmoothScroll(block, 0.4, 'block-' + id);
        if (markerId && type) {
            const m = document.querySelector('[data-' + type + '-id="' + markerId + '"]');
            if (m) highlightMarker(m);
        } else {
            highlightElement(block, '--rose');
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

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;
    const velocity = Math.abs(scrollY - focusState.lastScrollY);
    focusState.lastVelocity = velocity;
    focusState.lastScrollY = scrollY;

    if (focusState.isProgrammaticScroll && focusState.targetY !== null) {
        if (Math.abs(scrollY - focusState.targetY) < 3) {
            focusState.isProgrammaticScroll = false;
            if (focusState.timeout) clearTimeout(focusState.timeout);
        }
    }
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            const viewportHeight = window.innerHeight;
            const scrollMax = document.documentElement.scrollHeight - viewportHeight;
            
            updateFocus();
            
            if (scrollMax > 0) {
                const atAbsoluteBottom = scrollY >= scrollMax - 1;
                if (atAbsoluteBottom) {
                    focusState.reachedBottom = true;
                } else if (scrollY < scrollMax - 20) {
                    focusState.reachedBottom = false;
                }
                
                if (focusState.reachedBottom && scrollY > scrollMax + 5) {
                    webkit.messageHandlers.readerBridge.postMessage({type:'bottomTug'});
                    focusState.reachedBottom = false; 
                }
            }
            
            scrollTicking = false;
        });
    }
});

function updateFocus() {
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const scrollMax = document.documentElement.scrollHeight - viewportHeight;
    const scrollPercent = scrollMax > 0 ? (scrollY / scrollMax) : 0;
    const minSpacing = Math.max(140, viewportHeight * 0.22);
    
    // 1. Adaptive Eye Line (0.0 -> 0.4 -> 1.0)
    const edgeThreshold = viewportHeight * 0.6;
    let eyeRatio = 0.45;
    if (scrollY < edgeThreshold) {
        const t = Math.max(0, Math.min(1, scrollY / edgeThreshold));
        const pull = (1 - t) * 0.12;
        eyeRatio = 0.45 - pull;
    } else if (scrollY > scrollMax - edgeThreshold) {
        const t = Math.max(0, Math.min(1, (scrollY - (scrollMax - edgeThreshold)) / edgeThreshold));
        const pull = t * 0.18;
        eyeRatio = 0.45 + pull;
    }
    let focusLine = scrollY + (eyeRatio * viewportHeight);
    const isFlying = focusState.lastVelocity > 40;

    // 2. Block Tracking
    const blocks = getBlocks();
    let activeBlockIndex = -1;
    let minBlockDist = Infinity;
    blocks.forEach((block, index) => {
        const rect = block.getBoundingClientRect();
        const top = rect.top + scrollY, bottom = rect.bottom + scrollY;
        let dist = (focusLine >= top && focusLine <= bottom) ? 0 : Math.min(Math.abs(top - focusLine), Math.abs(bottom - focusLine));
        if (dist < minBlockDist) { minBlockDist = dist; activeBlockIndex = index; }
    });

    const edgeZone = 0.08;
    const topFactor = scrollPercent < edgeZone ? 1 - (scrollPercent / edgeZone) : 0;
    const bottomFactor = scrollPercent > 1 - edgeZone ? 1 - ((1 - scrollPercent) / edgeZone) : 0;
    const extraTop = topFactor * Math.max(24, minSpacing * 0.35);
    const extraBottom = bottomFactor * Math.max(60, minSpacing * 0.9);
    const edgeBand = Math.max(minSpacing * 0.6, viewportHeight * 0.12);
    if (topFactor > 0) {
        focusLine = Math.min(focusLine, scrollY + edgeBand);
    }
    if (bottomFactor > 0) {
        focusLine = Math.max(focusLine, scrollY + viewportHeight - edgeBand);
    }

    const markers = getMarkers();
    if (markers.length === 0) {
        sendScrollMessage(null, null, null, activeBlockIndex + 1, null, null, null, null, null, null, scrollY, scrollPercent, viewportHeight, focusState.isProgrammaticScroll);
        return;
    }

    // 3. Marker selection (visible + proximity to focus line)
    const markerData = markers.map((m, index) => {
        const rect = m.getBoundingClientRect();
        const type = m.classList.contains('annotation-marker') ? 'annotation' : (m.classList.contains('image-marker') ? 'image' : 'footnote');
        const id = m.dataset.annotationId || m.dataset.imageId || (type === 'footnote' ? (m.getAttribute('href')?.split('#')[1] || m.id) : null);
        return {
            el: m,
            id,
            type,
            order: index,
            y: rect.top + scrollY + (rect.height * 0.5),
            isVisible: isVisibleWithMargin(rect, viewportHeight, extraTop, extraBottom),
            blockId: blockIdForElement(m)
        };
    });

    const byType = { annotation: [], image: [], footnote: [] };
    for (const marker of markerData) {
        if (marker.id) {
            byType[marker.type].push(marker);
        }
    }

    const maxDistance = selectionThreshold(scrollPercent, viewportHeight);
    const prevActive = { ...focusState.activeIds };
    const keyForType = (item) => item.id;

    const visibleAll = markerData.filter(item => item.id && item.isVisible);
    const virtualMax = scrollMax + viewportHeight;
    if (visibleAll.length > 0) {
        computeVirtualPositions(visibleAll, minSpacing, 0, virtualMax);
    }

    const selectForType = (type, items) => {
        const visible = items.filter(item => item.isVisible);
        if (visible.length === 0) return null;
        const preferredId = preferredIdForType(type);
        const lastId = focusState.activeIds[type];
        return selectMarker(visible, focusLine, minSpacing, maxDistance, lastId, preferredId, keyForType);
    };

    const bestA = selectForType('annotation', byType.annotation);
    const bestI = selectForType('image', byType.image);
    const bestF = selectForType('footnote', byType.footnote);
    const parsedTarget = parseTargetId();
    const preferredPrimary = parsedTarget ? `${parsedTarget.type}:${parsedTarget.id}` : null;
    const primary = selectMarker(
        visibleAll,
        focusLine,
        minSpacing,
        maxDistance,
        focusState.primaryKey,
        preferredPrimary,
        (item) => `${item.type}:${item.id}`
    );

    // 4. Visual Pulse on Commitment
    if (!isFlying && !focusState.isProgrammaticScroll) {
        if (bestA && bestA.id !== prevActive.annotation) pulseMarker(bestA.el);
        if (bestI && bestI.id !== prevActive.image) pulseMarker(bestI.el);
        if (bestF && bestF.id !== prevActive.footnote) pulseMarker(bestF.el);
    }

    focusState.activeIds = { annotation: bestA?.id || null, image: bestI?.id || null, footnote: bestF?.id || null };
    focusState.primaryKey = primary ? `${primary.type}:${primary.id}` : null;

    // 5. Stable Delivery
    sendScrollMessage(
        bestA?.id || null,
        bestI?.id || null,
        bestF?.id || null,
        activeBlockIndex + 1,
        bestA ? bestA.distance : null,
        bestI ? bestI.distance : null,
        bestF ? bestF.distance : null,
        bestA?.blockId || null,
        bestI?.blockId || null,
        bestF?.blockId || null,
        primary?.type || null,
        scrollY,
        scrollPercent,
        viewportHeight,
        focusState.isProgrammaticScroll
    );
}

const selectionOverlay = document.getElementById('selectionOverlay');

function clearSelectionOverlay() {
    if (!selectionOverlay) return;
    selectionOverlay.innerHTML = '';
}

function updateSelectionOverlay() {
    if (!selectionOverlay) return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
        clearSelectionOverlay();
        return;
    }

    const range = sel.getRangeAt(0);
    const rects = Array.from(range.getClientRects()).filter(r => r.width > 0 && r.height > 0);
    
    clearSelectionOverlay();
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
window.addEventListener('resize', updateSelectionOverlay);

function sendScrollMessage(aId, iId, fId, bId, aD, iD, fD, aB, iB, fB, pT, sY, sP, vH, isP) {
    const isArrival = (focusState.lastTargetId === 'annotation-' + aId) || 
                      (focusState.lastTargetId === 'image-' + iId) ||
                      (focusState.lastTargetId === 'footnote-' + fId) ||
                      (focusState.lastTargetId === 'block-' + bId);
    
    if (focusState.isProgrammaticScroll && isArrival) {
        focusState.isProgrammaticScroll = false;
        if (focusState.timeout) clearTimeout(focusState.timeout);
    }

    webkit.messageHandlers.readerBridge.postMessage({
        type: 'scrollPosition',
        annotationId: aId, imageId: iId, footnoteRefId: fId, blockId: bId,
        annotationDist: aD, imageDist: iD, footnoteDist: fD,
        annotationBlockId: aB, imageBlockId: iB, footnoteBlockId: fB,
        primaryType: pT,
        scrollY: sY, scrollPercent: sP, viewportHeight: vH,
        isProgrammatic: isP
    });
}

function scrollToPercent(p) { const m = document.documentElement.scrollHeight - window.innerHeight; window.scrollTo({top: m * p, behavior:'auto'}); }
function scrollToOffset(o) { window.scrollTo({top: o, behavior:'auto'}); }

function injectMarkerAtBlock(aId, bId) {
    const blocks = getBlocks();
    if (bId > 0 && bId <= blocks.length) {
        const block = blocks[bId-1];
        const marker = document.createElement('span');
        marker.className = 'annotation-marker';
        marker.dataset.annotationId = aId;
        marker.dataset.blockId = bId;
        block.appendChild(marker);
    }
}

function injectImageMarker(iId, bId) {
    const blocks = getBlocks();
    if (bId > 0 && bId <= blocks.length) {
        const block = blocks[bId-1];
        const marker = document.createElement('span');
        marker.className = 'image-marker';
        marker.dataset.imageId = iId;
        marker.dataset.blockId = bId;
        block.appendChild(marker);
    }
}

document.addEventListener('click', e => {
    const m = e.target;
    if (m.classList.contains('annotation-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'annotationClick', id: m.dataset.annotationId});
    if (m.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerClick', id: m.dataset.imageId});
});

document.addEventListener('dblclick', e => {
    const m = e.target;
    if (m.classList.contains('image-marker')) {
        webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerDblClick', id: m.dataset.imageId});
    }
});

document.addEventListener('mouseup', e => {
    // Small delay to ensure selection state is updated by the browser
    setTimeout(() => {
        const sel = window.getSelection();
        const txt = sel.toString().trim();
        const p = document.getElementById('wordPopup');
        
        if (!sel.isCollapsed && txt) {
            const range = sel.getRangeAt(0);
            const container = range.startContainer.parentElement;
            const blocks = getBlocks();
            let bId = 1;
            for(let i=0; i<blocks.length; i++) { if(blocks[i].contains(container)) { bId = i+1; break; } }
            
            p.style.left = e.clientX+'px'; p.style.top = (e.clientY+10)+'px'; p.style.display = 'block';
            window.selectedWord = txt; window.selectedBlockId = bId; window.selectedContext = container.textContent;
        } else {
            if (!e.target.closest('.word-popup')) {
                p.style.display = 'none';
            }
        }
    }, 20);
});
document.addEventListener('mousedown', e => { if(!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display='none'; });
function handleExplain() { webkit.messageHandlers.readerBridge.postMessage({type:'explain', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }
function handleGenerateImage() { webkit.messageHandlers.readerBridge.postMessage({type:'generateImage', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }

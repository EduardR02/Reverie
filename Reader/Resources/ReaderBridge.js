const focusState = { 
    isProgrammaticScroll: false, 
    lastTargetId: null, 
    targetY: null,
    timeout: null 
};
let scrollTicking = false;

function getBlocks() {
    return Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li'));
}

function getMarkers() {
    return Array.from(document.querySelectorAll('.annotation-marker, .image-marker, .footnote-ref'));
}

function setProgrammaticScroll(targetId, targetY) {
    focusState.isProgrammaticScroll = true;
    focusState.lastTargetId = targetId;
    focusState.targetY = targetY;
    if (focusState.timeout) clearTimeout(focusState.timeout);
    focusState.timeout = setTimeout(() => {
        focusState.isProgrammaticScroll = false;
    }, 1200);
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
    const originalBg = el.style.backgroundColor;
    const originalTransition = el.style.transition;
    
    el.style.transition = 'none';
    el.style.backgroundColor = 'var(' + colorVar + ')';
    el.style.opacity = '0.6';
    el.offsetHeight; // Force reflow
    
    setTimeout(() => {
        el.style.transition = 'background-color 0.6s ease-out, opacity 0.6s ease-out';
        el.style.backgroundColor = originalBg;
        el.style.opacity = '1';
        setTimeout(() => {
            el.style.transition = originalTransition;
        }, 600);
    }, 200);
}

function highlightMarker(el) {
    if (!el) return;
    const isImage = el.classList.contains('image-marker');
    const colorVar = isImage ? '--iris' : '--rose';
    const originalBg = el.style.backgroundColor;
    const originalTransform = el.style.transform;
    const originalBoxShadow = el.style.boxShadow;
    const originalZIndex = el.style.zIndex;
    
    el.style.transition = 'transform 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275), box-shadow 0.4s, background-color 0.2s';
    el.style.transform = 'scale(1.6)';
    el.style.backgroundColor = 'var(' + colorVar + ')';
    el.style.boxShadow = '0 0 20px 5px var(' + colorVar + ')';
    el.style.zIndex = '100';
    
    setTimeout(() => {
        el.style.transform = originalTransform;
        el.style.backgroundColor = originalBg;
        el.style.boxShadow = originalBoxShadow;
        setTimeout(() => { el.style.zIndex = originalZIndex; }, 400);
    }, 1200);
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

window.addEventListener('scroll', () => {
    if (focusState.isProgrammaticScroll && focusState.targetY !== null) {
        if (Math.abs(window.scrollY - focusState.targetY) < 2) {
            focusState.isProgrammaticScroll = false;
            if (focusState.timeout) clearTimeout(focusState.timeout);
        }
    }
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            updateFocus();
            const scrollMax = document.documentElement.scrollHeight - window.innerHeight;
            if (scrollMax > 0 && window.scrollY > scrollMax + 40) {
                webkit.messageHandlers.readerBridge.postMessage({type:'bottomTug'});
            }
            scrollTicking = false;
        });
    }
});

function updateFocus() {
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const scrollMax = document.documentElement.scrollHeight - viewportHeight;
    
    // Adaptive focus line: moves toward edges at scroll boundaries
    let focusRatio = 0.4;
    const scrollPercent = scrollMax > 0 ? (scrollY / scrollMax) : 0;
    if (scrollPercent < 0.05) focusRatio = 0.1;
    else if (scrollPercent > 0.95) focusRatio = 0.9;
    const focusLine = scrollY + (viewportHeight * focusRatio);
    
    const blocks = getBlocks();
    let activeBlockIndex = -1;
    let minBlockDist = Infinity;

    blocks.forEach((block, index) => {
        const rect = block.getBoundingClientRect();
        const top = rect.top + scrollY;
        const bottom = rect.bottom + scrollY;
        
        let dist = (focusLine >= top && focusLine <= bottom) ? 0 : Math.min(Math.abs(top - focusLine), Math.abs(bottom - focusLine));
        
        if (dist < minBlockDist) {
            minBlockDist = dist;
            activeBlockIndex = index;
        }
    });

    const markers = getMarkers();
    let gADist = Infinity, gIDist = Infinity, gFDist = Infinity;
    let bestA = null, minADist = Infinity;
    let bestI = null, minIDist = Infinity;
    let bestF = null, minFDist = Infinity;

    // Track the "overall" best candidates regardless of block
    // but within a reasonable distance (e.g. half viewport)
    const visibilityThreshold = viewportHeight * 0.6;

    markers.forEach(m => {
        const rect = m.getBoundingClientRect();
        const markerY = rect.top + scrollY;
        const dist = Math.abs(markerY - focusLine);

        // Global distances for tab-switching logic
        if (m.classList.contains('annotation-marker')) gADist = Math.min(gADist, dist);
        else if (m.classList.contains('image-marker')) gIDist = Math.min(gIDist, dist);
        else if (m.classList.contains('footnote-ref')) gFDist = Math.min(gFDist, dist);

        // Individual best selection
        if (dist < visibilityThreshold) {
            if (m.dataset.annotationId && dist < minADist) {
                bestA = m.dataset.annotationId;
                minADist = dist;
            }
            if (m.dataset.imageId && dist < minIDist) {
                bestI = m.dataset.imageId;
                minIDist = dist;
            }
            if (m.classList.contains('footnote-ref') && dist < minFDist) {
                const href = m.getAttribute('href') || '';
                bestF = href.split('#')[1] || m.id;
                minFDist = dist;
            }
        }
    });

    if (activeBlockIndex !== -1) {
        const blockId = activeBlockIndex + 1;

        const isArrival = (focusState.lastTargetId === 'annotation-' + bestA) || 
                          (focusState.lastTargetId === 'image-' + bestI) ||
                          (focusState.lastTargetId === 'footnote-' + bestF) ||
                          (focusState.lastTargetId === 'block-' + blockId);
        
        if (focusState.isProgrammaticScroll && isArrival) {
            focusState.isProgrammaticScroll = false;
            if (focusState.timeout) clearTimeout(focusState.timeout);
        }

        if (!focusState.isProgrammaticScroll || isArrival) {
            webkit.messageHandlers.readerBridge.postMessage({
                type: 'scrollPosition',
                annotationId: bestA, 
                imageId: bestI, 
                footnoteRefId: bestF, 
                blockId: blockId,
                annotationDist: gADist, 
                imageDist: gIDist, 
                footnoteDist: gFDist,
                scrollY: scrollY, 
                scrollPercent: scrollPercent,
                viewportHeight: viewportHeight
            });
        }
    }
}

document.addEventListener('click', e => {
    const m = e.target;
    if (m.classList.contains('annotation-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'annotationClick', id: m.dataset.annotationId});
    if (m.classList.contains('image-marker')) webkit.messageHandlers.readerBridge.postMessage({type:'imageMarkerClick', id: m.dataset.imageId});
});

document.addEventListener('mouseup', e => {
    const sel = window.getSelection();
    const txt = sel.toString().trim();
    if (!sel.isCollapsed && txt) {
        const range = sel.getRangeAt(0);
        const container = range.startContainer.parentElement;
        const blocks = getBlocks();
        let bId = 1;
        for(let i=0; i<blocks.length; i++) { if(blocks[i].contains(container)) { bId = i+1; break; } }
        const p = document.getElementById('wordPopup');
        p.style.left = e.clientX+'px'; p.style.top = (e.clientY+10)+'px'; p.style.display = 'block';
        window.selectedWord = txt; window.selectedBlockId = bId; window.selectedContext = container.textContent;
    }
});
document.addEventListener('mousedown', e => { if(!e.target.closest('.word-popup')) document.getElementById('wordPopup').style.display='none'; });
function handleExplain() { webkit.messageHandlers.readerBridge.postMessage({type:'explain', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }
function handleGenerateImage() { webkit.messageHandlers.readerBridge.postMessage({type:'generateImage', word:window.selectedWord, context:window.selectedContext, blockId:window.selectedBlockId}); document.getElementById('wordPopup').style.display = 'none'; }
function scrollToPercent(p) { const m = document.documentElement.scrollHeight - window.innerHeight; window.scrollTo({top: m * p, behavior:'auto'}); }
function scrollToOffset(o) { window.scrollTo({top: o, behavior:'auto'}); }
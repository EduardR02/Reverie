const focusState = { 
    isProgrammaticScroll: false, 
    lastTargetId: null, 
    targetY: null,
    timeout: null,
    reachedBottom: false
};
let scrollTicking = false;

function getBlocks() {
    return Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, blockquote, li'));
}

function getMarkers() {
    // Return all markers in DOM order
    return Array.from(document.querySelectorAll('.annotation-marker, .image-marker, .footnote-ref'));
}

function setProgrammaticScroll(targetId, targetY) {
    focusState.isProgrammaticScroll = true;
    focusState.lastTargetId = targetId;
    focusState.targetY = targetY;
    if (focusState.timeout) clearTimeout(focusState.timeout);
    focusState.timeout = setTimeout(() => {
        focusState.isProgrammaticScroll = false;
    }, 1500); // Slightly longer to ensure smooth arrival
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
    
    setTimeout(() => {
        el.classList.remove('marker-highlight');
    }, 1500);
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
    if (focusState.isProgrammaticScroll && focusState.targetY !== null) {
        if (Math.abs(window.scrollY - focusState.targetY) < 3) {
            focusState.isProgrammaticScroll = false;
            if (focusState.timeout) clearTimeout(focusState.timeout);
        }
    }
    if (!scrollTicking) {
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            const scrollY = window.scrollY;
            const viewportHeight = window.innerHeight;
            const scrollMax = document.documentElement.scrollHeight - viewportHeight;
            
            updateFocus();
            
            // Refined bottom tug: Must reach bottom first, then scroll further
            if (scrollMax > 0) {
                const atAbsoluteBottom = scrollY >= scrollMax - 1;
                if (atAbsoluteBottom) {
                    focusState.reachedBottom = true;
                } else if (scrollY < scrollMax - 20) {
                    focusState.reachedBottom = false;
                }
                
                // If we are latched to bottom and user tries to scroll more
                if (focusState.reachedBottom && scrollY > scrollMax + 5) {
                    webkit.messageHandlers.readerBridge.postMessage({type:'bottomTug'});
                    focusState.reachedBottom = false; // Trigger once, reset latch
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
    
    // THE ADAPTIVE EYE LINE (First Principle Solution)
    // eyeRatio moves from 0 (start) -> 0.4 (stable) -> 1.0 (end)
    // The transition happens over 40% of a viewport's height of scrolling.
    const edgeThreshold = viewportHeight * 0.4;
    let eyeRatio = 0.4;
    if (scrollY < edgeThreshold) {
        eyeRatio = (scrollY / edgeThreshold) * 0.4;
    } else if (scrollY > scrollMax - edgeThreshold) {
        const over = scrollY - (scrollMax - edgeThreshold);
        eyeRatio = 0.4 + (over / edgeThreshold) * 0.6;
    }
    
    // The absolute coordinate we are "reading" right now.
    const focusLine = scrollY + (eyeRatio * viewportHeight);
    
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
    if (markers.length === 0) {
        sendScrollMessage(null, null, null, activeBlockIndex + 1, Infinity, Infinity, Infinity, scrollY, scrollPercent, viewportHeight);
        return;
    }

    // 1. Calculate physical positions and metadata
    const markerData = markers.map((m) => {
        const rect = m.getBoundingClientRect();
        return {
            el: m,
            y: rect.top + scrollY,
            // Visibility is the ultimate gate for highlight/expansion
            isVisible: rect.top >= -20 && rect.bottom <= viewportHeight + 20,
            id: m.dataset.annotationId || m.dataset.imageId || (m.classList.contains('footnote-ref') ? (m.getAttribute('href')?.split('#')[1] || m.id) : null),
            type: m.classList.contains('annotation-marker') ? 'annotation' : (m.classList.contains('image-marker') ? 'image' : 'footnote')
        };
    });

    // 2. Sort by Y then DOM order
    markerData.sort((a, b) => (a.y - b.y) || (markers.indexOf(a.el) - markers.indexOf(b.el)));

    // 3. Localized Virtual Spacing: 50px for colliding markers
    const spacing = 50;
    for (let i = 0; i < markerData.length; i++) {
        if (i === 0) {
            markerData[i].virtualY = markerData[i].y;
        } else {
            if (markerData[i].y < markerData[i-1].virtualY + 10) {
                markerData[i].virtualY = markerData[i-1].virtualY + spacing;
            } else {
                markerData[i].virtualY = markerData[i].y;
            }
        }
    }

    // 4. Visibility-Gated Ordinal Selection
    const findActive = (type) => {
        const filtered = markerData.filter(m => m.type === type);
        let candidate = null;
        for (let i = 0; i < filtered.length; i++) {
            const m = filtered[i];
            if (m.isVisible && focusLine >= m.virtualY - 10) {
                candidate = m;
            }
        }
        return candidate;
    };

    const bestA = findActive('annotation');
    const bestI = findActive('image');
    const bestF = findActive('footnote');

    const getVDist = (m) => m ? Math.abs(m.virtualY - focusLine) : Infinity;

    sendScrollMessage(
        bestA?.id, bestI?.id, bestF?.id, 
        activeBlockIndex + 1, 
        getVDist(bestA), getVDist(bestI), getVDist(bestF), 
        scrollY, scrollPercent, viewportHeight
    );
}

function sendScrollMessage(aId, iId, fId, bId, aD, iD, fD, sY, sP, vH) {
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
        scrollY: sY, scrollPercent: sP, viewportHeight: vH,
        isProgrammatic: focusState.isProgrammaticScroll
    });
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
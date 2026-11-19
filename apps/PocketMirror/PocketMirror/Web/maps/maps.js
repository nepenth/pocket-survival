/* Offline map: stacked Protomaps PMTiles layers (Leaflet + protomaps-leaflet, Canvas, no WebGL)
   and the phone's GPS position. Written for Safari 14: no syntax newer than ES2019. */
(function () {
  'use strict';

  var VIEW_KEY = 'pocketMirror.mapView';
  var darkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  var statusEl = document.getElementById('status');
  var coordsEl = document.getElementById('coords');
  var locateBtn = document.getElementById('locate');

  function setStatus(text) { statusEl.textContent = text; }

  function dms(value, pos, neg) {
    var hemi = value >= 0 ? pos : neg;
    var v = Math.abs(value), d = Math.floor(v), mFloat = (v - d) * 60, m = Math.floor(mFloat);
    var s = ((mFloat - m) * 60).toFixed(1);
    return d + '°' + m + '′' + s + '″' + hemi;
  }

  function formatLatLng(lat, lng) {
    return lat.toFixed(5) + ', ' + lng.toFixed(5) + '  (' + dms(lat, 'N', 'S') + ' ' + dms(lng, 'E', 'W') + ')';
  }

  function loadView() {
    try { return JSON.parse(localStorage.getItem(VIEW_KEY) || 'null'); } catch (e) { return null; }
  }
  function saveView(map) {
    try {
      var c = map.getCenter();
      localStorage.setItem(VIEW_KEY, JSON.stringify({ lat: c.lat, lng: c.lng, zoom: map.getZoom() }));
    } catch (e) { /* storage may be unavailable */ }
  }

  function boundsOf(layer) {
    var b = layer.bbox; // [west, south, east, north]
    return L.latLngBounds([[b[1], b[0]], [b[3], b[2]]]);
  }
  function areaOf(layer) {
    var b = layer.bbox;
    return (b[2] - b[0]) * (b[3] - b[1]);
  }

  fetch('/maps/maps.json', { cache: 'no-store' })
    .then(function (r) { if (!r.ok) throw new Error('missing'); return r.json(); })
    .then(start)
    .catch(function () { document.getElementById('notice').hidden = false; });

  function start(manifest) {
    // Largest area at the bottom, most detailed on top: each layer only draws inside its own box,
    // so the detailed map covers the backdrop where it exists.
    var layers = manifest.layers.slice().sort(function (a, b) { return areaOf(b) - areaOf(a); });
    var detailed = layers[layers.length - 1];

    var map = L.map('map', {
      zoomControl: true, minZoom: 3, maxZoom: 18, worldCopyJump: false,
      maxBounds: L.latLngBounds([[-85, -200], [85, 200]])
    });
    map.attributionControl.setPrefix(false);
    L.control.scale({ imperial: true, metric: true, position: 'topleft' }).addTo(map);

    var mapLayers = [];
    function addLayers() {
      mapLayers.forEach(function (l) { map.removeLayer(l); });
      var flavor = darkQuery && darkQuery.matches ? 'dark' : 'light';
      mapLayers = layers.map(function (layer, i) {
        var l = protomapsL.leafletLayer({
          url: '/maps/' + layer.file,
          flavor: flavor,
          lang: 'en',
          maxDataZoom: layer.maxzoom,
          bounds: boundsOf(layer),
          zIndex: i + 1,
          attribution: i === layers.length - 1
            ? '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors · <a href="https://protomaps.com">Protomaps</a>'
            : ''
        });
        l.addTo(map);
        return l;
      });
      // Outside every layer's box, show the map's own base colour instead of the page colour.
      if (mapLayers.length && mapLayers[0].backgroundColor) {
        map.getContainer().style.background = mapLayers[0].backgroundColor;
      }
    }
    addLayers();
    if (darkQuery && darkQuery.addEventListener) darkQuery.addEventListener('change', addLayers);
    else if (darkQuery && darkQuery.addListener) darkQuery.addListener(addLayers);

    var view = loadView();
    if (view) map.setView([view.lat, view.lng], view.zoom);
    else map.fitBounds(boundsOf(detailed));
    map.on('moveend', function () { saveView(map); });

    // --- GPS ---------------------------------------------------------------------------------
    var watchId = null, follow = false, you = null, accuracyCircle = null, lastFix = null;

    function setButton() {
      locateBtn.classList.toggle('on', watchId !== null && !follow);
      locateBtn.classList.toggle('follow', watchId !== null && follow);
    }

    function onFix(p) {
      var ll = L.latLng(p.coords.latitude, p.coords.longitude);
      lastFix = { latlng: ll, accuracy: p.coords.accuracy, altitude: p.coords.altitude };
      if (!you) {
        you = L.marker(ll, { icon: L.divIcon({ className: '', html: '<div class="you-dot"></div>', iconSize: [24, 24] }), interactive: false }).addTo(map);
        accuracyCircle = L.circle(ll, { radius: p.coords.accuracy, color: '#2f7fe0', weight: 1, fillOpacity: 0.12, interactive: false }).addTo(map);
        map.setView(ll, Math.max(map.getZoom(), 14));
      } else {
        you.setLatLng(ll);
        accuracyCircle.setLatLng(ll).setRadius(p.coords.accuracy);
        if (follow) map.panTo(ll);
      }
      var alt = p.coords.altitude !== null && p.coords.altitude !== undefined
        ? ' · altitude ' + Math.round(p.coords.altitude) + ' m (' + Math.round(p.coords.altitude * 3.28084) + ' ft)' : '';
      setStatus('You are here (±' + Math.round(p.coords.accuracy) + ' m)' + alt);
      coordsEl.textContent = formatLatLng(ll.lat, ll.lng);
    }

    function onError(e) {
      setStatus(e && e.code === 1
        ? 'Location is off for Pocket Mirror. Turn it on in Settings › Privacy › Location Services.'
        : 'Waiting for a GPS fix… (outdoors with a clear sky view is fastest)');
    }

    locateBtn.addEventListener('click', function () {
      if (watchId === null) {
        if (!navigator.geolocation) { setStatus('No location support here.'); return; }
        follow = true;
        setStatus('Waiting for a GPS fix… (outdoors with a clear sky view is fastest)');
        watchId = navigator.geolocation.watchPosition(onFix, onError, { enableHighAccuracy: true });
      } else if (!follow && lastFix) {
        follow = true;
        map.setView(lastFix.latlng, Math.max(map.getZoom(), 14));
      } else {
        navigator.geolocation.clearWatch(watchId);
        watchId = null; follow = false;
        if (you) { map.removeLayer(you); map.removeLayer(accuracyCircle); you = null; accuracyCircle = null; }
        lastFix = null;
        setStatus('Location off. Tap ◎ to show your position.');
        coordsEl.textContent = '';
      }
      setButton();
    });
    map.on('dragstart', function () { if (follow) { follow = false; setButton(); } });

    // Long-press (or right-click) anywhere: that point's coordinates, and distance from you.
    // iOS Safari/WKWebView never fires 'contextmenu' for a long touch, so time it ourselves.
    map.on('contextmenu', function (e) { showPoint(e.latlng); });
    (function () {
      var el = map.getContainer(), timer = null, startX = 0, startY = 0;
      function cancel() { if (timer) { clearTimeout(timer); timer = null; } }
      el.addEventListener('touchstart', function (ev) {
        cancel();
        if (ev.touches.length !== 1) return; // pinch-zoom etc.
        var t = ev.touches[0];
        startX = t.clientX; startY = t.clientY;
        timer = setTimeout(function () {
          timer = null;
          var rect = el.getBoundingClientRect();
          showPoint(map.containerPointToLatLng([startX - rect.left, startY - rect.top]));
        }, 550);
      }, { passive: true });
      el.addEventListener('touchmove', function (ev) {
        var t = ev.touches[0];
        if (!t || Math.abs(t.clientX - startX) > 10 || Math.abs(t.clientY - startY) > 10) cancel();
      }, { passive: true });
      el.addEventListener('touchend', cancel, { passive: true });
      el.addEventListener('touchcancel', cancel, { passive: true });
    })();

    function showPoint(latlng) {
      var e = { latlng: latlng };
      var text = '<b>' + formatLatLng(e.latlng.lat, e.latlng.lng) + '</b>';
      if (lastFix) {
        var meters = lastFix.latlng.distanceTo(e.latlng);
        var miles = meters / 1609.344;
        var bearing = bearingDeg(lastFix.latlng, e.latlng);
        text += '<br>' + (miles >= 0.1 ? miles.toFixed(2) + ' mi' : Math.round(meters * 3.28084) + ' ft') +
          ' (' + (meters >= 1000 ? (meters / 1000).toFixed(2) + ' km' : Math.round(meters) + ' m') + ')' +
          ' at ' + Math.round(bearing) + '° ' + compass(bearing) + ' from you';
      }
      L.popup().setLatLng(e.latlng).setContent(text).openOn(map);
    }

    function bearingDeg(a, b) {
      var toRad = Math.PI / 180, lat1 = a.lat * toRad, lat2 = b.lat * toRad, dLng = (b.lng - a.lng) * toRad;
      var y = Math.sin(dLng) * Math.cos(lat2);
      var x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng);
      return (Math.atan2(y, x) / toRad + 360) % 360;
    }
    function compass(deg) {
      return ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][Math.round(deg / 45) % 8];
    }

    // --- Topo overlay (USGS 3DEP contours + hillshade; files from tools/build-topo.sh) ----------
    var TOPO_KEY = 'pocketMirror.topo', topoLayers = [], topoBtn = document.getElementById('topoBtn');
    fetch('/maps/topo.json', { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (topo) {
        if (!topo) return;
        topoBtn.hidden = false;
        var b = topo.bbox, box = L.latLngBounds([[b[1], b[0]], [b[3], b[2]]]);
        var dark = darkQuery && darkQuery.matches;
        var line = dark ? '#c9a27a' : '#9a6a3a';
        function build() {
          var hill = pmtiles.leafletRasterLayer(new pmtiles.PMTiles('/maps/' + topo.hillshade.file), {
            maxNativeZoom: 12, maxZoom: 18, bounds: box, zIndex: 10, opacity: dark ? 0.6 : 0.5, className: 'hillshade',
            attribution: 'Relief: USGS 3DEP'
          });
          var contours = protomapsL.leafletLayer({
            url: '/maps/' + topo.contours.file, maxDataZoom: topo.contours.maxzoom, bounds: box, zIndex: 11,
            attribution: '',
            paintRules: [{
              dataLayer: 'contours',
              symbolizer: new protomapsL.LineSymbolizer({
                color: line,
                width: function (z, f) { return f.props.idx ? (z >= 13 ? 1.6 : 1.1) : 0.6; },
                opacity: function (z, f) { return f.props.idx ? 0.9 : 0.55; }
              })
            }],
            labelRules: [{
              dataLayer: 'contours', minzoom: 12,
              filter: function (z, f) { return f.props.idx === 1; },
              symbolizer: new protomapsL.LineLabelSymbolizer({
                labelProps: ['ele'], fill: line, stroke: dark ? '#18232a' : '#ffffff', width: 2,
                font: '600 11px sans-serif'
              })
            }]
          });
          return [hill, contours];
        }
        function setTopo(on) {
          topoLayers.forEach(function (l) { map.removeLayer(l); });
          topoLayers = on ? build() : [];
          topoLayers.forEach(function (l) { l.addTo(map); });
          topoBtn.classList.toggle('on', on);
          try { localStorage.setItem(TOPO_KEY, on ? '1' : '0'); } catch (e) { /* ignore */ }
          if (on) setStatus('Topo on: contour lines every ' + topo.contours.interval_ft + ' ft (bold every ' +
            topo.contours.index_ft + ' ft, labelled in feet) and shaded relief.');
        }
        var saved = null;
        try { saved = localStorage.getItem(TOPO_KEY); } catch (e) { /* ignore */ }
        if (saved === '1') setTopo(true);
        topoBtn.addEventListener('click', function () { setTopo(topoLayers.length === 0); });
      })
      .catch(function () {});

    // --- Place-name search (offline index: /maps/places.json built by tools/build-places.sh) ---
    var places = null, folded = null, kinds = null, searchMarker = null;
    var panel = document.getElementById('searchPanel'), input = document.getElementById('searchInput');
    var results = document.getElementById('searchResults');

    function fold(s) {
      return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[’']/g, '');
    }
    function loadPlaces() {
      if (places) return Promise.resolve();
      results.innerHTML = '<div class="empty">Loading place names…</div>';
      return fetch('/maps/places.json').then(function (r) {
        if (!r.ok) throw new Error('missing');
        return r.json();
      }).then(function (d) {
        places = d.places; kinds = d.kinds;
        folded = places.map(function (p) { return fold(p[0]); });
        results.innerHTML = '';
      }).catch(function () {
        results.innerHTML = '<div class="empty">No place index on this phone yet (maps/places.json).</div>';
      });
    }
    function reference() { return lastFix ? lastFix.latlng : map.getCenter(); }
    function describe(p, ref) {
      var ll = L.latLng(p[2], p[3]), meters = ref.distanceTo(ll), miles = meters / 1609.344;
      var bits = [kinds[p[1]][0], p[4]];
      if (p.length > 5) bits.push(Math.round(p[5] * 3.28084).toLocaleString() + ' ft');
      bits.push((miles < 10 ? miles.toFixed(1) : Math.round(miles)) + ' mi ' + compass(bearingDeg(ref, ll)) +
        (lastFix ? ' of you' : ' of map centre'));
      return bits.join(' · ');
    }
    function search(q) {
      var fq = fold(q.trim());
      if (fq.length < 2 || !places) { results.innerHTML = ''; return; }
      var ref = reference(), hits = [];
      for (var i = 0; i < folded.length; i++) {
        var n = folded[i], score;
        if (n === fq) score = 0;
        else if (n.indexOf(fq) === 0) score = 1;
        else if (n.indexOf(' ' + fq) >= 0 || n.indexOf('-' + fq) >= 0) score = 2;
        else if (fq.length >= 3 && n.indexOf(fq) >= 0) score = 3;
        else continue;
        hits.push({ i: i, score: score });
      }
      hits.forEach(function (h) {
        var p = places[h.i];
        h.rank = h.score * 100 - kinds[p[1]][1] * 6 + Math.min(ref.distanceTo(L.latLng(p[2], p[3])) / 25000, 60);
      });
      hits.sort(function (a, b) { return a.rank - b.rank; });
      if (!hits.length) { results.innerHTML = '<div class="empty">No matches</div>'; return; }
      results.innerHTML = hits.slice(0, 40).map(function (h) {
        var p = places[h.i];
        return '<div class="hit" data-i="' + h.i + '"><b>' + escapeHtml(p[0]) + '</b><span>' + escapeHtml(describe(p, ref)) + '</span></div>';
      }).join('');
    }
    function escapeHtml(s) {
      return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
    }
    var ZOOM = { City: 12, Town: 13, Village: 14, Hamlet: 15, River: 12, Lake: 13, Reservoir: 13, Bay: 12,
                 'National park': 11, 'Protected area': 12, 'Nature reserve': 13, Island: 13, Peak: 14, Airport: 13 };
    results.addEventListener('click', function (ev) {
      var el = ev.target.closest ? ev.target.closest('.hit') : null;
      if (!el) return;
      var p = places[+el.getAttribute('data-i')], ll = L.latLng(p[2], p[3]), label = kinds[p[1]][0];
      closeSearch();
      if (follow) { follow = false; setButton(); }
      map.setView(ll, ZOOM[label] || 16);
      if (searchMarker) map.removeLayer(searchMarker);
      searchMarker = L.circleMarker(ll, { radius: 9, color: '#fff', weight: 3, fillColor: '#e8822e', fillOpacity: 1 }).addTo(map);
      searchMarker.bindPopup('<b>' + escapeHtml(p[0]) + '</b><br>' + escapeHtml(describe(p, reference())) +
        '<br>' + formatLatLng(p[2], p[3])).openPopup();
    });
    function openSearch() { panel.hidden = false; input.focus(); loadPlaces().then(function () { search(input.value); }); }
    function closeSearch() { panel.hidden = true; input.blur(); }
    document.getElementById('searchBtn').addEventListener('click', openSearch);
    document.getElementById('searchClose').addEventListener('click', closeSearch);
    var pending = null;
    input.addEventListener('input', function () {
      clearTimeout(pending);
      pending = setTimeout(function () { search(input.value); }, 120);
    });

    setStatus('Tap ◎ to show your position, ⌕ to search places. Long-press the map for coordinates.');
  }
})();

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
      updateGuide();
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
      var detail = '';
      if (lastFix) {
        var meters = lastFix.latlng.distanceTo(latlng), bearing = bearingDeg(lastFix.latlng, latlng);
        detail = distanceText(meters) + ' (' + (meters >= 1000 ? (meters / 1000).toFixed(2) + ' km' : Math.round(meters) + ' m') + ')' +
          ' at ' + Math.round(bearing) + '° ' + compass(bearing) + ' from you';
      }
      L.popup().setLatLng(latlng).setContent(pointPopup(latlng, null, detail)).openOn(map);
    }

    // Popup for a place or a pressed point, with Walk / Drive / Line buttons.
    // Walk and Drive ask the app's router (/api/route, over maps/routing.bin); Line is a compass
    // bearing, for cross-country travel or when there's no routing file.
    var popupTarget = null, routingReady = false;
    fetch('/api/route?check=1').then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { routingReady = !!(d && d.ready); }).catch(function () {});
    function pointPopup(ll, name, detail) {
      popupTarget = { latlng: ll, name: name || formatLatLng(ll.lat, ll.lng).split('  ')[0] };
      return (name ? '<b>' + escapeHtml(name) + '</b><br>' : '<b>' + formatLatLng(ll.lat, ll.lng) + '</b><br>') +
        (detail ? escapeHtml(detail) + '<br>' : '') + (name ? formatLatLng(ll.lat, ll.lng) + '<br>' : '') +
        '<div class="go-row">' +
        (routingReady ? '<button class="go-btn" type="button" data-mode="foot">🚶 Walk</button>' +
                        '<button class="go-btn" type="button" data-mode="car">🚗 Drive</button>' : '') +
        '<button class="go-btn" type="button" data-mode="line">🧭 ' + (routingReady ? 'Line' : 'Guide me here') + '</button></div>';
    }
    // Leaflet stops clicks inside popups from reaching the map, so wire the buttons on open.
    map.on('popupopen', function (e) {
      var el = e.popup.getElement(), target = popupTarget;
      if (!el) return;
      Array.prototype.forEach.call(el.querySelectorAll('.go-btn'), function (btn) {
        btn.addEventListener('click', function () { startGuide(target, btn.getAttribute('data-mode')); map.closePopup(); });
      });
    });

    // --- Guide: a route (walk/drive) or a straight line to the target, updated with each fix ---
    var guide = null, guideLine = null, routeLine = null, guideEl = document.getElementById('guide');
    var guideText = document.getElementById('guideText'), stepsBtn = document.getElementById('guideSteps');
    var stepsPanel = document.getElementById('stepsPanel'), stepsList = document.getElementById('stepsList');
    // Magnetic declination for New England (WMM 2025, about ±1°): west, so a compass reads more.
    function declination(ll) { return -14 - 0.75 * (ll.lng + 71) - 0.3 * (ll.lat - 42.4); }
    function durationText(s) {
      var m = Math.max(1, Math.round(s / 60));
      return m < 60 ? m + ' min' : Math.floor(m / 60) + ' h ' + (m % 60 ? (m % 60) + ' min' : '');
    }
    function bearingLine(from, to) {
      var trueB = bearingDeg(from, to), magB = (trueB - declination(from) + 360) % 360;
      return distanceText(from.distanceTo(to)) + ' ' + compass(trueB) + ' · bearing ' + Math.round(trueB) + '° true, ' +
        Math.round(magB) + '° on a compass';
    }

    function clearRoute() {
      if (routeLine) { map.removeLayer(routeLine); routeLine = null; }
      if (guideLine) { map.removeLayer(guideLine); guideLine = null; }
    }

    function fetchRoute(from) {
      var g = guide;
      g.fetching = true; g.lastFetch = Date.now();
      var url = '/api/route?mode=' + g.mode + '&from=' + from.lat.toFixed(6) + ',' + from.lng.toFixed(6) +
        '&to=' + g.latlng.lat.toFixed(6) + ',' + g.latlng.lng.toFixed(6);
      fetch(url).then(function (r) { return r.json(); }).then(function (d) {
        if (guide !== g) return;
        g.fetching = false;
        if (d.error) { g.error = d.error; g.route = null; clearRoute(); updateGuide(); return; }
        g.error = null;
        var pts = d.coords.map(function (c) { return L.latLng(c[0], c[1]); });
        // Cumulative distance along the route, and where each step starts on it.
        var cum = [0];
        for (var i = 1; i < pts.length; i++) cum.push(cum[i - 1] + pts[i - 1].distanceTo(pts[i]));
        var k = 0;
        d.steps.forEach(function (s) {
          var ll = L.latLng(s.lat, s.lon), best = Infinity;
          for (var j = k; j < pts.length; j++) {
            var dist = pts[j].distanceTo(ll);
            if (dist < best) { best = dist; s.index = j; }
            if (dist > best + 2000) break;
          }
          k = s.index || k;
        });
        g.route = { pts: pts, cum: cum, total: cum[cum.length - 1], seconds: d.seconds, steps: d.steps };
        clearRoute();
        routeLine = L.polyline(pts, { color: g.mode === 'car' ? '#2f7fe0' : '#7a3fd1', weight: 6, opacity: 0.85, interactive: false }).addTo(map);
        if (g.fitPending) {
          g.fitPending = false;
          if (follow) { follow = false; setButton(); }
          map.stop(); map.fitBounds(routeLine.getBounds().pad(0.15), { maxZoom: 16, animate: false });
        }
        renderSteps();
        updateGuide();
      }).catch(function () {
        if (guide !== g) return;
        g.fetching = false; g.error = 'Directions failed. Is Pocket Mirror up to date?'; updateGuide();
      });
    }

    // Where we are along the route: nearest segment, metres along, metres off.
    function progress(r, here) {
      var kx = Math.cos(here.lat * Math.PI / 180) * 111320, ky = 110574, best = null;
      for (var i = 0; i < r.pts.length - 1; i++) {
        var a = r.pts[i], b = r.pts[i + 1];
        var ax = (a.lng - here.lng) * kx, ay = (a.lat - here.lat) * ky, bx = (b.lng - here.lng) * kx, by = (b.lat - here.lat) * ky;
        var dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
        var t = l2 > 0 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l2)) : 0;
        var qx = ax + t * dx, qy = ay + t * dy, off = Math.sqrt(qx * qx + qy * qy);
        if (!best || off < best.off) best = { i: i, off: off, along: r.cum[i] + t * (r.cum[i + 1] - r.cum[i]) };
      }
      return best;
    }

    function updateGuide() {
      if (!guide) return;
      var g = guide, head = '<b>' + escapeHtml(g.name) + '</b><br>';
      if (!lastFix) { guideText.innerHTML = head + 'Waiting for GPS…'; return; }
      var here = lastFix.latlng;
      if (g.mode === 'line') {
        if (g.fitPending) {
          g.fitPending = false;
          if (follow) { follow = false; setButton(); }
          map.stop(); map.fitBounds(L.latLngBounds([here, g.latlng]).pad(0.2), { maxZoom: 15, animate: false });
        }
        if (guideLine) guideLine.setLatLngs([here, g.latlng]);
        else guideLine = L.polyline([here, g.latlng], { color: '#e8822e', weight: 4, dashArray: '8 8', interactive: false }).addTo(map);
        guideText.innerHTML = head + bearingLine(here, g.latlng) +
          (here.distanceTo(g.latlng) < Math.max(30, lastFix.accuracy) ? '<br>You are there.' : '');
        return;
      }
      if (!g.route && !g.fetching && !g.error) fetchRoute(here);
      if (g.error) { guideText.innerHTML = head + escapeHtml(g.error) + '<br>' + bearingLine(here, g.latlng); return; }
      if (!g.route) { guideText.innerHTML = head + 'Finding the ' + (g.mode === 'car' ? 'driving' : 'walking') + ' route…'; return; }
      var r = g.route, p = progress(r, here), left = Math.max(0, r.total - p.along);
      // Off the route by more than GPS error: work out a new one (at most every 20 s).
      if (p.off > Math.max(60, lastFix.accuracy * 1.5) && !g.fetching && Date.now() - g.lastFetch > 20000) fetchRoute(here);
      var next = null;
      for (var i = 0; i < r.steps.length; i++) if (r.steps[i].index > p.i + 1) { next = r.steps[i]; break; }
      var nextText = next ? 'Next: ' + escapeHtml(next.text) + ' in ' + distanceText(Math.max(0, r.cum[next.index] - p.along))
        : 'Then the destination';
      if (left < Math.max(30, lastFix.accuracy)) nextText = 'You are there.';
      guideText.innerHTML = head + distanceText(left) + ' · ' + durationText(r.seconds * left / Math.max(r.total, 1)) +
        (g.mode === 'car' ? ' drive' : ' walk') + (p.off > 60 ? ' · off route, rerouting…' : '') + '<br>' + nextText;
      highlightStep(next);
    }

    function renderSteps() {
      var r = guide && guide.route;
      if (!r) { stepsList.innerHTML = ''; return; }
      stepsList.innerHTML = r.steps.map(function (s, i) {
        return '<div class="hit step" data-i="' + i + '"><b>' + escapeHtml(s.text) + '</b><span>' + distanceText(s.meters) + '</span></div>';
      }).join('') + '<div class="hint">' + distanceText(r.total) + ' in all, about ' + durationText(r.seconds) +
        '. Routes come from OpenStreetMap: check trail conditions, closures and the ground in front of you.</div>';
    }
    function highlightStep(next) {
      Array.prototype.forEach.call(stepsList.querySelectorAll('.step'), function (el) {
        el.classList.toggle('next', !!next && guide.route.steps[+el.getAttribute('data-i')] === next);
      });
    }
    stepsList.addEventListener('click', function (ev) {
      var el = ev.target.closest ? ev.target.closest('.step') : null;
      if (!el || !guide || !guide.route) return;
      var s = guide.route.steps[+el.getAttribute('data-i')];
      stepsPanel.hidden = true;
      if (follow) { follow = false; setButton(); }
      map.setView([s.lat, s.lon], Math.max(map.getZoom(), 16));
    });
    stepsBtn.addEventListener('click', function () { stepsPanel.hidden = !stepsPanel.hidden; });
    document.getElementById('stepsClose').addEventListener('click', function () { stepsPanel.hidden = true; });

    function startGuide(t, mode) {
      guide = { latlng: t.latlng, name: t.name, mode: mode || 'line', fitPending: true, route: null, lastFetch: 0 };
      clearRoute();
      stepsBtn.hidden = guide.mode === 'line';
      stepsPanel.hidden = true; stepsList.innerHTML = '';
      guideEl.hidden = false;
      if (watchId === null) locateBtn.click();   // guiding needs the GPS
      updateGuide();
    }
    document.getElementById('guideStop').addEventListener('click', function () {
      guide = null; guideEl.hidden = true; stepsPanel.hidden = true;
      clearRoute();
    });

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
            maxNativeZoom: topo.hillshade.maxzoom || 13, maxZoom: 18, bounds: box, zIndex: 10, opacity: dark ? 0.45 : 0.35, className: 'hillshade',
            attribution: 'Relief: USGS 3DEP'
          });
          var contours = protomapsL.leafletLayer({
            url: '/maps/' + topo.contours.file, maxDataZoom: topo.contours.maxzoom, bounds: box, zIndex: 11,
            attribution: '',
            paintRules: [{
              dataLayer: 'contours',
              // 40 ft lines only from zoom 13; 200 ft index lines always.
              filter: function (z, f) { return f.props.idx === 1 || z >= 13; },
              symbolizer: new protomapsL.LineSymbolizer({
                color: line,
                width: function (z, f) { return f.props.idx ? (z >= 14 ? 1.3 : 0.9) : 0.45; },
                opacity: function (z, f) { return f.props.idx ? 0.8 : (z >= 14 ? 0.45 : 0.3); }
              })
            }],
            labelRules: [{
              dataLayer: 'contours', minzoom: 12,
              filter: function (z, f) { return f.props.idx === 1; },
              symbolizer: new protomapsL.LineLabelSymbolizer({
                labelProps: ['label'], fill: line, repeatDistance: 400, stroke: dark ? '#18232a' : '#ffffff', width: 2,
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
    function distanceText(meters) {
      var miles = meters / 1609.344;
      if (miles < 0.1) return Math.round(meters * 3.28084) + ' ft';
      return (miles < 10 ? miles.toFixed(1) : Math.round(miles)) + ' mi';
    }
    function describe(p, ref) {
      var ll = L.latLng(p[2], p[3]);
      var bits = [distanceText(ref.distanceTo(ll)) + ' ' + compass(bearingDeg(ref, ll)), kinds[p[1]][0], p[4]];
      if (p.length > 5) bits.push(Math.round(p[5] * 3.28084).toLocaleString() + ' ft');
      return bits.join(' · ');
    }
    // Kinds a query can name ("hospital", "huts", "water"), matched on the folded label.
    function kindsNamed(fq) {
      var hit = {}, any = false, q = fq.replace(/s$/, '');
      if (q.length < 3) return null;
      kinds.forEach(function (k, id) {
        var label = fold(k[0]);
        if (label === q || label === fq || (label.indexOf(q) === 0 && q.length >= 4)) { hit[id] = true; any = true; }
      });
      return any ? hit : null;
    }
    // Closest first. Bigger places (towns, hospitals) count as a little closer than small ones
    // (streams, towers), and a name that only contains the query mid-word ranks after real matches.
    function search(q) {
      var fq = fold(q.trim());
      if (fq.length < 2 || !places) { results.innerHTML = ''; return; }
      var ref = reference(), hits = [], byKind = kindsNamed(fq);
      for (var i = 0; i < folded.length; i++) {
        var n = folded[i], p = places[i], tier;
        if (n === fq || n.indexOf(fq) === 0 || n.indexOf(' ' + fq) >= 0 || n.indexOf('-' + fq) >= 0) tier = 0;
        else if (byKind && byKind[p[1]]) tier = 0;
        else if (fq.length >= 3 && n.indexOf(fq) >= 0) tier = 1;
        else continue;
        var km = ref.distanceTo(L.latLng(p[2], p[3])) / 1000;
        hits.push({ i: i, rank: tier * 1e6 + km / (1 + kinds[p[1]][1] / 4) });
      }
      hits.sort(function (a, b) { return a.rank - b.rank; });
      if (!hits.length) { results.innerHTML = '<div class="empty">No matches</div>'; return; }
      results.innerHTML = '<div class="hint">' + hits.length.toLocaleString() + (hits.length === 1 ? ' match' : ' matches') +
        ', closest to ' + (lastFix ? 'you' : 'the map centre') + ' first' + (lastFix ? '' : ' (tap ◎ to use your position)') + '</div>' +
        hits.slice(0, 50).map(function (h) {
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
      // Distance only from a real position: the map centre has just moved onto the place.
      var detail = lastFix ? describe(p, lastFix.latlng) + ' of you'
        : [label, p[4]].concat(p.length > 5 ? [Math.round(p[5] * 3.28084).toLocaleString() + ' ft'] : []).join(' · ');
      searchMarker.bindPopup(pointPopup(ll, p[0], detail)).openPopup();
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

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

    setStatus('Tap ◎ to show your position. Long-press the map for a point’s coordinates.');
  }
})();

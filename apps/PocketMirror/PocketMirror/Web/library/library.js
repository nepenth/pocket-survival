/* Pocket Mirror library page. Kiwix (libkiwix, port 8091) holds the ZIM archives; this page lists
   them from its OPDS catalog and searches them through its /search?format=xml API, so it doesn't
   depend on Kiwix's own welcome page (whose scripts don't run in iOS 14's WebKit).
   Written for Safari 14: no syntax newer than ES2019. */
(function () {
  'use strict';
  var K = location.protocol + '//' + location.hostname + ':8091';
  var shelf = document.getElementById('shelf'), results = document.getElementById('results');
  var form = document.getElementById('form'), q = document.getElementById('q'), scope = document.getElementById('scope');
  var sub = document.getElementById('sub');
  var PAGE = 20, current = null;

  var GROUPS = [
    ['Medical', /medic|mdwiki|doctor|health|libretexts.*med/i],
    ['Survival and preparedness', /disaster|ready|prepper|food|water|knot|outdoors/i],
    ['Repair and how-to', /ifixit|appropedia|diy|mechanics|gardening|cooking|ham\./i],
    ['Reference', /./]
  ];

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }
  function text(el, sel) { var n = el.getElementsByTagName(sel)[0]; return n ? n.textContent : ''; }
  function gb(bytes) { return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + ' GB' : Math.round(bytes / 1e6) + ' MB'; }

  function xml(url) {
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then(function (t) { return new DOMParser().parseFromString(t, 'application/xml'); });
  }

  // --- Shelf ------------------------------------------------------------------------------
  var sizes = {};
  Promise.all([
    fetch('/library/library.json').then(function (r) { return r.ok ? r.json() : null; }).catch(function () { return null; }),
    xml(K + '/catalog/v2/entries?count=-1')
  ]).then(function (got) {
    if (got[0] && got[0].archives) got[0].archives.forEach(function (a) { sizes[a.file.replace(/\.zim$/, '')] = a.bytes; });
    var books = Array.prototype.map.call(got[1].getElementsByTagName('entry'), function (e) {
      var links = e.getElementsByTagName('link'), href = '', icon = '';
      for (var i = 0; i < links.length; i++) {
        if (links[i].getAttribute('type') === 'text/html') href = links[i].getAttribute('href');
        if (/thumbnail/.test(links[i].getAttribute('rel') || '')) icon = links[i].getAttribute('href');
      }
      var name = href.replace(/^\/content\//, '');
      return { title: text(e, 'title'), summary: text(e, 'summary'), articles: +text(e, 'articleCount') || 0,
               href: href, icon: icon, name: name, bytes: sizes[name] || 0,
               search: /_ftindex:yes/.test(text(e, 'tags')) };
    });
    books.sort(function (a, b) { return a.title.localeCompare(b.title); });
    var total = books.reduce(function (t, b) { return t + b.bytes; }, 0);
    sub.textContent = books.length + ' books' + (total ? ', ' + gb(total) : '') + '. Everything works offline.';
    books.forEach(function (b) {
      if (!b.search) return;
      var o = document.createElement('option'); o.value = b.name; o.textContent = b.title; scope.appendChild(o);
    });
    var html = '';
    GROUPS.forEach(function (g) {
      var mine = books.filter(function (b) { return !b.group && g[1].test(b.name + ' ' + b.title) && (b.group = g[0]); });
      if (!mine.length) return;
      html += '<h2>' + esc(g[0]) + '</h2><div class="list">' + mine.map(function (b) {
        return '<a class="item" href="' + esc(K + b.href + '/') + '">' +
          (b.icon ? '<img src="' + esc(K + b.icon) + '" alt="" width="40" height="40">' : '<span class="ph">📘</span>') +
          '<div><b>' + esc(b.title) + '</b><span>' + esc(b.summary) + '</span>' +
          '<small>' + [b.articles > 1 ? b.articles.toLocaleString() + ' articles' : '', b.bytes ? gb(b.bytes) : ''].filter(Boolean).join(' · ') + '</small></div></a>';
      }).join('') + '</div>';
    });
    shelf.innerHTML = html;
  }).catch(function () {
    shelf.innerHTML = '<div class="check"><b>The library isn\'t running.</b><div class="detail">Open ⚙ Settings in Pocket Mirror to see ' +
      'the library status. Archives (.zim) go in the <b>library</b> folder.</div></div>';
  });

  // Snippets arrive with <b> elements around the matched words: keep those, escape the rest.
  function marked(node) {
    if (!node) return '';
    var out = '';
    for (var c = node.firstChild; c; c = c.nextSibling) {
      out += c.nodeType === 1 && c.nodeName.toLowerCase() === 'b' ? '<b>' + esc(c.textContent) + '</b>'
        : esc(c.textContent);
    }
    return out;
  }

  // --- Search -----------------------------------------------------------------------------
  function run(start) {
    var pattern = q.value.trim();
    if (!pattern) { results.innerHTML = ''; shelf.hidden = false; return; }
    current = { pattern: pattern, book: scope.value, start: start };
    shelf.hidden = true;
    results.innerHTML = '<p class="sub">Searching…</p>';
    var url = K + '/search?format=xml&pageLength=' + PAGE + '&start=' + start + '&pattern=' + encodeURIComponent(pattern) +
      (scope.value ? '&books.name=' + encodeURIComponent(scope.value) : '');
    var mine = current;
    xml(url).then(function (doc) {
      if (mine !== current) return;
      var total = parseInt(text(doc, 'opensearch:totalResults').replace(/,/g, ''), 10) || 0;
      var items = doc.getElementsByTagName('item');
      if (!items.length) { results.innerHTML = '<p class="sub">Nothing found for “' + esc(pattern) + '”.</p>'; return; }
      var html = '<p class="sub">' + (total >= 2000 ? 'Over 2,000' : total.toLocaleString()) + ' results' +
        (scope.value ? ' in ' + esc(scope.options[scope.selectedIndex].text) : '') + '</p><div class="list">';
      for (var i = 0; i < items.length; i++) {
        var it = items[i], book = it.getElementsByTagName('book')[0];
        var snippet = marked(it.getElementsByTagName('description')[0]);
        html += '<a class="item hit" href="' + esc(K + text(it, 'link')) + '"><div><b>' + esc(text(it, 'title')) + '</b>' +
          '<small>' + (book ? esc(text(book, 'title')) : '') + '</small><span>' + snippet + '</span></div></a>';
      }
      html += '</div><div class="pager">' +
        (start > 0 ? '<button type="button" data-start="' + Math.max(0, start - PAGE) + '">‹ Previous</button>' : '<span></span>') +
        (start + PAGE < total ? '<button type="button" data-start="' + (start + PAGE) + '">Next ›</button>' : '') + '</div>';
      results.innerHTML = html;
      window.scrollTo(0, 0);
    }).catch(function () {
      if (mine === current) results.innerHTML = '<p class="sub">Search failed. Is the library running? (⚙ Settings)</p>';
    });
  }
  results.addEventListener('click', function (ev) {
    var s = ev.target.getAttribute && ev.target.getAttribute('data-start');
    if (s !== null && s !== undefined) run(+s);
  });
  form.addEventListener('submit', function (ev) { ev.preventDefault(); q.blur(); run(0); });
  scope.addEventListener('change', function () { if (q.value.trim()) run(0); });
  q.addEventListener('input', function () { if (!q.value.trim()) run(0); });
})();

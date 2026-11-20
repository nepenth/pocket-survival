/* Pocket Mirror books page: reads /books/books.json (tools/build-books-index.swift) and lists the
   PDFs by collection, with chapter names, page counts and a filter. Opening a PDF shows it in the
   app's web view. Typing 3+ letters also searches the text of every page (books-text.json,
   loaded on first use). Without an index it says how to make one.
   Written for Safari 14: no syntax newer than ES2019. */
(function () {
  'use strict';
  var shelf = document.getElementById('shelf'), q = document.getElementById('q'), scope = document.getElementById('scope');
  var sub = document.getElementById('sub'), recentEl = document.getElementById('recent');
  var RECENT_KEY = 'pocketMirror.recentBooks', data = null, byId = {};
  var textEl = document.createElement('div'), pages = null, loadingText = null;
  textEl.id = 'inside';

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }
  function fold(s) { return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase(); }
  function href(file) { return '/books/' + file.split('/').map(encodeURIComponent).join('/'); }
  function size(b) { return b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB' : Math.round(b / 1e3) + ' KB'; }
  function meta(it) { return (it.pages ? it.pages + ' pages · ' : '') + size(it.bytes); }

  function loadRecent() { try { return JSON.parse(localStorage.getItem(RECENT_KEY) || '[]'); } catch (e) { return []; } }
  function remember(entry) {
    var list = loadRecent().filter(function (r) { return r.file !== entry.file; });
    list.unshift(entry);
    try { localStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, 4))); } catch (e) {}
  }
  function row(it, where) {
    return '<a class="item" href="' + esc(href(it.file)) + '" data-file="' + esc(it.file) + '" data-title="' + esc(it.title) +
      '" data-where="' + esc(where || '') + '"><span class="ph">📄</span><div><b>' + esc(it.title) + '</b>' +
      (where ? '<span>' + esc(where) + '</span>' : '') + '<small>' + meta(it) + '</small></div></a>';
  }

  // Scope: '' (all), 'c<n>' (a book split into chapters: collection n), 'f<id>' (one PDF).
  function inScope(c, it) {
    var v = scope.value;
    return !v || v === 'c' + c.index || v === 'f' + it.id;
  }
  function fillScope() {
    data.collections.forEach(function (c, n) {
      c.index = n;
      if (c.chapters) {
        var o = document.createElement('option'); o.value = 'c' + n; o.textContent = c.title; scope.appendChild(o);
        return;
      }
      var g = document.createElement('optgroup'); g.label = c.title;
      c.items.forEach(function (it) {
        var o = document.createElement('option'); o.value = 'f' + it.id; o.textContent = it.title; g.appendChild(o);
      });
      scope.appendChild(g);
    });
  }

  function render() {
    var fq = fold(q.value.trim()), html = '';
    if (!fq) {
      var recent = loadRecent();
      recentEl.innerHTML = recent.length ? '<h2>Recently opened</h2><div class="list">' + recent.map(function (r) {
        return row(r, r.where);
      }).join('') + '</div>' : '';
    } else recentEl.innerHTML = '';
    if (scope.value) recentEl.innerHTML = '';
    data.collections.forEach(function (c) {
      var hitCollection = fq && fold(c.title + ' ' + c.about).indexOf(fq) >= 0;
      var items = c.items.filter(function (it) {
        return inScope(c, it) && (!fq || hitCollection || fold(it.title).indexOf(fq) >= 0);
      });
      if (!items.length) return;
      if (!c.chapters) {
        html += '<h2>' + esc(c.title) + '</h2>' + (c.about ? '<p class="about">' + esc(c.about) + '</p>' : '') +
          '<div class="list">' + items.map(function (it) { return row(it); }).join('') + '</div>';
        return;
      }
      var pages = c.items.reduce(function (t, it) { return t + (it.pages || 0); }, 0);
      html += '<h2>' + esc(c.title) + '</h2>' + (c.about ? '<p class="about">' + esc(c.about) + '</p>' : '') +
        '<details class="list book"' + (fq || scope.value ? ' open' : '') + '><summary class="item"><span class="ph">📕</span><div><b>' +
        c.items.length + ' chapters</b><small>' + pages + ' pages · tap for the chapter list</small></div></summary>' +
        (scope.value ? '' : '<a class="item tool" href="#" data-scope="c' + c.index + '"><span class="ph">🔍</span><div><b>Search this book</b></div></a>') +
        items.map(function (it) { return row(it, c.title); }).join('') + '</details>';
    });
    shelf.innerHTML = html || (fq.length >= 3 ? '' : '<p class="sub">No book or chapter matches “' + esc(q.value) + '”.</p>');
    shelf.appendChild(textEl);
    searchText(fq);
  }

  // --- Searching inside the books (every page's text) ---------------------------------------
  function loadText() {
    if (!loadingText) {
      loadingText = fetch('/books/books-text.json').then(function (r) { return r.ok ? r.json() : { pages: [] }; })
        .then(function (d) {
          pages = d.pages.map(function (p) { return { id: p[0], page: p[1], text: p[2], folded: fold(p[2]) }; });
        }).catch(function () { pages = []; });
    }
    return loadingText;
  }
  function snippet(p, fq) {
    var at = p.folded.indexOf(fq), from = Math.max(0, at - 70), to = Math.min(p.text.length, at + fq.length + 110);
    return (from > 0 ? '…' : '') + esc(p.text.slice(from, at)) + '<b>' + esc(p.text.slice(at, at + fq.length)) + '</b>' +
      esc(p.text.slice(at + fq.length, to)) + (to < p.text.length ? '…' : '');
  }
  function searchText(fq) {
    if (fq.length < 3) { textEl.innerHTML = ''; return; }
    if (!pages) {
      textEl.innerHTML = '<h2>Inside ' + (scope.value ? 'this book' : 'the books') + '</h2><p class="sub">Searching the pages…</p>';
      loadText().then(function () { if (fold(q.value.trim()) === fq) searchText(fq); });
      return;
    }
    var hits = [];
    for (var i = 0; i < pages.length; i++) {
      var p = pages[i];
      if (scope.value && !inScope(byId[p.id].c, byId[p.id])) continue;
      var at = p.folded.indexOf(fq);
      if (at < 0) continue;
      var n = 0;
      for (var k = at; k >= 0 && n < 20; k = p.folded.indexOf(fq, k + fq.length)) n++;
      hits.push({ p: p, n: n });
    }
    hits.sort(function (a, b) { return b.n - a.n; });
    if (!hits.length) { textEl.innerHTML = '<h2>Inside ' + (scope.value ? 'this book' : 'the books') + '</h2><p class="sub">“' + esc(q.value.trim()) + '” isn\'t on any page' + (scope.value ? ' of this book' : '') + '.</p>'; return; }
    textEl.innerHTML = '<h2>Inside ' + (scope.value ? 'this book' : 'the books') + '</h2><p class="sub">' + hits.length + (hits.length === 1 ? ' page' : ' pages') +
      (hits.length > 40 ? ', the 40 that mention it most' : '') + '</p><div class="list">' +
      hits.slice(0, 40).map(function (h) {
        var it = byId[h.p.id];
        if (!it) return '';
        return '<a class="item hit" href="' + esc(href(it.file)) + '#page=' + h.p.page + '" data-file="' + esc(it.file) +
          '" data-title="' + esc(it.title) + '" data-where="' + esc(it.collection) + '"><div><b>' + esc(it.title) + '</b><small>' +
          esc(it.collection) + ' · page ' + h.p.page + ' of ' + it.pages + '</small><span>' + snippet(h.p, fq) + '</span></div></a>';
      }).join('') + '</div>';
  }

  document.addEventListener('click', function (ev) {
    var a = ev.target.closest ? ev.target.closest('a.item') : null;
    if (a && a.getAttribute('data-scope')) {
      ev.preventDefault();
      scope.value = a.getAttribute('data-scope');
      render(); window.scrollTo(0, 0); q.focus();
      return;
    }
    if (a && a.getAttribute('data-file')) {
      remember({ file: a.getAttribute('data-file'), title: a.getAttribute('data-title'), where: a.getAttribute('data-where'),
                 pages: 0, bytes: 0 });
    }
  });
  // Remembered entries keep their page counts from the index.
  function withMeta(r) {
    var found = null;
    data.collections.forEach(function (c) { c.items.forEach(function (it) { if (it.file === r.file) found = it; }); });
    return found ? { file: r.file, title: r.title, where: r.where, pages: found.pages, bytes: found.bytes } : null;
  }

  fetch('/books/books.json', { cache: 'no-store' }).then(function (r) {
    if (!r.ok) throw new Error('no index');
    return r.json();
  }).then(function (d) {
    data = d;
    d.collections.forEach(function (c) { c.items.forEach(function (it) { it.collection = c.title; it.c = c; byId[it.id] = it; }); });
    fillScope();
    scope.addEventListener('change', function () { render(); window.scrollTo(0, 0); });
    try { localStorage.setItem(RECENT_KEY, JSON.stringify(loadRecent().map(withMeta).filter(Boolean))); } catch (e) {}
    var files = d.collections.reduce(function (t, c) { return t + c.items.length; }, 0);
    var books = d.collections.reduce(function (t, c) { return t + (c.chapters ? 1 : c.items.length); }, 0);
    sub.textContent = books + ' books (' + files + ' files). Tap one to read it; use the ‹ button to come back.';
    render();
    var pending = null;
    q.addEventListener('input', function () { clearTimeout(pending); pending = setTimeout(render, 200); });
  }).catch(function () {
    shelf.innerHTML = '<div class="check"><b>No book index yet.</b><div class="detail">Run tools/fetch-books.sh on the Mac and copy ' +
      'the books folder to the phone again.</div></div>';
  });
})();

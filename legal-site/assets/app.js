/* BOJI CLUB 法律协议站 · 前端交互 */
(function () {
  "use strict";

  var root = document.documentElement;
  var params = new URLSearchParams(location.search);

  /* ---------- theme toggle (auto → light → dark) ---------- */
  var themeBtn = document.getElementById("themeBtn");
  function currentTheme() { return root.getAttribute("data-theme") || "auto"; }
  function applyTheme(t, persist) {
    root.setAttribute("data-theme", t);
    if (persist) { try { localStorage.setItem("boji-theme", t); } catch (e) {} }
  }
  if (themeBtn) {
    applyTheme(currentTheme(), false);
    themeBtn.addEventListener("click", function () {
      var order = ["auto", "light", "dark"];
      var next = order[(order.indexOf(currentTheme()) + 1) % order.length];
      applyTheme(next, true);
    });
  }

  /* ---------- language switch (keeps theme param + path) ---------- */
  var langSelect = document.getElementById("langSelect");
  if (langSelect) {
    langSelect.addEventListener("change", function () {
      var lang = langSelect.value;
      try { localStorage.setItem("boji-lang", lang); } catch (e) {}
      var url = new URL(location.href);
      url.searchParams.set("lang", lang);
      location.href = url.toString();
    });
  }

  /* ---------- TOC scrollspy ---------- */
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc-nav a[href^='#']"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var map = {};
    tocLinks.forEach(function (a) {
      var id = a.getAttribute("href").slice(1);
      var el = document.getElementById(id);
      if (el) map[id] = a;
    });
    var visible = {};
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) visible[en.target.id] = en.intersectionRatio;
        else delete visible[en.target.id];
      });
      var bestId = null, best = -1;
      Object.keys(visible).forEach(function (id) {
        if (visible[id] > best) { best = visible[id]; bestId = id; }
      });
      if (bestId) {
        tocLinks.forEach(function (a) { a.classList.remove("current"); });
        var link = map[bestId];
        if (link) {
          link.classList.add("current");
          var aside = document.getElementById("docAside");
          if (aside && aside.scrollHeight > aside.clientHeight) {
            var ar = aside.getBoundingClientRect();
            var lr = link.getBoundingClientRect();
            if (lr.top < ar.top + 8 || lr.bottom > ar.bottom - 8) {
              aside.scrollTop += lr.top - (ar.top + ar.height / 2);
            }
          }
        }
      }
    }, { rootMargin: "-70px 0px -55% 0px", threshold: [0, .2, .6, 1] });
    Object.keys(map).forEach(function (id) { io.observe(document.getElementById(id)); });
  }

  /* ---------- announcement bar ---------- */
  var annClose = document.getElementById("announceClose");
  if (annClose) {
    annClose.addEventListener("click", function () {
      var bar = annClose.closest(".announce-bar");
      if (bar) bar.remove();
    });
  }

  /* ---------- remember visited doc language for in-app consistency ---------- */
  try {
    var l = params.get("lang") || params.get("hl");
    if (l) localStorage.setItem("boji-lang", l);
  } catch (e) {}
})();

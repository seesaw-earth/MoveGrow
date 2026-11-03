/* MoveGrow website — Copyright (C) 2026 Ziqing Shi — SPDX-License-Identifier: AGPL-3.0-only
   If the browser prefers Chinese or Spanish and this page is in another language, offer the
   matching page once (no automatic redirect; the choice to dismiss is remembered on this device). */
(function () {
  "use strict";
  var bar = document.getElementById("lang-hint");
  if (!bar) return;
  var key = "movegrow-lang-hint";
  try { if (localStorage.getItem(key)) return; } catch (e) { return; }
  var page = document.documentElement.lang || "en";
  var want = ((navigator.languages && navigator.languages[0]) || navigator.language || "en").toLowerCase();
  var target = want.indexOf("zh") === 0 ? "zh" : (want.indexOf("es") === 0 ? "es" : "en");
  if (page.toLowerCase().indexOf(target) === 0) return;
  var offer = bar.querySelector('[data-offer="' + target + '"]');
  if (!offer) return;
  offer.hidden = false;
  bar.hidden = false;
  offer.querySelector("button").addEventListener("click", function () {
    bar.hidden = true;
    try { localStorage.setItem(key, "dismissed"); } catch (e) {}
  });
})();

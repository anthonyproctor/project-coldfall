// Shared by / and /guide. Kept out of the HTML so the CSP can say script-src 'self'.
(function () {
    var status = document.getElementById("copy-status");
    document.querySelectorAll("[data-copy]").forEach(function (b) {
      b.addEventListener("click", function () {
        var el = document.getElementById(b.dataset.copy), t = el.textContent;
        var say = function (msg, label) {
          status.textContent = msg; b.textContent = label;
          setTimeout(function () { b.textContent = "Copy"; }, 1800);
        };
        var select = function () {
          var r = document.createRange(); r.selectNodeContents(el);
          var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          say("Selected. Press Command C to copy.", "Selected");
        };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(t).then(function () { say("Command copied.", "Copied"); }, select);
        } else { select(); }
      });
    });
    var h = document.querySelector("header");
    var onScroll = function () { h.classList.toggle("scrolled", window.scrollY > 8); };
    window.addEventListener("scroll", onScroll, { passive: true }); onScroll();

    // Small-screen menu: a disclosure button that shows the header links.
    // The button stays hidden without JS, so the page never shows a dead control.
    var menu = h.querySelector(".menu-btn"), links = document.getElementById("nav-links");
    if (menu && links) {
      menu.hidden = false;
      var setOpen = function (open) {
        h.classList.toggle("open", open);
        menu.setAttribute("aria-expanded", open ? "true" : "false");
      };
      var isOpen = function () { return menu.getAttribute("aria-expanded") === "true"; };
      menu.addEventListener("click", function () { setOpen(!isOpen()); });
      links.addEventListener("click", function (e) { if (e.target.closest("a")) setOpen(false); });
      document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && isOpen()) { setOpen(false); menu.focus(); }
      });
      document.addEventListener("click", function (e) { if (isOpen() && !h.contains(e.target)) setOpen(false); });
      h.addEventListener("focusout", function (e) { if (isOpen() && e.relatedTarget && !h.contains(e.relatedTarget)) setOpen(false); });
      window.matchMedia("(min-width: 881px)").addEventListener("change", function (m) { if (m.matches) setOpen(false); });
    }
})();

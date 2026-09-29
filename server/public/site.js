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
})();

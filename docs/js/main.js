/* ============================================================
   OpenFortiMac landing page scripts
   ============================================================ */

(function () {
  'use strict';

  /**
   * Update the copyright year in the footer so it never gets stale.
   */
  function updateYear() {
    var el = document.getElementById('year');
    if (el) {
      el.textContent = new Date().getFullYear();
    }
  }

  /**
   * Reveal .reveal elements as they scroll into view.
   * Falls back to showing everything if IntersectionObserver is unavailable.
   */
  function setupScrollReveal() {
    var items = document.querySelectorAll('.reveal');
    if (!items.length) return;

    if (!('IntersectionObserver' in window)) {
      items.forEach(function (el) { el.classList.add('is-visible'); });
      return;
    }

    var observer = new IntersectionObserver(function (entries, obs) {
      entries.forEach(function (entry, index) {
        if (entry.isIntersecting) {
          // Stagger sibling cards slightly for a nicer cascade.
          entry.target.style.transitionDelay = (index * 60) + 'ms';
          entry.target.classList.add('is-visible');
          obs.unobserve(entry.target);
        }
      });
    }, {
      threshold: 0.12,
      rootMargin: '0px 0px -40px 0px'
    });

    items.forEach(function (el) { observer.observe(el); });
  }

  /**
   * Smooth scroll for in-page anchor links (if any get added later).
   */
  function setupSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach(function (link) {
      link.addEventListener('click', function (e) {
        var id = link.getAttribute('href');
        if (id.length <= 1) return;
        var target = document.querySelector(id);
        if (!target) return;
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });
  }

  /**
   * Copy buttons: copy their data-copy text and confirm inline.
   * Without clipboard access the command gets selected for a manual copy.
   */
  function setupCopyButtons() {
    document.querySelectorAll('.copy-btn[data-copy]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var text = btn.getAttribute('data-copy');

        function showLabel(label) {
          btn.textContent = label;
          btn.classList.add('is-copied');
          setTimeout(function () {
            btn.textContent = 'copy';
            btn.classList.remove('is-copied');
          }, 1600);
        }

        function confirmCopied() {
          showLabel('copied');
        }

        function selectCommand() {
          var target = btn.parentNode.querySelector('.install-text');
          if (!target) return;
          var range = document.createRange();
          range.selectNodeContents(target);
          var selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          showLabel('⌘C to copy');
        }

        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(confirmCopied, selectCommand);
        } else {
          selectCommand();
        }
      });
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    updateYear();
    setupScrollReveal();
    setupSmoothScroll();
    setupCopyButtons();
  });
})();
/*
 * Flow theme controller
 *
 * Preference values:
 *   "system" – follow the device setting (default)
 *   "light"  – always light
 *   "dark"   – always dark
 *
 * The preference is saved in localStorage. A small inline script in <head>
 * applies the saved choice before first paint so the page never flashes.
 */
(function () {
  var STORAGE_KEY = "flow-theme";
  var THEME_COLORS = { light: "#ffffff", dark: "#181b22" };
  var root = document.documentElement;
  var media = window.matchMedia("(prefers-color-scheme: dark)");

  function readPref() {
    try {
      var v = localStorage.getItem(STORAGE_KEY);
      return v === "light" || v === "dark" ? v : "system";
    } catch (e) {
      return "system";
    }
  }

  function savePref(pref) {
    try {
      if (pref === "system") localStorage.removeItem(STORAGE_KEY);
      else localStorage.setItem(STORAGE_KEY, pref);
    } catch (e) {
      /* storage blocked (private mode) – still works for this visit */
    }
  }

  function resolve(pref) {
    if (pref === "system") return media.matches ? "dark" : "light";
    return pref;
  }

  function apply(pref) {
    var resolved = resolve(pref);

    if (pref === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", pref);
    root.setAttribute("data-resolved-theme", resolved);

    // Colour of the mobile browser bar / status bar
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    for (var i = 0; i < metas.length; i++) {
      metas[i].setAttribute("content", THEME_COLORS[resolved]);
    }

    // Update controls
    var options = document.querySelectorAll("[data-theme-option]");
    for (var j = 0; j < options.length; j++) {
      var on = options[j].getAttribute("data-theme-option") === pref;
      options[j].setAttribute("aria-checked", on ? "true" : "false");
      options[j].tabIndex = on ? 0 : -1;
    }
    var toggles = document.querySelectorAll("[data-theme-toggle]");
    for (var k = 0; k < toggles.length; k++) {
      var label = resolved === "dark" ? "เปลี่ยนเป็นโหมดสว่าง" : "เปลี่ยนเป็นโหมดมืด";
      toggles[k].setAttribute("aria-label", label);
      toggles[k].setAttribute("title", label);
    }
  }

  function setPref(pref) {
    savePref(pref);
    apply(pref);
  }

  // Quick toggle: switch to the opposite of what is shown now.
  // If that matches the device setting, go back to "system" automatically.
  function toggle() {
    var next = resolve(readPref()) === "dark" ? "light" : "dark";
    var systemTheme = media.matches ? "dark" : "light";
    setPref(next === systemTheme ? "system" : next);
  }

  // React when the device switches light/dark (only matters in "system" mode)
  function onSystemChange() {
    if (readPref() === "system") apply("system");
  }
  if (media.addEventListener) media.addEventListener("change", onSystemChange);
  else if (media.addListener) media.addListener(onSystemChange);

  // Keep multiple tabs in sync
  window.addEventListener("storage", function (e) {
    if (e.key === STORAGE_KEY) apply(readPref());
  });

  document.addEventListener("click", function (e) {
    var opt = e.target.closest("[data-theme-option]");
    if (opt) {
      setPref(opt.getAttribute("data-theme-option"));
      return;
    }
    if (e.target.closest("[data-theme-toggle]")) toggle();
  });

  // Arrow-key navigation inside the radiogroup
  document.addEventListener("keydown", function (e) {
    var opt = e.target.closest && e.target.closest("[data-theme-option]");
    if (!opt) return;
    var keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
    if (!(e.key in keys)) return;
    e.preventDefault();
    var group = Array.prototype.slice.call(
      opt.parentNode.querySelectorAll("[data-theme-option]")
    );
    var idx = (group.indexOf(opt) + keys[e.key] + group.length) % group.length;
    group[idx].focus();
    setPref(group[idx].getAttribute("data-theme-option"));
  });

  window.FlowTheme = { get: readPref, set: setPref, toggle: toggle };

  apply(readPref());
})();

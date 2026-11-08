// Hearth website behavior: theme toggle, header edge, scroll reveals, the phone demo chat and the town map.
// Makes no network requests and sets no cookies. The only thing it stores is your light/dark choice.
(() => {
  "use strict";
  window.__hearthSite = true;

  const root = document.documentElement;
  const THEME_KEY = "hearth-site-theme";
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const prefersLight = window.matchMedia("(prefers-color-scheme: light)");
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // ---------- Theme ----------
  const currentTheme = () => root.dataset.theme || (prefersLight.matches ? "light" : "dark");

  function syncThemeUI() {
    const theme = currentTheme();
    const next = theme === "dark" ? "light" : "dark";
    document.querySelectorAll("[data-theme-toggle]").forEach((btn) => {
      btn.setAttribute("aria-label", `Switch to ${next} theme`);
      btn.title = `Switch to ${next} theme`;
    });
    document.querySelectorAll('meta[name="theme-color"]').forEach((meta) => {
      if (root.dataset.theme) meta.setAttribute("content", theme === "dark" ? "#141110" : "#FBF7F2");
    });
  }

  document.querySelectorAll("[data-theme-toggle]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const next = currentTheme() === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* storage blocked: theme still changes */ }
      syncThemeUI();
    });
  });
  prefersLight.addEventListener("change", syncThemeUI);
  syncThemeUI();

  // ---------- Header edge once the page scrolls ----------
  const header = document.querySelector(".site-header");
  if (header) {
    const onScroll = () => header.classList.toggle("is-scrolled", window.scrollY > 4);
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  // ---------- Fade sections in as they scroll into view ----------
  const reveals = document.querySelectorAll(".reveal");
  if (reveals.length) {
    if (reduceMotion || !("IntersectionObserver" in window)) {
      reveals.forEach((el) => el.classList.add("is-visible"));
    } else {
      const io = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
      reveals.forEach((el) => io.observe(el));
    }
  }

  // ---------- Table of contents highlight (privacy, safety) ----------
  // The current section is the last one whose top has passed 30% of the window (the last one at the bottom).
  const tocLinks = [...document.querySelectorAll(".toc a[href^='#']")];
  const tocSections = tocLinks.map((a) => document.getElementById(a.getAttribute("href").slice(1))).filter(Boolean);
  if (tocSections.length) {
    let ticking = false;
    const updateToc = () => {
      ticking = false;
      const line = window.innerHeight * 0.3;
      const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
      let current = tocSections[0];
      tocSections.forEach((section) => { if (section.getBoundingClientRect().top <= line) current = section; });
      if (atBottom) current = tocSections[tocSections.length - 1];
      tocLinks.forEach((a) => a.classList.toggle("is-current", a.getAttribute("href") === `#${current.id}`));
    };
    window.addEventListener("scroll", () => {
      if (!ticking) { ticking = true; requestAnimationFrame(updateToc); }
    }, { passive: true });
    updateToc();
  }

  // ---------- Phone demo: a short scripted chat that plays when visible ----------
  // The messages are written in the HTML (so the chat reads fine without JS); this only sequences them.
  function initPhoneDemo(phone) {
    const thread = phone.querySelector("[data-demo]");
    const typingRow = phone.querySelector(".pm-typing-row");
    const composer = phone.querySelector(".pm-composer");
    const input = composer && composer.querySelector(".pm-input");
    if (!thread || !typingRow || !input) return;

    const steps = [...thread.querySelectorAll(".pm-msg:not(.pm-typing-row)")];
    const placeholder = input.textContent;

    if (reduceMotion) {
      steps.forEach((el) => el.classList.add("is-shown"));
      return;
    }

    let visible = false;
    let playing = false;

    async function typeInComposer(text) {
      input.textContent = "";
      input.classList.add("has-text");
      for (const ch of text) {
        input.textContent += ch;
        await sleep(ch === " " ? 70 : 34 + Math.random() * 40);
      }
      composer.classList.add("is-ready");
      await sleep(420);
      composer.classList.remove("is-ready");
      input.classList.remove("has-text");
      input.textContent = placeholder;
    }

    async function playVoiceNote(el) {
      const bars = [...el.querySelectorAll(".pm-wave i")];
      const time = el.querySelector(".pm-time");
      const seconds = Number(el.dataset.seconds || 6);
      const total = time ? time.textContent : "";
      await sleep(500);
      for (let i = 0; i < bars.length; i++) {
        bars[i].classList.add("on");
        if (time) time.textContent = `0:${String(Math.min(seconds, Math.round(((i + 1) / bars.length) * seconds))).padStart(2, "0")}`;
        await sleep(95);
      }
      await sleep(500);
      bars.forEach((b) => b.classList.remove("on"));
      if (time) time.textContent = total;
    }

    async function play() {
      playing = true;
      steps.forEach((el) => el.classList.remove("is-shown", "is-in"));
      await sleep(600);
      for (const el of steps) {
        if (el.classList.contains("is-user")) {
          const text = el.querySelector(".pm-text");
          await typeInComposer(text ? text.textContent.trim() : "");
        } else {
          typingRow.hidden = false;
          await sleep(Number(el.dataset.think || 1200));
          typingRow.hidden = true;
        }
        el.classList.add("is-shown", "is-in");
        if (el.querySelector(".pm-voice")) await playVoiceNote(el);
        await sleep(Number(el.dataset.after || 900));
      }
      await sleep(7000);
      playing = false;
      if (visible && !document.hidden) play();
    }

    if ("IntersectionObserver" in window) {
      new IntersectionObserver((entries) => {
        visible = entries.some((e) => e.isIntersecting);
        if (visible && !playing) play();
      }, { threshold: 0.35 }).observe(phone);
    } else {
      visible = true;
      play();
    }
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && visible && !playing) play();
    });
  }
  document.querySelectorAll("[data-phone-demo]").forEach(initPhoneDemo);

  // ---------- Town map: who is where at each part of the day ----------
  // Same rule as the app: 5-11 morning, 11-17 afternoon, 17-22 evening, otherwise night (local time).
  function dayPartAt(date) {
    const h = date.getHours();
    if (h >= 5 && h < 11) return "morning";
    if (h >= 11 && h < 17) return "afternoon";
    if (h >= 17 && h < 22) return "evening";
    return "night";
  }

  function makeAvatar(person, className) {
    const wrap = document.createElement("span");
    wrap.className = `avatar ${className || ""}`.trim();
    wrap.style.setProperty("--a1", person.colors[0]);
    wrap.style.setProperty("--a2", person.colors[1]);
    const emoji = document.createElement("span");
    emoji.textContent = person.emoji;
    emoji.setAttribute("aria-hidden", "true");
    wrap.appendChild(emoji);
    if (person.art) {
      const img = document.createElement("img");
      img.alt = "";
      img.loading = "lazy";
      img.addEventListener("error", () => img.remove());
      img.src = person.art;
      wrap.appendChild(img);
    }
    return wrap;
  }

  function initTown(townEl) {
    const dataEl = document.getElementById(townEl.dataset.town);
    if (!dataEl) return;
    let data;
    try { data = JSON.parse(dataEl.textContent); } catch (e) { return; }

    const map = townEl.querySelector(".town-map");
    const list = townEl.querySelector(".town-now");
    const label = townEl.querySelector("[data-town-label]");
    const featured = townEl.querySelector("[data-town-featured]");
    const buttons = [...townEl.querySelectorAll(".daypart-switch button")];
    if (!map || !list) return;
    const residentsByID = new Map(data.residents.map((r) => [r.id, r]));
    const partPhrase = { morning: "In the morning", afternoon: "In the afternoon", evening: "In the evening", night: "At night" };
    const placeName = (loc) => (loc.name.startsWith("The ") ? `the ${loc.name.slice(4)}` : loc.name);
    const joinNames = (names) => (names.length < 2 ? names.join("") : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`);

    const nowPart = dayPartAt(new Date());
    const locations = new Map(data.locations.map((l) => [l.id, l]));

    // Location pins
    const pins = new Map();
    data.locations.forEach((loc) => {
      const pin = document.createElement("div");
      pin.className = "pin";
      pin.style.left = `${loc.x * 100}%`;
      pin.style.top = `${loc.y * 100}%`;
      const dot = document.createElement("span");
      dot.className = "pin-dot";
      dot.textContent = loc.emoji;
      dot.setAttribute("aria-hidden", "true");
      const name = document.createElement("span");
      name.className = "pin-name";
      name.textContent = loc.name;
      pin.append(dot, name);
      map.appendChild(pin);
      pins.set(loc.id, pin);
    });

    // Residents walking between places
    const walkers = new Map();
    data.residents.forEach((person) => {
      const walker = document.createElement("div");
      walker.className = "walker";
      walker.setAttribute("aria-hidden", "true");
      walker.title = person.name;
      walker.appendChild(makeAvatar(person));
      map.appendChild(walker);
      walkers.set(person.id, walker);
    });

    let currentPart = nowPart;
    function show(part) {
      currentPart = part;
      map.dataset.part = part;
      buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.part === part)));
      if (label) {
        label.textContent = part === nowPart ? `It's ${part} in ${data.town}` : `${part[0].toUpperCase()}${part.slice(1)} in ${data.town}`;
      }

      // Group residents by where they are now, then fan each group around its pin.
      const groups = new Map();
      data.residents.forEach((person) => {
        const slot = person.schedule[part] || person.schedule.home;
        if (!slot || !locations.has(slot.at)) return;
        if (!groups.has(slot.at)) groups.set(slot.at, []);
        groups.get(slot.at).push({ person, slot });
      });

      pins.forEach((pin, id) => pin.classList.toggle("is-busy", groups.has(id)));

      // Each busy place gets a small stack of avatars just above its pin.
      const small = map.clientWidth < 440;
      const step = small ? 17 : 22;
      const lift = small ? 29 : 37;
      groups.forEach((people, locID) => {
        const loc = locations.get(locID);
        // A place near the top edge has no room above it, so its stack sits to the right of the pin.
        const beside = loc.y * map.clientHeight < lift + 14;
        people.forEach(({ person, slot }, i) => {
          const dx = beside ? lift - 4 + i * step : (i - (people.length - 1) / 2) * step;
          const walker = walkers.get(person.id);
          walker.style.left = `calc(${loc.x * 100}% + ${dx}px)`;
          walker.style.top = beside ? `${loc.y * 100}%` : `calc(${loc.y * 100}% - ${lift}px)`;
          walker.style.zIndex = String(10 + i);
          walker.title = `${person.name}: ${slot.doing}`;
        });
      });

      // One resident's moment, then who is where, busiest places first.
      const star = data.featured && residentsByID.get(data.featured[part]);
      const starSlot = star && (star.schedule[part] || star.schedule.home);
      if (featured && starSlot && locations.has(starSlot.at)) {
        const lead = part === nowPart ? "Right now" : partPhrase[part];
        featured.textContent = `${lead}, ${star.name} is at ${placeName(locations.get(starSlot.at))}, ${starSlot.doing}.`;
      }
      list.textContent = "";
      [...groups.entries()]
        .sort((a, b) => b[1].length - a[1].length)
        .forEach(([locID, people]) => {
          const loc = locations.get(locID);
          const li = document.createElement("li");
          const place = document.createElement("span");
          place.className = "place";
          const icon = document.createElement("span");
          icon.setAttribute("aria-hidden", "true");
          icon.textContent = loc.emoji;
          place.append(icon, ` ${loc.name}`);
          const who = document.createElement("span");
          who.className = "who";
          who.textContent = joinNames(people.map(({ person }) => person.name));
          li.append(place, who);
          list.appendChild(li);
        });
    }

    buttons.forEach((b) => {
      if (b.dataset.part === nowPart) b.insertAdjacentHTML("beforeend", '<span class="visually-hidden"> (now)</span>');
      b.addEventListener("click", () => show(b.dataset.part));
    });
    show(nowPart);
    // Announce later changes (a tapped time of day), not the first render.
    if (featured) featured.setAttribute("aria-live", "polite");

    // Avatar offsets depend on the map's size, so lay them out again after a resize.
    let resizeTimer;
    window.addEventListener("resize", () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => show(currentPart), 150);
    });
  }
  document.querySelectorAll("[data-town]").forEach(initTown);
})();

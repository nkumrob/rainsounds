/* rain sounds — endless rain, three moods.
   AudioEngine: gapless Web Audio loops with equal-power crossfade.
   RainCanvas: generative rain whose weather morphs with the mood.
   UI: wiring, idle fade, keyboard, Media Session, persistence. */

"use strict";

const MOODS = {
  drizzle: {
    file: "audio/drizzle.wav",
    desc: "a light patter, barely there",
    rain: { count: 300, speed: 9, length: 20, width: 1.0, slant: 0.06, bright: 0.65 },
  },
  downpour: {
    file: "audio/downpour.wav",
    desc: "heavy, steady, all around you",
    rain: { count: 760, speed: 17, length: 38, width: 1.4, slant: 0.1, bright: 0.95 },
  },
  tent: {
    file: "audio/tent.wav",
    desc: "rain on canvas, thunder far away",
    rain: { count: 520, speed: 13, length: 28, width: 1.2, slant: 0.14, bright: 0.8, flashes: true },
  },
};
const DEFAULT_MOOD = "downpour";
const CROSSFADE = 2.0;           // s, audio + visual morph
const LOOP_TRIM = 0;             // WAV has no encoder padding; loop the full buffer
const store = {
  get: (k, d) => { try { return localStorage.getItem("rain." + k) ?? d; } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem("rain." + k, v); } catch {} },
};
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

/* ---------- AudioEngine ---------- */

const AudioEngine = {
  ctx: null,
  master: null,
  buffers: {},
  current: null,        // { source, gain, mood }
  fallback: null,       // <audio> element when Web Audio is unavailable
  volume: 0.8,
  playing: false,

  async init() {
    try {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this.master = this.ctx.createGain();
      this.master.gain.value = this.volume;
      this.master.connect(this.ctx.destination);
    } catch {
      this.ctx = null; // fallback path
    }
  },

  async load(mood) {
    if (!this.ctx || this.buffers[mood]) return;
    const fetchOnce = () => fetch(MOODS[mood].file).then((r) => {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.arrayBuffer();
    });
    let data;
    try { data = await fetchOnce(); }
    catch { data = await fetchOnce(); } // one quiet retry
    this.buffers[mood] = await this.ctx.decodeAudioData(data);
  },

  _startSource(mood, when, gainAt) {
    const buf = this.buffers[mood];
    const source = this.ctx.createBufferSource();
    source.buffer = buf;
    source.loop = true;
    source.loopStart = LOOP_TRIM;
    source.loopEnd = buf.duration - LOOP_TRIM;
    const gain = this.ctx.createGain();
    gain.gain.value = gainAt;
    source.connect(gain).connect(this.master);
    source.start(when, LOOP_TRIM);
    return { source, gain, mood };
  },

  async play(mood) {
    if (!this.ctx) return this._playFallback(mood);
    await this.ctx.resume();
    try {
      await this.load(mood);
    } catch {
      // decode/fetch failed (e.g. codec-less browser build): drop to <audio>
      this.ctx = null;
      return this._playFallback(mood);
    }
    const t = this.ctx.currentTime;
    if (this.current && this.current.mood === mood && this.playing) return;

    if (this.current) {
      // equal-power crossfade out the old voice
      const old = this.current;
      old.gain.gain.setValueAtTime(old.gain.gain.value, t);
      old.gain.gain.linearRampToValueAtTime(0, t + CROSSFADE);
      old.source.stop(t + CROSSFADE + 0.1);
      const next = this._startSource(mood, t, 0);
      next.gain.gain.linearRampToValueAtTime(1, t + CROSSFADE);
      this.current = next;
    } else {
      const next = this._startSource(mood, t, 0);
      next.gain.gain.linearRampToValueAtTime(1, t + Math.min(CROSSFADE, 1.2));
      this.current = next;
    }
    this.playing = true;
  },

  pause() {
    if (!this.ctx) { this.fallback?.pause(); this.playing = false; return; }
    this.ctx.suspend();
    this.playing = false;
  },

  resume() {
    if (!this.ctx) { this.fallback?.play(); this.playing = true; return; }
    this.ctx.resume();
    this.playing = true;
  },

  setVolume(v) {
    this.volume = v;
    if (this.ctx) {
      this.master.gain.setTargetAtTime(v, this.ctx.currentTime, 0.05);
    } else if (this.fallback) {
      this.fallback.volume = v;
    }
  },

  /* Sleep timer: fade master to 0 over `fadeS`, then signal done. */
  fadeOut(fadeS, onDone) {
    if (this.ctx) {
      const t = this.ctx.currentTime;
      this.master.gain.setValueAtTime(this.master.gain.value, t);
      this.master.gain.linearRampToValueAtTime(0.0001, t + fadeS);
      setTimeout(() => {
        this.pause();
        this.master.gain.setValueAtTime(this.volume, this.ctx.currentTime);
        onDone();
      }, fadeS * 1000);
    } else {
      const el = this.fallback;
      if (!el) return onDone();
      const step = el.volume / (fadeS * 10);
      const iv = setInterval(() => {
        el.volume = Math.max(0, el.volume - step);
        if (el.volume <= 0.001) {
          clearInterval(iv);
          el.pause(); el.volume = this.volume;
          onDone();
        }
      }, 100);
    }
  },

  _playFallback(mood) {
    // <audio loop> accepts a faint seam click; better than a silent page
    if (this.fallback) { this.fallback.pause(); this.fallback.remove(); }
    const el = new Audio(MOODS[mood].file);
    el.loop = true;
    el.volume = this.volume;
    this.fallback = el;
    this.playing = true;
    return el.play().catch(() => {});
  },
};

/* ---------- RainCanvas ---------- */

const THEMES = {
  night: { streak: [168, 196, 230], alphaBoost: 1.0, flash: "rgba(190, 210, 240, ALPHA)" },
  day:   { streak: [30, 44, 64],    alphaBoost: 2.4, flash: "rgba(255, 255, 255, ALPHA)" },
};

const RainCanvas = {
  canvas: null, ctx: null, drops: [],
  params: { ...MOODS[DEFAULT_MOOD].rain },   // live (lerped) weather
  target: { ...MOODS[DEFAULT_MOOD].rain },
  theme: "night",
  running: false,
  intensity: 0,          // 0→1 global ramp (begin moment, pause)
  targetIntensity: 0,
  wind: 0, windT: 0,
  flash: 0, nextFlash: Infinity,
  raf: 0, lastT: 0,

  init(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.resize();
    addEventListener("resize", () => this.resize());
    this.seed();
    if (reducedMotion.matches) this.renderStill();
  },

  resize() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    this.canvas.width = innerWidth * dpr;
    this.canvas.height = innerHeight * dpr;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = innerWidth; this.h = innerHeight;
    if (reducedMotion.matches) this.renderStill();
  },

  seed() {
    // three depth layers: far 45%, mid 35%, near 20%
    this.drops = [];
    const max = 900; // cap; density comes from params.count
    for (let i = 0; i < max; i++) {
      const depth = i < max * 0.45 ? 0.35 : i < max * 0.8 ? 0.65 : 1;
      this.drops.push({
        x: Math.random() * 1.2 - 0.1,  // normalized, spill past edges
        y: Math.random(),
        depth,
        jitter: Math.random() * 0.6 + 0.7,
      });
    }
  },

  setMood(mood) {
    this.target = { ...MOODS[mood].rain };
    this.nextFlash = this.target.flashes ? this.now() + 6 + Math.random() * 18 : Infinity;
  },

  setTheme(theme) { this.theme = theme; if (reducedMotion.matches) this.renderStill(); },
  now() { return performance.now() / 1000; },

  start() {
    this.targetIntensity = 1;
    if (reducedMotion.matches) { this.renderStill(); return; }
    if (!this.running) {
      this.running = true;
      this.lastT = this.now();
      this.raf = requestAnimationFrame(() => this.frame());
    }
  },

  calm() { this.targetIntensity = 0.25; },   // paused: the rain eases, never dies

  frame() {
    if (!this.running) return;
    const t = this.now();
    const dt = Math.min(t - this.lastT, 0.05);
    this.lastT = t;

    // lerp weather toward the mood target — the "changing weather" moment
    const k = 1 - Math.exp(-dt / (CROSSFADE * 0.45));
    for (const p of ["count", "speed", "length", "width", "slant", "bright"]) {
      this.params[p] += (this.target[p] - this.params[p]) * k;
    }
    this.intensity += (this.targetIntensity - this.intensity) * (1 - Math.exp(-dt / 0.9));

    // slow wind oscillation
    this.windT += dt;
    this.wind = Math.sin(this.windT * 0.13) * 0.5 + Math.sin(this.windT * 0.041) * 0.5;

    // distant flash (tent)
    if (t > this.nextFlash) {
      this.flash = 1;
      this.nextFlash = t + 14 + Math.random() * 26;
    }
    this.flash = Math.max(0, this.flash - dt * 2.2);

    this.draw(dt);
    this.raf = requestAnimationFrame(() => this.frame());
  },

  draw(dt) {
    const { ctx, w, h } = this;
    ctx.clearRect(0, 0, w, h);

    if (this.flash > 0.01) {
      const a = Math.pow(this.flash, 2.2) * 0.16;
      ctx.fillStyle = THEMES[this.theme].flash.replace("ALPHA", a.toFixed(3));
      ctx.fillRect(0, 0, w, h);
    }

    const { streak: [r, g, b], alphaBoost } = THEMES[this.theme];
    const visible = Math.floor(this.params.count * this.intensity);
    const slant = this.params.slant + this.wind * 0.045;

    ctx.lineCap = "round";
    for (let i = 0; i < visible; i++) {
      const d = this.drops[i];
      const speed = this.params.speed * d.depth * d.jitter;
      d.y += speed * dt * 0.06;
      d.x += slant * speed * dt * 0.06;
      if (d.y > 1.05) { d.y = -0.08; d.x = Math.random() * 1.2 - 0.1; }
      if (d.x > 1.1) d.x -= 1.2;

      const len = this.params.length * d.depth * d.jitter;
      const alpha = Math.min(0.85, this.params.bright * d.depth * 0.75 * alphaBoost) * this.intensity;
      ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, ${alpha.toFixed(3)})`;
      ctx.lineWidth = this.params.width * d.depth;
      const x = d.x * w, y = d.y * h;
      ctx.beginPath();
      ctx.moveTo(x, y);
      ctx.lineTo(x - len * slant, y - len);
      ctx.stroke();
    }
  },

  /* reduced motion: a still, mist-like field instead of falling rain */
  renderStill() {
    const { ctx, w, h } = this;
    if (!ctx) return;
    ctx.clearRect(0, 0, w, h);
    const [r, g, b] = THEMES[this.theme].streak;
    for (let i = 0; i < 340; i++) {
      const x = Math.random() * w, y = Math.random() * h;
      const rad = Math.random() * 1.6 + 0.4;
      ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${(Math.random() * 0.14 + 0.03).toFixed(3)})`;
      ctx.beginPath();
      ctx.arc(x, y, rad, 0, Math.PI * 2);
      ctx.fill();
    }
  },
};

/* ---------- UI ---------- */

const UI = {
  mood: store.get("mood", DEFAULT_MOOD) in MOODS ? store.get("mood", DEFAULT_MOOD) : DEFAULT_MOOD,
  wakeWanted: store.get("wake", "0") === "1",
  wakeLock: null,
  idleTimer: 0,
  sleepEnd: 0, sleepTick: 0,
  TIMER_STEPS: [0, 15, 30, 60],
  timerStep: 0,

  el(id) { return document.getElementById(id); },

  async init() {
    RainCanvas.init(this.el("rain"));

    const theme = store.get("theme", "night");
    this.applyTheme(theme, true);

    AudioEngine.volume = Math.min(1, Math.max(0, parseFloat(store.get("volume", "0.8"))));
    this.el("volume").value = Math.round(AudioEngine.volume * 100);

    await AudioEngine.init();

    this.el("begin").addEventListener("click", () => this.begin());
    this.el("play").addEventListener("click", () => this.togglePlay());
    this.el("theme").addEventListener("click", () =>
      this.applyTheme(document.documentElement.dataset.theme === "night" ? "day" : "night"));
    this.el("timer").addEventListener("click", () => this.cycleTimer());
    const about = this.el("about");
    const showAbout = (on) => { about.hidden = !on; };
    this.el("about-open").addEventListener("click", () => showAbout(true));
    this.el("about-open-2").addEventListener("click", () => showAbout(true));
    this.el("about-close").addEventListener("click", () => showAbout(false));
    about.addEventListener("click", (e) => { if (e.target === about) showAbout(false); });
    if ("wakeLock" in navigator) {
      const wakeBtn = this.el("wake");
      wakeBtn.hidden = false;
      wakeBtn.setAttribute("aria-pressed", String(this.wakeWanted));
      wakeBtn.addEventListener("click", () => this.toggleWake());
      // the OS drops the lock when the tab hides; take it back on return
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") this.syncWake();
      });
    }
    this.el("volume").addEventListener("input", (e) => {
      const v = e.target.valueAsNumber / 100;
      AudioEngine.setVolume(v);
      store.set("volume", v);
    });
    document.querySelectorAll(".mood").forEach((btn) =>
      btn.addEventListener("click", () => this.switchMood(btn.dataset.mood)));

    document.addEventListener("keydown", (e) => this.onKey(e));
    ["pointermove", "pointerdown", "touchstart"].forEach((ev) =>
      document.addEventListener(ev, () => this.wake(), { passive: true }));

    this.markActiveMood();
    // the rain footage runs from the first moment — the intro floats on it
    this.videoStart();
    // warm the default mood's bytes while the visitor reads the intro
    AudioEngine.load(this.mood).catch(() => {});
  },

  async begin() {
    try {
      await AudioEngine.play(this.mood);
    } catch {
      const note = this.el("intro-note");
      note.hidden = false;
      note.textContent = "the rain could not load — check your connection and try again.";
      return;
    }
    this.el("intro").classList.add("gone");
    this.el("brand").hidden = false;
    this.el("controls").hidden = false;
    document.body.classList.remove("paused");
    this.videoStart();
    RainCanvas.setMood(this.mood);
    RainCanvas.start();
    this.setDesc(MOODS[this.mood].desc);
    this.mediaSession();
    this.syncWake();
    this.wake();
  },

  async switchMood(mood) {
    if (!(mood in MOODS) || mood === this.mood) return;
    this.mood = mood;
    store.set("mood", mood);
    this.markActiveMood();
    this.setDesc(MOODS[mood].desc);
    RainCanvas.setMood(mood);
    if (AudioEngine.playing || AudioEngine.ctx) await AudioEngine.play(mood);
    if (!AudioEngine.playing) this.togglePlay(true);
    this.mediaSession();
  },

  togglePlay(forcePlay) {
    const video = this.el("bgvideo");
    if (AudioEngine.playing && !forcePlay) {
      AudioEngine.pause();
      document.body.classList.add("paused");
      RainCanvas.calm();
      video.pause();
    } else {
      AudioEngine.resume();
      document.body.classList.remove("paused");
      RainCanvas.start();
      if (!reducedMotion.matches) video.play().catch(() => {});
    }
    this.syncWake();
    if (navigator.mediaSession) {
      navigator.mediaSession.playbackState = AudioEngine.playing ? "playing" : "paused";
    }
  },

  toggleWake() {
    this.wakeWanted = !this.wakeWanted;
    store.set("wake", this.wakeWanted ? "1" : "0");
    this.el("wake").setAttribute("aria-pressed", String(this.wakeWanted));
    this.syncWake();
  },

  /* hold the screen-wake lock only while wanted AND playing */
  async syncWake() {
    if (!("wakeLock" in navigator)) return;
    if (this.wakeWanted && AudioEngine.playing) {
      if (this.wakeLock && !this.wakeLock.released) return;
      try { this.wakeLock = await navigator.wakeLock.request("screen"); } catch {}
    } else if (this.wakeLock) {
      this.wakeLock.release().catch(() => {});
      this.wakeLock = null;
    }
  },

  videoStart() {
    // real rain footage under the generative streaks; skipped for
    // reduced-motion visitors, and a load failure just leaves the gradient
    if (reducedMotion.matches) return;
    const video = this.el("bgvideo");
    video.play().then(() => video.classList.add("on")).catch(() => {});
  },

  markActiveMood() {
    document.querySelectorAll(".mood").forEach((b) =>
      b.classList.toggle("active", b.dataset.mood === this.mood));
  },

  setDesc(text) {
    const el = this.el("mood-desc");
    el.classList.add("swap");
    setTimeout(() => { el.textContent = text; el.classList.remove("swap"); }, 300);
  },

  applyTheme(theme, silent) {
    document.documentElement.dataset.theme = theme;
    document.querySelector('meta[name="theme-color"]')
      .setAttribute("content", theme === "night" ? "#070b12" : "#b6c2cf");
    this.el("theme").setAttribute("aria-label",
      theme === "night" ? "Switch to day" : "Switch to night");
    RainCanvas.setTheme(theme);
    if (!silent) store.set("theme", theme);
  },

  cycleTimer() {
    this.timerStep = (this.timerStep + 1) % this.TIMER_STEPS.length;
    const mins = this.TIMER_STEPS[this.timerStep];
    clearInterval(this.sleepTick);
    const btn = this.el("timer");
    if (!mins) {
      btn.textContent = "timer";
      btn.classList.remove("armed");
      this.sleepEnd = 0;
      return;
    }
    btn.classList.add("armed");
    this.sleepEnd = Date.now() + mins * 60000;
    const render = () => {
      const left = this.sleepEnd - Date.now();
      if (left <= 0) {
        clearInterval(this.sleepTick);
        this.timerStep = 0;
        btn.textContent = "timer";
        btn.classList.remove("armed");
        // the long goodnight: a slow minute-long fade, then sleep
        AudioEngine.fadeOut(60, () => {
          document.body.classList.add("paused");
          RainCanvas.calm();
          this.el("bgvideo").pause();
          this.syncWake();   // let the screen sleep once the rain has faded
        });
        return;
      }
      btn.textContent = Math.ceil(left / 60000) + "m";
    };
    render();
    this.sleepTick = setInterval(render, 5000);
  },

  onKey(e) {
    if (e.target.tagName === "INPUT") return;
    if (e.code === "Escape") { this.el("about").hidden = true; return; }
    if (e.code === "Space") { e.preventDefault(); this.togglePlay(); }
    const keys = { Digit1: "drizzle", Digit2: "downpour", Digit3: "tent" };
    if (keys[e.code]) this.switchMood(keys[e.code]);
  },

  wake() {
    document.body.classList.remove("idle", "hide-cursor");
    clearTimeout(this.idleTimer);
    if (this.el("intro").classList.contains("gone")) {
      this.idleTimer = setTimeout(() => {
        document.body.classList.add("idle", "hide-cursor");
      }, 6000);
    }
  },

  mediaSession() {
    if (!("mediaSession" in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: "rain sounds",
      artist: this.mood,
      album: "endless rain",
    });
    navigator.mediaSession.setActionHandler("play", () => this.togglePlay(true));
    navigator.mediaSession.setActionHandler("pause", () => this.togglePlay());
  },
};

UI.init();

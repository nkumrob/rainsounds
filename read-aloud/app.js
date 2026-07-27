/* Read Aloud — client-side text-to-speech.
 *
 * Design notes:
 *  - Speech is chunked by sentence. Browsers (esp. Chrome) truncate or stall
 *    on very long single utterances, so we feed one sentence at a time and
 *    chain them. This also makes skip-forward / skip-back trivial.
 *  - Word highlighting uses the utterance `boundary` event, which reports a
 *    character index into the *current chunk*; we add the chunk's absolute
 *    offset to map it back onto the whole text.
 *  - Nothing is sent anywhere. All state lives in the page + localStorage.
 */
(function () {
  "use strict";

  var synth = window.speechSynthesis;
  var supported = "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;

  // ---- Elements ----
  var $ = function (id) { return document.getElementById(id); };
  var editor = $("editor");
  var reader = $("reader");
  var playBtn = $("play-btn");
  var stopBtn = $("stop-btn");
  var restartBtn = $("restart-btn");
  var voiceSel = $("voice");
  var rateInput = $("rate");
  var pitchInput = $("pitch");
  var rateVal = $("rate-val");
  var pitchVal = $("pitch-val");
  var progressBar = $("progress-bar");
  var progressLabel = $("progress-label");
  var counts = $("counts");
  var themeBtn = $("theme-btn");
  var sampleBtn = $("sample-btn");
  var clearBtn = $("clear-btn");

  var STORE = "readaloud.v1";
  var SAMPLE = "There is a particular kind of quiet that comes from being read to. " +
    "You paste a chapter, an article, or a long email here, choose a voice, and press play. " +
    "The words light up one at a time as they are spoken, so your eyes can rest — or follow along. " +
    "Nothing you type is uploaded anywhere; the voice comes straight from your own device. " +
    "Try changing the speed while it reads. Click any word to jump straight to it.";

  // ---- State ----
  var chunks = [];        // [{ text, start, end }] sentence spans over full text
  var wordEls = [];       // word <span> elements in reader, with .dataset.start
  var current = 0;        // index into chunks
  var speaking = false;
  var paused = false;
  var voices = [];

  // ---------- Persistence ----------
  function loadPrefs() {
    var p = {};
    try { p = JSON.parse(localStorage.getItem(STORE)) || {}; } catch (e) {}
    return p;
  }
  function savePrefs() {
    try {
      localStorage.setItem(STORE, JSON.stringify({
        theme: document.documentElement.getAttribute("data-theme"),
        rate: rateInput.value,
        pitch: pitchInput.value,
        voice: voiceSel.value,
        text: editor.value
      }));
    } catch (e) {}
  }

  // ---------- Theme ----------
  function applyTheme(t) {
    document.documentElement.setAttribute("data-theme", t);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", t === "night" ? "#16130f" : "#f6f4ef");
  }
  themeBtn.addEventListener("click", function () {
    var next = document.documentElement.getAttribute("data-theme") === "night" ? "day" : "night";
    applyTheme(next);
    savePrefs();
  });

  // ---------- Voices ----------
  function loadVoices() {
    voices = synth.getVoices();
    if (!voices.length) return;

    var prev = voiceSel.value;
    var wanted = loadPrefs().voice;
    voiceSel.innerHTML = "";

    // Prefer the current UI language, then group the rest.
    voices.sort(function (a, b) {
      var la = a.lang.slice(0, 2), lb = b.lang.slice(0, 2);
      var ui = (navigator.language || "en").slice(0, 2);
      if (la === ui && lb !== ui) return -1;
      if (lb === ui && la !== ui) return 1;
      return a.name.localeCompare(b.name);
    });

    voices.forEach(function (v, i) {
      var opt = document.createElement("option");
      opt.value = String(i);
      opt.textContent = v.name + " (" + v.lang + ")" + (v.default ? " — default" : "");
      voiceSel.appendChild(opt);
    });

    // Restore selection: explicit saved name > previous > default > first.
    var idx = -1;
    if (wanted) idx = voices.findIndex(function (v) { return v.name === wanted; });
    if (idx < 0 && prev) idx = parseInt(prev, 10);
    if (idx < 0) idx = voices.findIndex(function (v) { return v.default; });
    if (idx < 0) idx = 0;
    voiceSel.value = String(Math.max(0, idx));
  }

  // ---------- Text segmentation ----------
  // Split into sentence-ish chunks, tracking absolute char offsets so word
  // highlighting can map back onto the full text.
  function segment(text) {
    var out = [];
    // Match runs ending in sentence punctuation (or the final trailing run).
    var re = /[^.!?\n]*[.!?]+["'”’)]*|\n+|[^.!?\n]+$/g;
    var m;
    while ((m = re.exec(text)) !== null) {
      if (m[0] === "") { re.lastIndex++; continue; }
      var start = m.index;
      var raw = m[0];
      var end = start + raw.length;
      if (raw.trim() === "") continue; // skip pure whitespace/newlines as chunks
      // Speech engines choke past ~32k chars; hard-split very long sentences.
      if (raw.length > 300) {
        var pieces = raw.match(/[\s\S]{1,280}(\s|$)/g) || [raw];
        var off = start;
        pieces.forEach(function (pc) {
          out.push({ text: pc, start: off, end: off + pc.length });
          off += pc.length;
        });
      } else {
        out.push({ text: raw, start: start, end: end });
      }
    }
    return out;
  }

  // Build the read-along overlay: every word becomes a clickable span whose
  // dataset.start is its absolute char offset in the source text.
  function buildReader(text) {
    reader.innerHTML = "";
    wordEls = [];
    var frag = document.createDocumentFragment();
    var re = /\S+|\s+/g;
    var m;
    while ((m = re.exec(text)) !== null) {
      var tok = m[0];
      if (/\s/.test(tok[0])) {
        frag.appendChild(document.createTextNode(tok));
      } else {
        var span = document.createElement("span");
        span.className = "word";
        span.textContent = tok;
        span.dataset.start = String(m.index);
        wordEls.push(span);
        frag.appendChild(span);
      }
    }
    reader.appendChild(frag);
  }

  // ---------- Speaking ----------
  function totalChars() {
    return chunks.length ? chunks[chunks.length - 1].end : 0;
  }

  function updateProgress(absChar) {
    var total = totalChars() || 1;
    var pct = Math.min(100, Math.round((absChar / total) * 100));
    progressBar.style.width = pct + "%";
    progressLabel.textContent = pct + "%";
  }

  function highlightWordAt(absChar) {
    // Find the last word whose start <= absChar.
    var target = null;
    for (var i = 0; i < wordEls.length; i++) {
      if (parseInt(wordEls[i].dataset.start, 10) <= absChar) target = wordEls[i];
      else break;
    }
    for (var j = 0; j < wordEls.length; j++) wordEls[j].classList.remove("spoken");
    if (target) {
      target.classList.add("spoken");
      var r = target.getBoundingClientRect();
      if (r.top < 90 || r.bottom > window.innerHeight - 160) {
        target.scrollIntoView({ block: "center", behavior: "smooth" });
      }
    }
  }

  function speakFrom(index) {
    if (index >= chunks.length) { finish(); return; }
    current = index;
    synth.cancel(); // clear any queued utterance

    var chunk = chunks[index];
    var u = new SpeechSynthesisUtterance(chunk.text);
    if (voices[parseInt(voiceSel.value, 10)]) u.voice = voices[parseInt(voiceSel.value, 10)];
    u.rate = parseFloat(rateInput.value);
    u.pitch = parseFloat(pitchInput.value);

    u.onboundary = function (e) {
      var abs = chunk.start + (e.charIndex || 0);
      highlightWordAt(abs);
      updateProgress(abs);
    };
    u.onstart = function () {
      highlightWordAt(chunk.start);
      updateProgress(chunk.start);
    };
    u.onend = function () {
      if (!speaking) return;          // stopped by user
      if (current === index) speakFrom(index + 1);
    };
    u.onerror = function (ev) {
      if (ev.error === "interrupted" || ev.error === "canceled") return;
      if (speaking && current === index) speakFrom(index + 1);
    };

    synth.speak(u);
  }

  function start() {
    var text = editor.value.trim();
    if (!text) { editor.focus(); return; }

    chunks = segment(editor.value);
    if (!chunks.length) return;
    buildReader(editor.value);

    speaking = true;
    paused = false;
    document.body.classList.add("speaking");
    document.body.classList.remove("paused");
    editor.hidden = true;
    reader.hidden = false;
    reader.setAttribute("aria-hidden", "false");
    playBtn.setAttribute("aria-label", "Pause");
    speakFrom(0);
  }

  function finish() {
    speaking = false;
    paused = false;
    synth.cancel();
    document.body.classList.remove("speaking", "paused");
    playBtn.setAttribute("aria-label", "Play");
    progressLabel.textContent = "Done";
    progressBar.style.width = "100%";
    // Return to the editor after a beat.
    setTimeout(function () {
      if (!speaking) {
        reader.hidden = true;
        reader.setAttribute("aria-hidden", "true");
        editor.hidden = false;
        progressBar.style.width = "0%";
        progressLabel.textContent = "Ready";
      }
    }, 900);
  }

  function stop() {
    speaking = false;
    paused = false;
    synth.cancel();
    document.body.classList.remove("speaking", "paused");
    playBtn.setAttribute("aria-label", "Play");
    reader.hidden = true;
    reader.setAttribute("aria-hidden", "true");
    editor.hidden = false;
    progressBar.style.width = "0%";
    progressLabel.textContent = "Ready";
    wordEls.forEach(function (w) { w.classList.remove("spoken"); });
  }

  function togglePlay() {
    if (!supported) return;
    if (!speaking) { start(); return; }
    if (paused) {
      synth.resume();
      paused = false;
      document.body.classList.remove("paused");
      playBtn.setAttribute("aria-label", "Pause");
    } else {
      synth.pause();
      paused = true;
      document.body.classList.add("paused");
      playBtn.setAttribute("aria-label", "Play");
    }
  }

  function skip(dir) {
    if (!speaking) return;
    var next = Math.min(chunks.length, Math.max(0, current + dir));
    if (next === current && dir > 0) { finish(); return; }
    // resume() first so a paused synth actually advances
    if (paused) { paused = false; document.body.classList.remove("paused"); }
    speakFrom(next);
  }

  // ---------- Counts ----------
  function updateCounts() {
    var t = editor.value.trim();
    var words = t ? (t.match(/\S+/g) || []).length : 0;
    var mins = Math.max(1, Math.round(words / 180)); // ~180 wpm read-aloud
    counts.textContent = words === 0
      ? "0 words"
      : words + (words === 1 ? " word" : " words") + " · ~" + mins + " min";
  }

  // ---------- Wire up ----------
  function initControls() {
    playBtn.addEventListener("click", togglePlay);
    stopBtn.addEventListener("click", stop);
    restartBtn.addEventListener("click", function () {
      if (speaking) speakFrom(0); else start();
    });

    rateInput.addEventListener("input", function () {
      rateVal.textContent = parseFloat(rateInput.value).toFixed(1) + "×";
      savePrefs();
      // Apply live: restart the current sentence at the new rate.
      if (speaking && !paused) speakFrom(current);
    });
    pitchInput.addEventListener("input", function () {
      pitchVal.textContent = parseFloat(pitchInput.value).toFixed(1);
      savePrefs();
      if (speaking && !paused) speakFrom(current);
    });
    voiceSel.addEventListener("change", function () {
      savePrefs();
      if (speaking && !paused) speakFrom(current);
    });

    editor.addEventListener("input", function () { updateCounts(); savePrefs(); });

    sampleBtn.addEventListener("click", function () {
      editor.value = SAMPLE;
      updateCounts(); savePrefs(); editor.focus();
    });
    clearBtn.addEventListener("click", function () {
      stop();
      editor.value = "";
      updateCounts(); savePrefs(); editor.focus();
    });

    // Click a word in the reader to start reading from there.
    reader.addEventListener("click", function (e) {
      var el = e.target.closest(".word");
      if (!el) return;
      var abs = parseInt(el.dataset.start, 10);
      var idx = 0;
      for (var i = 0; i < chunks.length; i++) {
        if (chunks[i].start <= abs) idx = i; else break;
      }
      speakFrom(idx);
    });

    // Keyboard shortcuts (ignored while typing in the editor).
    document.addEventListener("keydown", function (e) {
      var typing = document.activeElement === editor;
      if (e.key === "t" || e.key === "T") {
        if (typing) return;
        themeBtn.click();
      } else if (e.code === "Space") {
        if (typing) return;
        e.preventDefault(); togglePlay();
      } else if (e.key === "Escape") {
        if (speaking) { e.preventDefault(); stop(); }
      } else if (e.key === "ArrowRight") {
        if (typing || !speaking) return;
        e.preventDefault(); skip(1);
      } else if (e.key === "ArrowLeft") {
        if (typing || !speaking) return;
        e.preventDefault(); skip(-1);
      } else if (e.key === "0") {
        if (typing || !speaking) return;
        e.preventDefault(); speakFrom(0);
      }
    });

    // Safety: browsers keep speaking after navigation otherwise.
    window.addEventListener("beforeunload", function () { synth.cancel(); });
  }

  function init() {
    if (!supported) {
      $("unsupported").hidden = false;
      playBtn.disabled = stopBtn.disabled = restartBtn.disabled = true;
      return;
    }

    var prefs = loadPrefs();
    applyTheme(prefs.theme === "night" ? "night" : "day");
    if (prefs.rate) rateInput.value = prefs.rate;
    if (prefs.pitch) pitchInput.value = prefs.pitch;
    if (typeof prefs.text === "string") editor.value = prefs.text;
    rateVal.textContent = parseFloat(rateInput.value).toFixed(1) + "×";
    pitchVal.textContent = parseFloat(pitchInput.value).toFixed(1);

    updateCounts();
    initControls();
    loadVoices();
    if (synth.onvoiceschanged !== undefined) synth.onvoiceschanged = loadVoices;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

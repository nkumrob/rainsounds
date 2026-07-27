# Read Aloud

A free, **private** read-aloud (text-to-speech) web app. Paste any text, pick a
voice, press play — and follow along as each word lights up while it's spoken.

Everything runs in the browser using the built-in [Web Speech API], so **no text
is ever uploaded** and there is no backend, build step, or dependency.

[Web Speech API]: https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API

## Features

- **Any text** — paste an article, email, or chapter and listen instead of read.
- **Word-by-word highlighting** — the spoken word is highlighted; click any word
  to jump straight to it.
- **Natural voices** — uses the voices installed on your operating system.
- **Adjustable speed & pitch** — change them live, even mid-sentence.
- **Sentence skip** — jump forward/back a sentence at a time.
- **Pause / resume / restart**, a progress bar, and a reading-time estimate.
- **Light & dark themes**, keyboard shortcuts, and settings remembered between
  visits (in `localStorage`).

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| <kbd>Space</kbd> | Play / pause |
| <kbd>Esc</kbd> | Stop |
| <kbd>→</kbd> / <kbd>←</kbd> | Skip forward / back one sentence |
| <kbd>0</kbd> | Restart from the beginning |
| <kbd>T</kbd> | Toggle theme |

## Run it

It's a static site — just open `index.html`, or serve the folder:

```bash
cd read-aloud
python3 -m http.server 8000
# open http://localhost:8000
```

## Files

```
read-aloud/
├── index.html     # markup + SEO / structured data
├── style.css      # two themes, one accent, no framework
├── app.js         # the speech engine (chunking, highlighting, controls)
├── robots.txt
├── sitemap.xml
└── vercel.json    # static deploy config + cache headers
```

## How it works

Browsers truncate or stall on very long single utterances, so the text is split
into **sentence-sized chunks** that are spoken in sequence. The utterance
`boundary` event reports a character index into the current chunk; adding the
chunk's absolute offset maps it back onto the full text, which drives the
word highlighting and progress bar. Skipping a sentence is just jumping to a
different chunk.

## Notes & limitations

- The Web Speech API is supported in current Chrome, Edge, and Safari. Available
  voices — and their quality — are provided by the operating system, so the list
  differs per device. On some Linux setups no voices are installed by default.
- Because playback uses the system speech engine, exact word-boundary timing
  varies by voice (some voices don't emit `boundary` events; highlighting then
  advances per sentence).

## License

Part of the [`rainsounds`](../README.md) repository.

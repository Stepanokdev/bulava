# What is in here

Everything the download page loads, and nothing else. `site/render.sh` rewrites each
`{{ASSET:name}}` in the template to `assets/name.<first 8 of its sha256>.ext`, so these filenames
are the source names; the published ones carry the hash.

| file | what it is |
|---|---|
| `mark.svg` | the mace, on its plate — the favicon |
| `hero-1.webp` … `hero-5.webp` | five candidate backdrops for the first screen; **one** of them ships |
| `og.jpg` | the social preview, 1200×630, composed from `site/demo/og.html` |
| `result-*.jpg` | the three games the benchmark produced, as each one opens |
| `play-*.mp4` | the same three games being played — recorded, not staged; see below |
| `play-*-poster.jpg` | the still each clip shows before it starts, taken from the clip itself |
| `meme-en.jpg`, `meme-uk.jpg` | the review gate as a joke — our own drawing, words drawn by `site/demo/meme.py` |
| `shot-*-en.png`, `shot-*-uk.png` | captures of the application, one set per language of the page |

## The hero backdrop

Five of these exist because the choice is the director's. `site/render.py` publishes **one** —
`hero-1.webp`, `HERO_DEFAULT` — and a preview publishes all five plus a switch between them:

```
bash site/preview.sh 1.7.13 10854107 15.6     # switcher, bottom right, 1–5
BULAVA_HERO_PREVIEW=0 bash site/preview.sh …  # exactly what production renders
```

The five candidates are stacked layers, one visible at a time, and they are absolutely
positioned on purpose: in normal flow they stood one under another, only the first was inside the
band, and the switch moved a picture nobody could see. The page's own `img { display:block }`
reset also beat the browser's `[hidden] { display:none }`, so `hidden` had no visual effect at
all — hence the `[hidden] { display:none !important; }` guard near the top of the stylesheet.

Leave it running: the preview re-renders on every request, so a refresh is enough to see an
edit. It also kills whatever else is listening on the port first — an older preview server would
otherwise keep answering with its own frozen copy.

The switch is not in the template. `hero_backdrop()` in the renderer emits it only when
`BULAVA_HERO_PREVIEW=1`, and `site/render.sh` — the path every release takes — unsets that
variable before rendering, so an exported variable in somebody's shell cannot publish a page with
a development control on it. When the choice is made, the other four files and the branch in
`hero_backdrop()` go away together.

All five came from the ImageGen MCP (`gpt-image-2`, 1792×1024, high) and were converted with
Pillow to WebP at quality 80. The prompts are in `site/assets/src/` next to the PNG each one
produced; `site/assets/src` is ignored by git and stripped from the public export, because 2.5 MB
of source PNG per backdrop is not something a clone needs.

## The generated backdrop

No longer used — the screenshots are frameless now, on the page's own background. Kept here
because it may come back, and because the prompt is worth keeping. `field-dark.webp` came from the ImageGen MCP (`gpt-image-2`, 1792×1024, high), then `sips` to
1792 wide and `cwebp -q 82 -m 6`. The prompt, kept so it can be made again rather than
approximated:

> An abstract macro photograph of a deep charcoal anodized aluminium surface, almost black, lit by
> one very soft broad light from the upper left so the fine machining grain catches it as a faint
> sheen. The lower right falls away into near-total darkness. A single faint band of lime-green
> light grazes diagonally across the upper third, like a reflection from a screen off-frame. Fine
> photographic grain, rich blacks, no banding. Absolutely no objects, no text, no logos, no
> letters, no people, no shapes, no icons. Flat, even, calm, expensive, understated — the kind of
> surface a high-end laptop sits on in a night-time product photograph.

Both the webp and its full-resolution original are gone from the repository now that the
screenshots stand on the page's own background; the prompt above is what would bring it back.

## The gameplay clips

`bash site/demo/gameplay.sh` remakes all three; `bash site/demo/gameplay.sh peer` remakes one.

Each clip is a live session against the address the page links to. Chrome loads the game and plays
it with its own input pipeline — `Input.dispatchMouseEvent`, the same trusted events a hand at the
trackpad produces — so every match in the recording went through the game's real pointer handlers.
The move is chosen by the game, not by us: `site/demo/play-*.js` asks each game for the move it
would hint to a player sitting idle. That is why the clips look like somebody who knows the rules.

The three games are not interchangeable to automate, so there is one director per game and each
one is commented with what its game needed. Two things cost a recording and are worth knowing:

* the second game's renderer works in the canvas's backing-store pixels, so a cell centre has to
  be divided by `dpr` before it means anything to a mouse. Without that every click landed two
  cells away, the board matched nothing, and the score sat at zero for the whole clip;
* the first game keeps a green **Play** on the map screen behind the pre-level card. It is still
  `offsetParent`-visible, a click there lands on the veil, and the first recording spent all
  fourteen seconds clicking it. The director looks only inside the topmost dialog.

Menus are not recorded: a director returns `record: false` for a frame it considers warm-up, and
`web-video.py` drops those, which is why a 38-second session yields a 15-second clip that opens on
the board. The poster is lifted from a third of the way into the clip.

`site/analytics/check-video.py` opens the rendered pages in a browser, scrolls the clips into view
and asks each one whether it has picture and whether its clock has moved — a `<video>` tag whose
file is missing looks identical to a working one in the HTML, and `scripts/release.sh` will not
publish a page whose clips it could not watch play.

## The joke

The panel comes from the presentation, where it ran over a comic somebody else drew. On a slide
in a room that is a quotation; on an indexed page it is an unlicensed illustration, so the
artwork here is ours — generated, prompt below — and only the composition of the gag is borrowed.

The words are drawn by `site/demo/meme.py` rather than asked of the image model, because an image
model spells «покличу» differently in every attempt and the whole point of the panel is the exact
line. The original named a person; the public version says "a human", because the argument is
about people in general.

> A single black-and-white comic panel in clean ink-line style, no colour, no text anywhere, no
> letters, no speech bubbles. Scene: a narrow apartment hallway. On the right, a very large,
> heavy, intimidating bald man in a white tank top and tracksuit trousers stands with his legs
> apart, leaning forward, scowling, holding a folded leather belt in one hand. On the left, a
> small skinny young man with curly hair sits sprawled on the floor, one palm raised in a
> placating gesture, looking up at him with wide alarmed eyes. Plain t-shirt and joggers, no
> writing on the clothes. Leave generous empty space in the upper left and the middle left of the
> panel. Crisp black outlines, light grey flat shading, white background walls. Absolutely no
> words, no captions, no logos, no symbols.

## The captures

`site/demo/shoot.sh --lang=en` and `--lang=uk` take four frames each, and never of the real
desktop. It starts a second, isolated
Bulava — its own state directory, its own engine state, invented products, English interface —
drives it into the state each picture is about through the app's own test inbox, and photographs
that window alone. `site/analytics/check-screenshots.py` then reads the published frames with
Vision and fails if any of them shows a project this machine has actually worked in.

There is a set per language because the application has both interfaces, and an English window
on a Ukrainian page is the seam a reader sees first — the conversation inside the fixture is
translated too, in `site/demo/words.py`, not only the chrome. The three detail frames
(`shot-compose`, `shot-running`, `shot-review`) are regions of that one window: a three-column application shrunk to phone width is decoration, and the page says
something specific about each of them.

**Why Terminal takes the picture.** macOS records a screen-recording grant against the
*responsible* process, which a child inherits from whatever started it — so a Bulava started from
a script is refused however plainly the switch for Bulava is on. Terminal holds the grant, and
`site/demo/windowshot` asks it for one window by pid.

**What the fixture does and does not simulate.** The products, the conversation, the repository
and the verifier's evidence are invented, and the interface drawing them is the real one, reading
real files in the real shapes. One thing is deliberately staged: a stand-in watchdog process, so
the sidebar reads "working" rather than "idle" — no work is being done behind it. The appearance
is pinned to dark, because the page is black and a light window on it is a different product. The usage meters
are not staged and cannot be: the app refreshes them from this machine's actual Claude and Codex
accounts, so the frames are taken when those numbers read like an ordinary working day.

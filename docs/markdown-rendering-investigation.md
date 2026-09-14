# Markdown rendering investigation for the Zig TUI (#256)

Date: 2026-09-14. Investigation only — no production changes. Decision owner: Marc.
Baseline: `main` @ `0d2091d` (post #254 plain render). PoC branch: `poc/256-md4c-zig` @ `fe9f231` (not for merge).

## The contract any renderer must inherit (#254)

The plain renderer established a security and layout contract that a markdown renderer
must preserve bit-for-bit in its rejection semantics. All citations are merged code:

- `renderAssistantPlain` (`zig/src/tui/views/transcript.zig:402`) — the only structure
  detection is code fences (`fenceMarker` :465, `isFenceClose` :477). Prose lines go to
  `wrapPlainLine` :427; fence lines go through `stripControls` :430 → `expandTabs` :432 →
  `truncateLineToWidth` :434 → 2-space dim indent :437-440.
- Sanitizer rejection set (`wrapPlainLine` :511-591 and `stripControls` :602-639):
  `skipAnsiSequence` :669-712 consumes CSI (`[`), OSC (`]`), DCS (`P`), and charset
  selector (`(`–`+`) sequences whole (prose :524, fence :609); C0 controls except tab
  and DEL dropped (:528, :618); malformed UTF-8 lead/continuation bytes skipped
  (:567-572, :622-630); C1 controls U+0080–U+009F rejected (:573-576, :631-634). The
  invariant that actually holds: **no ESC byte ever survives** — for introducers with
  no branch (APC `ESC _`, PM `ESC ^`, SOS `ESC X`) the ESC and its successor byte are
  still consumed, destroying the sequence, but the payload up to ST then flows through
  the ordinary C0/C1/UTF-8 filters and renders as inert text. A renderer port should
  close that cosmetic gap by consuming APC/PM/SOS payloads to ST, as the PoC does.
  Model-emitted ANSI never survives into prose; the only ANSI in bubble content is
  theme-introduced.
- Width model: `zz.measure.charWidth` per codepoint (:578), tabs expanded to 8-column
  stops with padding never dropped across wrap boundaries — a stop crossing the width
  fills the current row, flushes it, and the remaining padding continues on the next
  row (:532-559, i.e. padding may split across rows; it is never discarded as a word
  separator) — greedy wrap with last-space breaks and hard splits for overlong words
  (`flushWrapRow` :487).
- Bubble/scroll integration: `renderBubble` (:739) computes per-line visible width via
  `visibleWidth` (ANSI-aware, `zig/src/tui/text.zig:6`) and re-asserts the bubble's open
  SGR after every `\x1b[0m` inside content (:742-744). `lineWindow` (:882) slices the
  transcript by rendered line count — so a renderer's emitted row count *is* the scroll
  height, and every row must already fit the content width (no downstream re-wrap).

Consequence for output model: a renderer that emits pre-styled ANSI strings works only
if every output row is self-contained (re-assert open span styles at row start, reset at
row end) and every width computation is column-based, ANSI-aware. A renderer that
separates plain text from styling (events/AST) lets the TUI keep wrapping plain runs and
apply styles per run — closest to the existing pattern.

## Candidate A — vendored zigzag Markdown component

`zig/vendor/zigzag/src/components/markdown.zig`, 368 lines. Already vendored, so zero
new vendoring cost — and that is its only passing criterion.

- **Not a parser.** Line-pattern matching over the source: ATX headings only for `# `,
  `## `, `### ` (:204-221; H4–H6 unsupported), ``` fences only (no `~~~`), `- ` / `* ` /
  `N. ` single-line list items (:232-254; no continuation lines, no multi-paragraph
  items), single-level `> ` quotes (:223), `---`/`***` thematic breaks (:188-202). No
  indented code blocks, no setext headings, no reference links, no escapes, no nested
  emphasis rules. This is the "hand-rolled" category issue #256 rules out.
- **No wrapping.** Paragraph text is never wrapped; `width` is used only for the code
  box (:333-335) and HR lengths (:190, :198). Long prose overflows the bubble.
- **No sanitization.** `renderInline` copies unmatched bytes verbatim (:326); heading,
  quote, and code content are rendered as-is. Model-emitted ESC bytes pass straight
  into the terminal. Integrating it would require wrapping it with the #254 sanitizer —
  which then strips nothing it doesn't already handle, but the component would still
  emit none of the guarantees itself.
- **Byte-based truncation** in code blocks (`@min(line.len, inner_width)` :175) can
  split UTF-8 sequences and miscount wide chars.
- **Tests:** one test (fence length, :359-368). No conformance suite.

Verdict: **reject.** Fails CommonMark coverage, wrapping, and security criteria.

## Candidate B — md4c (C, MIT, SAX)

`mity/md4c`, latest tag `release-0.5.3`, master active (pushed 2026-09-13). Fully
CommonMark 0.31-conformant; SAX API (`md_parse` + one callback struct in `md4c.h`).
Same parser behind Qt's QTextMarkdown and LibreOffice's Markdown support. Linear /
near-linear parsing with a pathological-input test suite — relevant because the input
is untrusted model output. Explicit GIGO note in the docs: any byte sequence is
accepted and ill-formed UTF-8 is passed through to callbacks — so the #254 sanitizer
must wrap every `MD_TEXT` event; that is a clean, single choke point.

Vendoring cost is the lowest of the C options: the parser is two files
(`md4c.c` 6,462 lines + `md4c.h` 407 lines, stdlib-only, no CMake, no config headers —
"add md4c.[hc] directly to your code base" per upstream). The HTML renderer
(`md4c-html.[ch]`) is not needed for an ANSI renderer. `entity.[ch]` is not needed by
the parser itself, but its MIT data is the natural source of the renderer's entity
decode table — a complete table means the vendor slice takes four files, or the
renderer slice carries an equivalent generated Zig table. `MD_FLAG_NOHTML` disables
raw HTML blocks and spans. Two gaps the renderer slice must close deliberately:

- **Span metadata bypasses text events.** Link destinations, titles, and image sources
  arrive as `MD_ATTRIBUTE` fields on span-detail structs (`MD_SPAN_A_DETAIL.href`,
  `MD_SPAN_IMG_DETAIL.src`, wikilink targets) — never through `MD_TEXT` callbacks. A
  renderer that prints any of them (e.g. a dim URL after a link) must run the same
  sanitizer over the attribute bytes before emission, or model output like
  `[x](https://e/\x1b]0;pwned\x07)` injects terminal control past the text-event choke
  point. The PoC originally had exactly this hole; it is fixed and tested there.
  Attributes may themselves contain character references (`MD_ATTRIBUTE` exposes them
  via `substr_types`/`substr_offsets`), so the decode-before-sanitize rule applies
  here too: decode the attribute's substrings first, then sanitize the decoded bytes,
  or a destination like `https://e/&#27;]0;pwned&#7;` injects OSC after sanitization.
- **Structural events are not text payloads.** `MD_TEXT_BR` / `MD_TEXT_SOFTBR` are
  distinct event types carrying no bytes; they must dispatch straight to layout (row
  break), not pass through a byte sanitizer. Conversely `MD_TEXT_CODE` payloads *do*
  contain `\n` between code lines, so the code-path sanitizer must preserve newlines
  (strip controls per line, not per payload) — a naive port of `stripControls` over
  the whole payload would merge code lines.
- **Line-ending semantics differ pre-parse.** `renderAssistantPlain` splits on LF only
  and drops stray `\r` as a C0 control (:411, :528); CommonMark treats CR as a source
  line ending *during parsing*, so a lone CR becomes structural breaks no
  callback-level sanitizer can remove. The renderer must sanitize the raw input before
  `md_parse` (drop CR bytes, preserving LF/tab semantics), then apply the event-,
  attribute-, and post-decode sanitization above.
- **Entities.** Entities arrive as `MD_TEXT_ENTITY` with the raw reference text
  (`&amp;`, `&#27;`, `&NewLine;`). The renderer must decode **first**, then run the
  sanitizer and width accounting over the decoded bytes — decoding after sanitizing
  re-introduces ESC/newline/tab bytes (`&#27;`, `&NewLine;`, `&Tab;`) that the
  sanitizer already passed. Decoding needs the complete CommonMark named-entity set
  plus numeric references for full conformance (upstream `entity.c/h` is MIT and
  adaptable); a common-subset table would be reduced entity compatibility and must be
  documented as such if chosen. The PoC passes raw entity text through undecoded —
  safe, but not yet conformant rendering.

### PoC results (branch `poc/256-md4c-zig` @ `fe9f231`)

`zig/src/poc/md4c_ansi.zig` (657 lines incl. tests) drives `md_parse` from Zig via
`@cImport` — a SAX→ANSI renderer with:

- sanitizer ported from `stripControls` semantics applied at every text event
  (ESC/CSI skip, C0+DEL drop, C1 rejection, malformed-UTF-8 skip), plus the two
  hardening deltas above: sanitized link destinations and APC/PM/SOS payloads
  consumed to ST;
- width-aware greedy wrap with span re-assertion across row breaks and
  reset-before-separator ordering (rows are self-contained: style at row start, reset
  at row end — directly compatible with `renderBubble`'s re-assert and `lineWindow`'s
  line counting);
- styled headings/emphasis/code spans/links (text styled + dim sanitized URL), fenced
  and indented code blocks (2-space dim indent, width-aware wrap, per-byte stream
  handling matched to md4c's granular `MD_TEXT_CODE` events), nested UL/OL markers
  with `start` offsets, quote bars, thematic breaks;
- 8/8 inline tests pass on x86_64-linux with Zig 0.16.0 (`zig test` with `md4c.c` +
  `-Ivendor`, no build.zig changes needed to compile it standalone).

Build-cost evidence:

| Target | `md4c.c` via `zig cc` | full renderer via `build-lib` |
| --- | --- | --- |
| x86_64-linux | OK | host `zig test` |
| aarch64-linux | OK | OK |
| x86_64-windows | OK | OK |
| aarch64-windows | OK | OK |
| aarch64-macos | OK | OK |
| x86_64-macos | OK | — |

CI's cross-compile smoke matrix (`cross-compile-smoke`, `.github/workflows/ci.yml:164-179`)
builds all five of these release targets on every PR — `aarch64-windows` included, on
`windows-latest`. The smoke job compiles the repo checkout (`zig build install`, :202-206),
which contains no md4c today, so md4c's portability evidence is PoC-only until a vendor
slice merges — at that point the existing matrix compiles it on all five targets
automatically, with no CI changes needed.

Lessons the PoC already paid for (the implementation slice inherits them as known
pitfalls, not surprises): multi-byte prefixes (`│ `, `• `) must be width-accounted, not
byte-accounted; separator spaces must be ordered against span open/close boundaries;
the production renderer must use `zz.measure.charWidth`, not the PoC's rune-count
simplification, or CJK/emoji width breaks the bubble math.

Verdict: **recommended**, subject to the conditions below.

## Candidate C — cmark (C, BSD-2, AST)

`commonmark/cmark`, latest release 0.31.2 (2026-02-14) — the CommonMark reference
implementation, full conformance by definition. Node-API AST walk (`cmark_node_*`) is a
fine fit conceptually — walk nodes, wrap each paragraph's text runs, style per run.

Costs relative to md4c: the vendored surface is much larger (the parser is split across
`blocks.c`, `inlines.c`, `node.c`, `references.c`, `utf8.c`, `buffer.c`, `houdini*`,
`cmark.c` plus generated scanners; CMake-centric build expecting a configured
`config.h`, so vendoring means either hand-maintaining a config header or shimming
CMake output into build.zig). It allocates an AST per message where md4c streams
events. BSD-2 is license-compatible; nothing wrong with the library — it is strictly
more machinery for the same terminal result.

Verdict: viable fallback if md4c hits an unforeseen wall; not preferred.

## Candidate D — pure-Zig ecosystem survey

- **zigmark** (`sc2in/zigmark`, published March 2026): claims 100% CommonMark 0.31.2
  conformance (652 spec tests) but is licensed **PolyForm Noncommercial** — fails the
  license criterion for this repository, and it is a brand-new single-author project.
- **zigdown** (`JacobCrabill/zigdown`, MIT, Zig 0.16): a Glow/mdcat-inspired terminal
  markdown toolset — but its own README states it "is not a CommonMark-compliant
  Markdown parser, nor will it ever be one". Valuable as prior art for terminal
  markdown aesthetics (its console renderer, clickable links); not a conformance
  candidate for vendoring.
- Nothing else in the Zig ecosystem is at comparable CommonMark maturity today.

Verdict: no pure-Zig candidate passes; revisit yearly.

## Criteria matrix

| Criterion | zz.Markdown | md4c | cmark | pure-Zig |
| --- | --- | --- | --- | --- |
| CommonMark conformance | none (line patterns) | 0.31, SAX | 0.31, reference | none (license/blocklist) |
| Output model fit | pre-styled ANSI string (worst) | events → wrap plain runs, style per run (best) | AST → same | varies |
| Width wrapping | none | caller-owned (PoC proves) | caller-owned | varies |
| Sanitizer inheritance | absent | at text events + every emitted span/block attribute | at node text walk + attributes | varies |
| Vendoring cost | zero (present) | 4 files incl. entity table (parser 6.9k + entity 2.2k C lines), no CMake | ~10k C lines + config/CMake shim | n/a |
| Windows ARM64 | untested | proven via zig cc; target already in CI smoke | presumed fine, unproven | n/a |
| License | vendored zigzag | MIT | BSD-2 | PolyForm-NC (zigmark) |
| Test story | 1 test | upstream spec suite + PoC 8/8 | upstream spec suite | n/a |
| Incremental prod LOC vs plain render | integration only (already vendored; fails criteria) | ~600-800 Zig renderer (vendor excluded) | ~600-800 Zig renderer + config shim | n/a |

## Recommendation

**Vendor md4c (release-0.5.3) and build a SAX→ANSI renderer in the TUI**, in two
slices per methodology (vendor blob gets its own PR; the renderer is a second):

1. **Vendor slice**: `zig/vendor/md4c/{md4c.c,md4c.h,entity.c,entity.h}` + LICENSE
   (or drop `entity.[ch]` here and generate a complete Zig entity table in the
   renderer slice instead), `build.zig` C source wiring, no behavior change (parser
   unreferenced by prod).
2. **Renderer slice**: replace the body path in `renderAssistantPlain` for assistant
   entries with the md4c renderer: pre-parse CR removal, sanitizer on text payloads
   (newline-preserving on the code path) **and over every emitted span/block metadata
   attribute**, structural break events dispatched to layout, decode entities before
   sanitizing, `MD_FLAG_NOHTML`, `zz.measure.charWidth` width model, self-contained
   styled rows, exact-output regression tests in the #254 pattern plus a sampled
   CommonMark fixture set.

Keep plain rendering as the fallback for non-assistant transcript entries (tool cards,
errors) — only assistant prose benefits from markdown structure.

Open question for the decision owner: whether terminal markdown is wanted at all right
now — the trim series deliberately bought simplicity (-2,295 lines in #254) and model
output is mostly readable as plain text. This investigation establishes that *if* it
returns, md4c is the path with known, bounded cost.

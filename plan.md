# Launcher — Implementation Plan

## Step 6: Wire Handlers to the Wayland UI

| Item | Status |
|------|--------|
| `InputState` struct | [x] done |
| `Mode` struct + `default_mode` / `dict_mode` | [x] done |
| `App` with `arena`, `mode`, `candidates` | [x] done |
| Arena init in `run()` | [x] done |
| `runDispatcher` with `RankedCandidate`, fuzzy scoring, final copy | [x] done |
| `redraw` using `app.mode.prefix` | [x] done |
| `redraw` using `app.candidates` | [x] done |
| Up/Down clamping to `candidates.len` | [x] done |
| Enter key with `execute_fn` | [x] done |
| Escape + `"dw "` mode transitions | [x] done |
| `dict_mode.handlers` wired up | [x] done |
| `fillSolid` dead code removed | [x] done |
| `fuzzy.zig` | [ ] missing — imported but not created |
| `score` removed from `Candidate` | [ ] still present in handler.zig |
| `systemd.suggest` — remove prefix filter + score | [ ] still scores |
| `calc.suggest`, `convert.suggest` — remove score field | [ ] still set score |

---

## Step 7: Expand-in-place for dictionary words

See `plan-expand.md` for the full design and code snippets.

---

## Step 8: Scrolling in expanded view

Simple `scroll_offset: usize` in `App`. Arrow keys adjust it (clamped to line
count). `redraw` renders `lines[scroll_offset..scroll_offset + visible_rows]`.
No toolkit needed — ~30 lines of code.

---

## Rendering approach — why not GTK4 or EFL

Considered GTK4/libadwaita and EFL as alternatives for getting scroll, list
views, and input widgets "for free". Decided against both:

**GTK4:**
- 100–300ms startup (toolkit init, D-Bus, theme loading) — unacceptable for a
  launcher that should feel instant
- 30–80MB resident memory vs <5MB for our current stack
- No Zig bindings library — would use `@cImport` on GTK4's massive C API
  (Ghostty does this, but for a full terminal app, not a 600×400 overlay)
- libadwaita looks native on GNOME but out of place on sway/Hyprland/KDE
- Layer shell still requires gtk4-layer-shell as a separate library

**EFL (Enlightenment):**
- Lighter than GTK4 but still has toolkit init overhead
- Tiny community, Wayland support lags GTK4
- Same `@cImport` situation

Our fcft/pixman/wlr-layer-shell stack starts in <50ms, uses <5MB, and looks
consistent everywhere. Scroll is ~30 lines of custom code — not worth a toolkit.

---

## Dictionary options considered

**Current: Webster's 1913 (StarDict)**
- Plain text format, no machine-readable structure
- Preamble before definitions: pronunciation + etymology in `\word\`, `(phon)`,
  `[OE. ...]` — hard to extract cleanly for previews
- Good for expand-in-place (full definition is human-readable once you have space)

**WordNet (considered for previews)**
- Much cleaner format: `(n) apple (fruit with firm whitish flesh) "example"`
  — definition and example on same line, no pronunciation clutter
- Available as a system package (`dnf install wordnet`), own database format;
  StarDict versions exist but are unofficial conversions
- Would be ideal for one-line previews
- Decision: revisit when WordNet data is available to test against; for now
  skip previews and use Webster's for expand-in-place only

**Multi-source design (future)**
The mode system naturally supports multiple dict handlers:
```zig
.handlers = &.{ wordnet.suggest, webster.suggest },
```
But per-word results should NOT be merged as separate candidates — that creates
duplicates. The right design is either:
- One handler that internally coordinates multiple sources (WordNet preview +
  Webster expand), or
- Pick one source per mode

---

## Remaining cleanup (low priority)

```zig
// src/fuzzy.zig
const std = @import("std");

pub fn score(input: []const u8, label: []const u8) f32 {
    if (input.len == 0) return 1.0;
    var i: usize = 0;
    var consecutive: f32 = 0;
    var total: f32 = 0;
    for (label) |c| {
        if (std.ascii.toLower(c) == std.ascii.toLower(input[i])) {
            consecutive += 1;
            total += consecutive;
            i += 1;
            if (i == input.len) return total / @as(f32, @floatFromInt(label.len));
        } else {
            consecutive = 0;
        }
    }
    return 0;
}
```

- [ ] Create `src/fuzzy.zig` using snippet above
- [ ] Remove `score` field from `Candidate` in `handler.zig`
- [ ] `systemd.suggest` — remove prefix filter + score calculation
- [ ] `calc.suggest`, `convert.suggest` — remove `.score` field from candidates

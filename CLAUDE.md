# Launcher (Raycast-like app in Zig)

## Project Goal
Learning Zig by building a Raycast-like launcher application.
Background: Coming from Go.

## Development Approach
- Always implement changes step-by-step, one piece at a time. Never implement everything at once. Wait for confirmation before moving to the next step.
- When the user asks to build something incrementally, treat each logical unit as a separate step with its own review cycle.

## Design Discussions
- When proposing architecture or memory management patterns, present ONE clear recommendation with rationale rather than a confused mix of approaches. If unsure, ask the user which ownership model they prefer before writing code.

## Current State
- Basic REPL loop with stdin/stdout
- Handler architecture: each plugin implements `suggest(allocator, input) → []Candidate`
  - `src/calc.zig` — calculator (+, -, *, /, %)
  - `src/convert.zig` — temperature (F↔C) and data units (B, KB, MB, GB, TB)
  - `src/dict.zig` — dictionary lookup via StarDict (`src/stardict.zig`)
  - `src/systemd.zig` — power commands via D-Bus (suggest + execute)
  - `src/handler.zig` — shared types (Candidate, Handler, ResultKind)
- Arena allocator for handler results, resets each input cycle
- Quit command

## Next Steps
- [x] **Handler refactor for partial input (UI-ready)**
- [ ] **Wayland UI**
- [ ] Application Launcher
  - [ ] fuzzy finder support (fzf lib based ideally)
- [x] SystemD commands integration (suspend, shutdown etc.)
- [x] Dictionary/define word (see Dictionary section below)
- [ ] Remember frequently launched apps or commands (not the conversions/word definition)
- [ ] Unit conversions
  - [x] F to C (supports both "to" and "in" separators)
  - [x] Data units: B, KB, MB, GB, TB (e.g., `100 MB to KB`)
  - [ ] 50 Mb in 10 sec => 5 MB/sec (bandwidth calculation)
- [ ] Timezone manipulation (i.e. current time in Tokyo or UTC time)
- [ ] Support theming

## Zig Notes
- Code includes Go-comparison comments for learning
- Using std library for parsing and I/O

**Language proposals to watch:**
- [#11520](https://github.com/ziglang/zig/issues/11520) - Implicit named block for declarations (use var name as label in `break :varname`)
- [#2792](https://github.com/ziglang/zig/issues/2792) - Assign once to `const` initialized to `undefined`

Both address the friction of: "I want `const`, but initialization requires side effects (e.g., logging on error)"

## Development Approach
- Iterate one thing at a time for learning
- Build and test each step before moving to the next
- Discuss Zig concepts as they come up

## Unit Conversion Architecture
```
Input: "32F to C"
         │
         ▼
┌─────────────────────┐
│ parseNumberPrefix() │  → { value: 32, rest: "F to C" }
└─────────────────────┘
         │
         ▼
┌─────────────────────┐
│ convert() dispatcher│  → tries each converter with (value, rest)
└─────────────────────┘
         │
         ├──► convertTemperature(32, "F to C", buf) → "0.00 C"
         ├──► convertDataUnit(100, "MB to KB", buf) → "102400.00 KB"
         └──► calculateBandwidth(...)  (TODO)
```
- `findSeparator()` handles both " to " and " in "
- Each converter returns null if units don't match, allowing fallthrough

## Dictionary Feature

**Decision:** Parse StarDict format natively in Zig (no shelling out to sdcv).

**Why StarDict:**
- Simple binary format — good Zig learning exercise
- Largest free dictionary archive (stardict.uber.space)
- Used by sdcv, GoldenDict — can share dictionaries
- Alternatives (DSL, XDXF, Slob) have worse tooling or availability

**Why native parsing (not sdcv subprocess):**
- Avoids process spawn latency on each lookup
- Launcher should be snappy

**StarDict format:**
```
.ifo  — metadata (text, key=value)
.idx  — word index: [word\0][offset:4B big-endian][size:4B big-endian]...
.dict — definitions (plain text or .dict.dz compressed)
```

**Implementation:**
- [x] Parse .ifo metadata (bookname, version, wordcount)
- [x] Parse .idx into word → (offset, size) entries
- [x] Binary search / prefix search (`findByPrefix`)
- [x] Read definition from .dict at offset (`readDefinition`)
- [x] Load dictionary files from disk (`Dictionary.load`)
- [x] REPL integration (`dw <word>`)
- [ ] Case-insensitive lookup (try exact → Title → lower variants)

**Resources:**
- Format spec: github.com/huzheng001/stardict-3/blob/master/dict/doc/StarDictFileFormat
- Dictionaries: stardict.uber.space (Webster's 1913 recommended)

## SystemD Commands Feature

**Goal:** Quick system power commands via D-Bus IPC (no subprocess spawning).

**Commands to support:**
| Command | REPL syntax | D-Bus method |
|---------|-------------|--------------|
| Suspend | `suspend` | `org.freedesktop.login1.Manager.Suspend` |
| Hibernate | `hibernate` | `org.freedesktop.login1.Manager.Hibernate` |
| Reboot | `reboot` | `org.freedesktop.login1.Manager.Reboot` |
| Shutdown | `shutdown` | `org.freedesktop.login1.Manager.PowerOff` |
| Lock | `lock` | `org.freedesktop.login1.Session.Lock` |

**D-Bus details:**
- Bus: System bus (`/run/dbus/system_bus_socket`)
- Service: `org.freedesktop.login1`
- Object: `/org/freedesktop/login1`
- Interface: `org.freedesktop.login1.Manager`

**Implementation (sd-bus via C interop):**
- [x] Add libsystemd to build.zig (`linkSystemLibrary("libsystemd")` — note: `libsystemd` not `systemd`)
- [x] Create `src/systemd.zig` with `@cImport` for sd-bus headers
- [x] Implement `Bus.connectSystem()` — open system bus connection
- [x] Implement power commands (suspend, hibernate, reboot, poweroff)
- [x] Implement `Bus.disconnect()` — cleanup
- [x] REPL integration: `checkSystemCommand()` matches keywords, calls Bus methods
- [x] Error handling (connection failed, method call failed)
- [ ] Lock command (requires session object path lookup)

**sd-bus API overview:**
```c
sd_bus *bus;
sd_bus_open_system(&bus);                    // Connect
sd_bus_call_method(bus,
    "org.freedesktop.login1",                // service
    "/org/freedesktop/login1",               // object path
    "org.freedesktop.login1.Manager",        // interface
    "Suspend",                               // method
    &error, &reply, "b", true);              // args: interactive=true
sd_bus_unref(bus);                           // Cleanup
```

**Zig learning points:**
- `@cImport` / `@cInclude` for C headers
- `linkSystemLibrary("libsystemd")` in build.zig (pkg-config name, not package name)
- `std.mem.zeroes()` for C struct initialization (when C macros can't translate)
- C pointer handling: `?*c.type` for nullable C pointers
- Translating C error patterns to Zig errors (negative return = error)

## Handler Architecture (Partial Input Support)

**Problem:** Current CLI design assumes final input → single result. UI needs:
- Partial input → multiple candidates
- As-you-type filtering
- Different result types (instant values vs executable actions vs previews)

**Current flow (CLI):**
```
Input → try handler1() → try handler2() → ... → first non-null result
```

**New flow (UI-ready):**
```
Input → all handlers return []Candidate → merge & rank → display top N
```

### Design Decisions

**Allocator model:** Dispatcher owns an arena allocator, passes it to each handler's
`suggest()`. Handlers allocate candidates (and any dynamic strings like formatted
calculator results) from this arena. Arena resets between input changes.

- Most string data costs zero allocation — labels point to comptime literals (systemd
  command names), pre-loaded data (dictionary words), or cached data (app names from
  `.desktop` files loaded at startup).
- Only expression handlers (calculator, converters) need to `allocPrint` result strings
  from the arena.
- Candidate structs are ~72 bytes each. Worst case ~50 candidates = ~3.5 KB per keystroke.
  Arena allocation is just pointer bumping — negligible cost.

**Candidate.action field:** `?[]const u8` carries the command data needed for execute.
For systemd: the D-Bus method name ("Suspend"). For app launcher: the executable path.
For instant handlers (calculator): null.

**No progressive filtering in dispatcher:** Initially considered having the dispatcher
cache candidates and filter on appended keystrokes. Rejected because:
- Dispatcher would need to know which handlers are prefix-based vs expression-based
- Expression handlers can widen results on longer input ("1+" → nothing, "1+2" → "= 3")
- Instead: dispatcher is simple, calls all handlers every keystroke
- Handlers that benefit from caching (app launcher) optimize internally

**Threading:** Handler interface is thread-safe by design — each `suggest()` receives
its own allocator and reads only immutable data. For now, sequential execution (all
handlers are fast). Can add per-handler worker threads later without changing any handler
code.

**Handler struct:** Struct with function pointers (manual vtable), not a Go-style
interface. Since all handlers are known at compile time, the dispatcher can also call
them directly. The struct exists for when we want to iterate over handlers in an array.

### Open Questions

- **Handler identification on Candidate:** When the dispatcher merges candidates from
  all handlers and the user selects one, how does the dispatcher know which handler's
  `execute()` to call? Options: handler pointer on Candidate, execute fn pointer on
  Candidate, or dispatcher tracks origin. Decide when building the dispatcher (step 6).

### Candidate Structure

```zig
const ResultKind = enum {
    instant,   // Calculator: show value immediately, no action needed
    action,    // SystemD: execute on Enter
    preview,   // Dictionary: show definition inline, copy on Enter
};

const Candidate = struct {
    label: []const u8,        // Primary display text
    sublabel: ?[]const u8,    // Secondary text (definition preview, path, etc.)
    kind: ResultKind,
    score: f32,               // 0.0-1.0, higher = better match
    action: ?[]const u8,      // Command data for execute (method name, app path, etc.)
};
```

### Handler Interface

```zig
const SuggestFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]Candidate;

const Handler = struct {
    name: []const u8,
    suggest: SuggestFn,
    // Null for instant-result handlers (calculator) that have no action on Enter
    execute: ?*const fn (Candidate) anyerror!void = null,
};
```

### Handler Behavior by Type

| Handler | Partial Input Behavior | Result Kind |
|---------|------------------------|-------------|
| Calculator | Parse as-you-type, show result if valid expression | instant |
| Temperature | Show result if parseable, else nothing | instant |
| Data Units | Show result if parseable, else nothing | instant |
| SystemD | Filter commands by prefix ("sus" → suspend, sleep) | action |
| Dictionary | Return top N word matches + first definition preview | preview |
| App Launcher | Fuzzy match .desktop files | action |

### Implementation Plan

1. [x] Create `src/handler.zig` with Candidate, ResultKind, Handler types
2. [x] Refactor systemd → `suggest()` prefix-matches entries, `execute()` calls D-Bus
3. [x] Refactor calculator → `suggest()` returns 0-1 candidates
4. [x] Refactor converters → `suggest()` returns 0-1 candidates
5. [x] Refactor dictionary → `suggest()` uses existing `findByPrefix()`
6. [ ] Create dispatcher: call all handlers, merge candidates by score
7. [ ] Update main.zig REPL to use new dispatcher (keep CLI working)

## Wayland UI

**Goal:** Floating overlay window with input field + candidate list.

### UI Components

```
┌─────────────────────────────────┐
│ [____input field____________]  │  ← Text entry
├─────────────────────────────────┤
│ > suspend          [action]    │  ← Selected candidate (highlighted)
│   sleep            [action]    │
│   sublime_text     [app]       │
│   ...                          │
└─────────────────────────────────┘
```

### Technology Stack (Fuzzel-like)

Following fuzzel's proven approach:

| Component | Library | build.zig link | Zig binding |
|-----------|---------|----------------|-------------|
| Wayland client | libwayland | `wayland-client` | zig-wayland v0.3.0 (Zig 0.14) |
| Overlay window | wlr-layer-shell | (via zig-wayland scanner) | zig-wayland scanner |
| Font rendering | fcft | `fcft` | `@cImport` (small API, 18 funcs) |
| Keyboard | xkbcommon | `xkbcommon` | `@cImport` |
| Pixel ops | pixman | `pixman-1` | `@cImport` |

**Why this over GTK4:**
- Lightweight, no heavy toolkit dependency
- Zig bindings already exist
- Better learning opportunity (understand Wayland directly)
- Proven pattern (fuzzel, foot use this stack)

**fcft vs pango:** fcft is simpler and faster — built for terminals/launchers. Pango is a full text layout engine for i18n, which we don't need for short ASCII labels.

**@cImport vs zig-fcft/zig-pixman:** Using `@cImport` directly for fcft and pixman.
The API surface is tiny (pixman: create_bits, fill_rectangles, composite32, solid_fill,
unref; fcft: init/fini, from_name, rasterize_char_utf32, destroy). Same pattern we
already use for libsystemd. Fewer deps to manage.

### System Dependencies (Fedora)

```bash
sudo dnf install wayland-devel wayland-protocols-devel pixman-devel fcft-devel libxkbcommon-devel
```

### Wayland Protocols Needed

| Protocol | Interface | Version | Purpose |
|----------|-----------|---------|---------|
| core | `wl_compositor` | 4 | Create surfaces |
| core | `wl_shm` | 1 | Shared memory pixel buffers |
| core | `wl_seat` | 7 | Input (keyboard) |
| core | `wl_output` | 4 | Monitor info for sizing |
| wlr-layer-shell | `zwlr_layer_shell_v1` | 4 | Overlay positioning |

- `wl_display`, `wl_registry`, `wl_callback`, `wl_buffer` are generated automatically
- Layer-shell XML vendored in `protocol/wlr-layer-shell-unstable-v1.xml`

### Build Setup

**zig-wayland v0.3.0** added via `build.zig.zon`. Scanner generates Zig bindings from
protocol XML at build time. Also generates C glue code (`scanner.addCSource(exe)`) that
libwayland needs for protocol dispatch — required until Zig issue #131 is resolved.

```zig
// build.zig sketch
const Scanner = @import("wayland").Scanner;
const scanner = Scanner.create(b, .{});
const wayland = b.createModule(.{ .root_source_file = scanner.result });

scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

scanner.generate("wl_compositor", 4);
scanner.generate("wl_shm", 1);
scanner.generate("wl_seat", 7);
scanner.generate("wl_output", 4);
scanner.generate("zwlr_layer_shell_v1", 4);

exe.root_module.addImport("wayland", wayland);
exe.linkSystemLibrary("wayland-client");
scanner.addCSource(exe);
```

### Rendering Pipeline (per frame)

```
1. Fill surface with background color  → pixman_image_fill_rectangles(OP_SRC)
2. Draw selection highlight rectangle  → pixman_image_fill_rectangles(OP_SRC)
3. Render input text glyph-by-glyph   → fcft_rasterize_char_utf32 + pixman_composite32
4. Render candidate labels             → same as above
5. Attach buffer to wl_surface, commit
```

**Text rendering:** fcft rasterizes each codepoint → `pixman_image_t` glyph. For normal
glyphs, use glyph->pix as mask with a solid color source (`PIXMAN_OP_OVER`). For color
glyphs (emoji), use glyph->pix as source directly. Positioning formula:
`dst_y = pen_y + font->ascent - glyph->y`

### Implementation Plan

1. [x] **Setup + connect:** Add zig-wayland dep, vendor layer-shell XML, update build.zig,
       create `src/wayland.zig`, connect to display, print globals
2. [x] **Layer-shell surface:** Bind compositor/shm/layer-shell from registry, create
       surface, set up wl_shm buffer pool (mmap), fill with solid color via pixman, commit
3. [x] **Text rendering:** Install fcft-devel, link fcft + pixman, init fcft, load font,
       render static text onto the pixman surface
4. [ ] **Keyboard input:** Bind wl_seat, set up keyboard listener, xkbcommon keycode
       translation, build text input buffer, handle backspace/escape/enter
       - [x] Piece 1: wl_seat + wl_keyboard listeners, Escape to close
       - [x] Piece 2: xkbcommon keymap + xkb_state, translate keys to U+XXXX
       - [x] Piece 3: text input buffer with cursor (insert, backspace, delete, left, right)
       - [ ] Piece 4: key repeat (timerfd + poll on Wayland fd + timerfd)
       - [ ] Piece 5: readline shortcuts — Ctrl+A (home), Ctrl+E (end), Ctrl+U (kill to start),
             Ctrl+K (kill to end), Ctrl+W (delete word back)
5. [ ] **Candidate list:** Layout input field + candidate rows, render labels + sublabels,
       arrow key navigation with highlight
6. [ ] **Wire to handlers:** On keystroke → reset arena, call all handlers, collect
       candidates, sort by score, render list. Enter → execute. Escape → close
7. [ ] **Mode system:** Handler-set switching via keyword triggers ("dw " → dict mode).
       See plan-modes.md.
8. [ ] **Nested modes:** Mode hierarchy with a mode stack — e.g. "dd " → top level shows
       categories (dashboards / monitors / apm), selecting one enters a single-handler
       sub-mode. Escape pops the stack. See plan-modes.md future section.

### Text Input Buffer Design (Step 4 Piece 3)

**Approach:** raw `wl_keyboard` + xkbcommon (same as fuzzel). No text-input protocol needed
for a launcher — that's for IME/CJK input.

**Key API change:** switch from `xkb_state_key_get_utf32` (single codepoint → manual encode)
to `xkb_state_key_get_utf8` (writes UTF-8 bytes directly into a temp buffer). Simpler.

**Backspace detection:** check keysym via `xkb_state_key_get_one_sym` for `XKB_KEY_BackSpace`
rather than raw keycode 14. More portable.

**App fields:**
```
input_buf: [512]u8   — byte content of the input field (bytes, not codepoints)
input_len: usize     — total bytes used (a 4-byte emoji counts as 4)
cursor_byte: usize   — byte offset where cursor sits (0 = before first char)
```

**Operations:**
- Insert at `cursor_byte` → `std.mem.copyBackwards` to shift right, advance cursor
- Backspace → walk back from `cursor_byte` past UTF-8 continuation bytes (`& 0xC0 == 0x80`),
  `std.mem.copyForwards` to shift left, move cursor back
- Delete → same but forward from `cursor_byte`
- Left arrow → step `cursor_byte` back one codepoint (skip continuation bytes)
- Right arrow → step `cursor_byte` forward one codepoint (`std.unicode.utf8ByteSequenceLength`)
- Mouse click → skip for now

**Drawing resources stored in App** (listeners can't receive local vars from run()):
```
surface: ?*wl.Surface
surface_image: ?*gfx.pixman_image_t
wl_buffer: ?*wl.Buffer
font: ?*gfx.struct_fcft_font
```

**redraw(app: *App):** fillSolid → renderText(input_buf[0..input_len]) → attach + damageBuffer + commit
Initial frame also calls redraw() — same code path, empty buffer = blank dark screen.

### Reference Projects

- [fuzzel](https://codeberg.org/dnkl/fuzzel) — closest reference (launcher, fcft+pixman+layer-shell)
- [hello-zig-wayland](https://github.com/ifreund/hello-zig-wayland) — minimal zig-wayland example
- [river](https://github.com/riverwm/river) — full compositor in Zig, build.zig reference

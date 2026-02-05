# Launcher (Raycast-like app in Zig)

## Project Goal
Learning Zig by building a Raycast-like launcher application.
Background: Coming from Go.

## Current State
- Basic REPL loop with stdin/stdout
- Calculator plugin: supports +, -, *, /, % operations
- Quit command
- Temperature conversion: F ↔ C (e.g., `32F to C`, `100C in F`)
- Data unit conversion: B, KB, MB, GB, TB (e.g., `100 MB to KB`)
- Dictionary lookup: `dw <word>` using StarDict format (`src/stardict.zig`)
- SystemD commands: `suspend`/`sleep`, `hibernate`, `reboot`, `shutdown` via D-Bus

## Next Steps
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
- [ ] UI rendering for Wayland
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

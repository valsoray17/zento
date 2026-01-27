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

## Next Steps
- [ ] Application Launcher
  - [ ] fuzzy finder support (fzf lib based ideally)
- [ ] SystemD commands integration (suspend, shutdown etc.)
- [ ] Dictionary/define word (see Dictionary section below)
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
1. Parse .idx into word → (offset, size) map
2. Binary search for word
3. Read definition from .dict at offset

**Resources:**
- Format spec: github.com/huzheng001/stardict-3/blob/master/dict/doc/StarDictFileFormat
- Dictionaries: stardict.uber.space (Webster's 1913 recommended)

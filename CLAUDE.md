# Launcher (Raycast-like app in Zig)

## Project Goal
Learning Zig by building a Raycast-like launcher application.
Background: Coming from Go.

## Current State
- Basic REPL loop with stdin/stdout
- Calculator plugin: supports +, -, *, /, % operations
- Quit command
- Temperature conversion: F ↔ C (e.g., `32F to C`, `100C in F`)

## Next Steps
- [ ] Application Launcher
  - [ ] fuzzy finder support (fzf lib based ideally)
- [ ] SystemD commands integration (suspend, shutdown etc.)
- [ ] Dictionary/define word
- [ ] Remember frequently launched apps or commands (not the conversions/word definition)
- [ ] Unit conversions
  - [x] F to C (supports both "to" and "in" separators)
  - [ ] 100 MB to KB (DataUnit enum next)
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
         ├──► convertDataUnit(...)     (TODO)
         └──► calculateBandwidth(...)  (TODO)
```
- `findSeparator()` handles both " to " and " in "
- Each converter returns null if units don't match, allowing fallthrough

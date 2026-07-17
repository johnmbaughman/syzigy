# syzigy

A Z-machine interpreter written in Zig, aimed at running the classic
Infocom (and Infocom-alike) interactive fiction titles — Zork I/II/III,
Adventure (Colossal Cave, the Microsoft/Infocom port), Hitchhiker's Guide,
etc. Primary target is **version 3** story files (`.z3`), which covers
Zork I and most of the original Infocom catalog; versions 4-5 mostly work
but lack the fancier screen model (windows, colours, fonts) those versions
can use.

Built against the [Z-Machine Standards Document, revision 1.1](https://www.inform-fiction.org/zmachine/standards/z1point1/index.html)
(the same document underlying the "Learning ZIL" appendices and the `zax`
Java interpreter linked in the project's origin request).

## Status

**Verified working against a real Zork I release (`ZORK1.z3`, release
119/serial 880429)**: boots, prints the title banner and room
description, and correctly handles movement, object visibility, and
`quit`/score reporting through the real parser.

This is a from-scratch implementation, not a port — it does not share
code with `zax`. It implements:

- Header parsing and packed-address unpacking (v1-8)
- Dynamic/static/high memory as a single flat buffer with byte/word access
- Z-character text decoding (all 3 alphabets, abbreviations, 10-bit ZSCII
  escapes) and encoding (for dictionary lookups)
- The object tree: attributes, parent/sibling/child, properties
  (get/put/get_prop_addr/get_next_prop), v1-3 layout only
- Dictionary parsing, binary search (and linear search for the rare
  unsorted dictionary), and `sread`'s lexical-analysis tokenizer
- The full instruction decoder (long/short/variable forms) and the 2OP,
  1OP, 0OP, and most VAR opcodes needed to play a v3 game: arithmetic,
  comparisons, branching, calls/returns with proper local-variable frames,
  object manipulation, `sread`, `print`/`print_ret`/`print_char`/
  `print_num`/`print_addr`/`print_paddr`, `random`, `push`/`pull`,
  `show_status`, `save`/`restore`/`restart`/`quit`
- A minimal terminal "screen": scrolling output plus a one-line status
  bar (v3's `show_status`)

### Known limitations

- **Save/restore is not Quetzal-compatible.** It dumps dynamic memory,
  the stack, and call frames to `syzigy.sav` in an ad-hoc format that
  only this interpreter can read back. Good enough to save/resume a
  session; don't expect it to load in another interpreter (or vice
  versa).
- No v4+ screen model: windows, colours, fonts, timed input, and sound
  are accepted as no-ops rather than implemented.
- Object/property tables are v1-3 layout (32 attributes, 9-byte object
  entries). v4+'s wider layout (48 attributes, 14-byte entries) isn't
  implemented, so v4+ games will misbehave once they touch objects.
- `verify` (checksum opcode) always reports success rather than actually
  summing the file.

## Building

Built and verified against `zig version` `0.17.0-dev` (a master/nightly
snapshot, not a tagged release). That snapshot is mid-way through a large
standard library rewrite (`std.Io`, `main(init: std.process.Init)`,
unmanaged-by-default `ArrayList`), so `build.zig`, `main.zig`, `screen.zig`,
and the save/restore code in `cpu.zig` all target that specific API shape.
If you build with a different Zig — especially an older stable release
like 0.13/0.14 — expect compile errors in those spots (older stable Zig
has `std.fs.cwd()`, `std.io.getStdOut()`, `std.process.argsAlloc`, and a
managed `ArrayList(T).init(allocator)` instead).

```sh
zig build
```

`zig build run` doesn't currently pass `-- <args>` through to the exe in
this Zig snapshot (`b.args` isn't exposed yet), so run the built binary
directly:

```sh
zig-out/bin/syzigy path/to/game.z3
```

Story files aren't included — bring your own `.z3`/`.z5` (Zork I's
`ZORK1.DAT`/`.z3` release, the public-domain Adventure port, etc).

## Layout

```
src/
  main.zig                 CLI entry point
  zmachine/
    header.zig              header parsing (spec §11)
    memory.zig               flat memory, byte/word/packed-address helpers
    text.zig                  Z-character decode/encode (spec §3)
    object.zig                 object tree + properties (spec §12)
    dictionary.zig               dictionary + sread tokenizer (spec §13, §15.20)
    cpu.zig                       instruction decode/execute loop (spec §4-15)
    screen.zig                     terminal I/O + status line (spec §8)
```

## Testing

```sh
zig build test
```

Unit tests currently cover text encoding. Most correctness was verified
by actually playing Zork I end to end (see Status above); `cpu.zig` has a
`debug_trace` const near the top that, set to `true`, prints every
decoded instruction (`pc`/opcode/operand count) to stderr — useful if a
different story file misbehaves.

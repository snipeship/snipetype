# snipetype

A terminal typing test with vim mode.

**Web:** [snipetype.com](https://snipetype.com)

## Install

```bash
bunx snipetype@latest
# or
npx snipetype@latest
```

## Usage

```bash
snipetype                      # 10 random words
snipetype -m sentences         # coherent sentences
snipetype -m code -l rust      # code snippets
snipetype -m vim               # multi-line vim editing
snipetype -t 60                # 60 second challenge
```

## Keys

| Key | Action |
|-----|--------|
| `ctrl+p` | settings |
| `tab` | restart / indent (vim insert) |
| `ctrl+c` | quit |

### Vim Mode

Motions: `h j k l w b e 0 $ ^ gg G`

Insert: `i I a A o O s S`

Visual: `v V` then `d/c/y`

Operators: `d dd D c cc C y yy x X p P J r`

## Build from source

Requires [Zig](https://ziglang.org/) 0.15.2+

```bash
zig build run
```

## License

MIT

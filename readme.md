# chip8z

Scuffed chip8 emulator written in zig.

## running

Requires zig 0.15.x and SDL2-devel.

```sh
# gui version
zig build
./zig-out/bin/c8 roms/keys.c8

# tui version (wip)
zig build -Dtui=true
./zig-out/bin/c8-tui roms/keys.c8
```

#!/usr/bin/env bash
set -e
# Workaround for Zig 0.16.0 + GCC 16 sframe (R_X86_64_PC64) on Arch
# Strips .sframe from crt files in a private mount namespace, then builds.
# No sudo needed, no system files modified.
if ! command -v zig >/dev/null 2>&1; then
  export PATH="$HOME/.local/share/mise/shims:$PATH"
fi
echo "zig $(zig version) — building imgv..."
# prepare stripped crt in /tmp
mkdir -p /tmp/stripped/usr/lib
for p in /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o; do
  if [ -f "$p" ]; then
    objcopy --remove-section .sframe --remove-section .rela.sframe "$p" "/tmp/stripped$p" 2>/dev/null || cp "$p" "/tmp/stripped$p"
  fi
done
unshare --map-root-user --mount bash -c '
mount --bind /tmp/stripped/usr/lib/crt1.o /usr/lib/crt1.o
mount --bind /tmp/stripped/usr/lib/crti.o /usr/lib/crti.o
mount --bind /tmp/stripped/usr/lib/crtn.o /usr/lib/crtn.o
zig build "$@"
' -- "$@"
echo "built -> zig-out/bin/imgv ($(du -h zig-out/bin/imgv 2>/dev/null | cut -f1))"

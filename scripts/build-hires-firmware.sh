#!/bin/bash
# Build an ArmVirtQemu (AArch64) UEFI firmware with high-resolution ramfb GOP
# modes. Stock EDK2 QemuRamfbDxe offers only 640x480 / 800x600 / 1024x768, and
# Windows on Arm has no native ramfb driver, so it inherits whatever mode the
# firmware picked. This patched driver adds 18 modes (up to 3840x2160) plus a
# custom mode supplied by the host through the fw_cfg file
# "opt/siliconwin/resolution" (e.g. "1920x1080").
#
# The patched driver source (firmware/QemuRamfb.c, QemuRamfbDxe.inf) is adapted
# from SiliconWin (OathWallet/SiliconWin, BSD-2-Clause-Patent), which itself
# adapts edk2's OvmfPkg/QemuRamfbDxe. See THIRD_PARTY_NOTICES.md.
#
# Output: work/firmware-build/hires-code.fd (64 MiB, ready for --code).
# Usage:  HV_RESOLUTION=1920x1080 ./build/winvm --code work/firmware-build/hires-code.fd ...
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${FIRMWARE_BUILD_DIR:-$ROOT/work/firmware-build}"
SRC="$BUILD/src"
QEMU_VERSION="${QEMU_VERSION:-11.1.2}"
LLVM="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"

mkdir -p "$SRC" "$BUILD/prefix/bin" "$BUILD/firmware"

# 1. QEMU source tarball ships the matching edk2 tree and edk2-build.py.
if [ ! -d "$SRC/qemu-$QEMU_VERSION/roms/edk2" ]; then
  echo "[fw] downloading QEMU $QEMU_VERSION source (edk2 included)..."
  curl -fsSL --max-time 600 -o "$SRC/qemu-$QEMU_VERSION.tar.xz" \
    "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"
  tar xf "$SRC/qemu-$QEMU_VERSION.tar.xz" \
    -C "$SRC" \
    "qemu-$QEMU_VERSION/roms/edk2" \
    "qemu-$QEMU_VERSION/roms/edk2-build.py" \
    "qemu-$QEMU_VERSION/roms/edk2-build.config"
fi
EDK2_SRC="$SRC/qemu-$QEMU_VERSION/roms/edk2"
EDK2="$SRC/edk2-work"
if [ ! -d "$EDK2" ]; then
  cp -Rc "$EDK2_SRC" "$EDK2" 2>/dev/null || cp -R "$EDK2_SRC" "$EDK2"
fi

# 2. Replace the ramfb driver with the patched, high-resolution version.
#    EDK2 sources use CRLF line endings.
for f in QemuRamfb.c QemuRamfbDxe.inf; do
  python3 -c "import sys; d=open(sys.argv[1],'rb').read().replace(b'\r\n',b'\n'); open(sys.argv[2],'wb').write(d.replace(b'\n',b'\r\n'))" \
    "$ROOT/firmware/$f" "$EDK2/OvmfPkg/QemuRamfbDxe/$f"
done

# 3. iasl (ACPICA) is needed by a few drivers. Build it locally because Apple's
#    linker rejects ACPICA's unaligned pointers unless chained fixups are off.
if [ ! -x "$BUILD/prefix/bin/iasl" ]; then
  echo "[fw] building iasl..."
  ACPICA_TAG=$(curl -fsSL "https://api.github.com/repositories/2173926/releases/latest" |
    python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
  mkdir -p "$SRC/acpica-src"
  curl -fsSL "https://github.com/acpica/acpica/archive/refs/tags/$ACPICA_TAG.tar.gz" |
    tar xz -C "$SRC/acpica-src" --strip-components 1
  LDFLAGS="-Wl,-no_fixup_chains" make -C "$SRC/acpica-src" iasl -j"$(sysctl -n hw.ncpu)" >/dev/null
  cp "$SRC/acpica-src/generate/unix/bin/iasl" "$BUILD/prefix/bin/"
fi

# 4. Build BaseTools with Apple clang, then the firmware with Homebrew LLVM
#    through edk2's CLANGDWARF profile.
export PATH="$LLVM/bin:$BUILD/prefix/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export IASL_PREFIX="$BUILD/prefix/bin/"
export CLANGDWARF_BIN="$LLVM/bin/"
export PYTHON_COMMAND=python3
make -C "$EDK2/BaseTools" -j"$(sysctl -n hw.ncpu)" CC=/usr/bin/clang CXX=/usr/bin/clang++ \
  EXTRA_OPTFLAGS="-Wno-error" >/dev/null

cd "$BUILD"
python3 "$EDK2_SRC/../edk2-build.py" \
  --config "$ROOT/firmware/hires-edk2.config" \
  --core "$EDK2" \
  --match armvirt.aa64 \
  --toolchain CLANGDWARF \
  --jobs "$(sysctl -n hw.ncpu)"

# 5. QEMU pflash requires exactly 64 MiB (edk2-build.py's padding step relies
#    on GNU truncate, which macOS does not ship).
OUT="$BUILD/firmware/windowsios-aarch64-code.fd"
python3 -c "import sys; f=open(sys.argv[1],'r+b'); f.truncate(64<<20)" "$OUT"
cp "$OUT" "$ROOT/work/firmware-build/hires-code.fd"
echo "[fw] done: $ROOT/work/firmware-build/hires-code.fd"

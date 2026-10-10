#!/bin/bash
# Build RADV Xclipse as ONE driver for Bannerlator's Wayland mode, without the Wayland adapter.
#
# The same libvulkan_radeon.so carries both worlds:
#   * the Android platform  -> HMI export, loaded by AdrenoTools (X11 games, Wayland compositor)
#   * the Wayland WSI       -> vk_icd* exports + VK_KHR_wayland_surface, loaded by the Khronos
#                              loader inside the Wine container as the Wayland game driver
# This is the recipe of Banners-Turnip's build_turnip_combined_so.sh (branch
# test/combined-android-wayland-so) applied to RADV. Two things from that recipe are NOT needed here:
# this tree's src/vulkan/vulkan-android.sym already exports the vk_icd* entry points, and libdrm
# stays statically linked, so no libdrm.so is shipped.
#
# usage: ./build-wayland.sh [path-to-android-ndk]
# The NDK can also come from ANDROID_NDK_HOME or ANDROID_NDK_ROOT.
# BUILD_DIR overrides the build directory (default: build-android-wayland).
# Requires (Linux x86_64 host): meson, ninja, python3 (mako, packaging, pyyaml), glslangValidator,
#   patchelf, curl, ar, tar, awk, pkg-config, and network access (Termux packages, Meson wraps).
#
# The two Mesa edits below (old-libwayland compatibility) are applied in place and are idempotent;
# `git checkout -- meson.build src/vulkan/wsi/wsi_common_wayland.c` reverts them. They only matter
# when the Wayland platform is built, so ./build.sh is unaffected by them.
#
# Output: dist/radv-xclipse-wayland-<mesa version>-<commit>.zip, a flat zip with
#   libvulkan_freedreno_radv.so + libwayland-client.so + libffi.so + libandroid-support.so +
#   meta.json + NOTICE.txt
# The driver is deliberately named libvulkan_freedreno_radv.so: Bannerlator's Wayland game-driver
# importer only accepts a libvulkan_freedreno*.so entry and renames it. The Khronos loader does not
# care about the file name (icd.json carries the path), and meta.json's libraryName points the
# AdrenoTools importer at the same file.

set -eu -o pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[radv-xclipse wayland] $*"; }

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
  || die "needs a Linux x86_64 host (the Termux wayland-scanner is an x86_64 binary)"

NDK="${1:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  die "pass the Android NDK path or set ANDROID_NDK_HOME"
fi
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$BIN/aarch64-linux-android34-clang" ] || die "no API 34 arm64 compiler in $BIN"
[ -x "$BIN/llvm-strip" ] || die "llvm-strip not found in $BIN"
[ -x "$BIN/llvm-readelf" ] || die "llvm-readelf not found in $BIN"

PYTHON=python3
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON=python
for tool in meson ninja "$PYTHON" glslangValidator patchelf curl ar tar awk pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

BUILD="${BUILD_DIR:-build-android-wayland}"
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"

# ---- Wayland client libraries and the host scanner, from Termux (as Banners-Turnip does) ----------
TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
TERMUX_PKGS="libwayland libwayland-protocols libffi libandroid-support"
TERMUX_HOST_PKGS="libwayland-cross-scanner"
SYSROOT="$BUILD/termux"
TPREFIX="$SYSROOT/data/data/com.termux/files/usr"

fetch() { # <url> <out>
  curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors "$1" -o "$2" || die "download failed: $1"
}

if [ ! -e "$TPREFIX/lib/libwayland-client.so" ] || [ ! -x "$TPREFIX/opt/libwayland/cross/bin/wayland-scanner" ]; then
  log "fetching Termux packages: $TERMUX_PKGS $TERMUX_HOST_PKGS"
  rm -rf "$SYSROOT" "$BUILD/debs"
  mkdir -p "$SYSROOT" "$BUILD/debs"
  fetch "$TERMUX_REPO/dists/stable/main/binary-aarch64/Packages" "$BUILD/Packages"
  for p in $TERMUX_PKGS $TERMUX_HOST_PKGS; do
    fn=$(awk -v P="$p" 'BEGIN{RS="";FS="\n"} {n="";f=""; for(i=1;i<=NF;i++){if($i~/^Package: /)n=substr($i,10); if($i~/^Filename: /)f=substr($i,11)} if(n==P){print f; exit}}' "$BUILD/Packages")
    [ -n "$fn" ] || die "Termux package $p not in the index"
    echo " - $fn"
    fetch "$TERMUX_REPO/$fn" "$BUILD/debs/$p.deb"
    rm -rf "$BUILD/debs/x" && mkdir "$BUILD/debs/x"
    (cd "$BUILD/debs/x" && ar x "../$p.deb" && tar -xf data.tar.* -C "$SYSROOT") || die "cannot unpack $p.deb"
  done
fi
for l in libwayland-client.so libffi.so libandroid-support.so; do
  [ -e "$TPREFIX/lib/$l" ] || die "Termux sysroot has no $l"
done
[ -x "$TPREFIX/opt/libwayland/cross/bin/wayland-scanner" ] || die "Termux sysroot has no host wayland-scanner"
export PATH="$TPREFIX/opt/libwayland/cross/bin:$PATH"
wayland-scanner --version

# ---- Mesa edits: load against any libwayland-client >= 1.22 (idempotent) ---------------------------
# A host app may put its own older libwayland-client first on the library path. It lacks
# wl_display_dispatch_queue_timeout, wl_display_create_queue_with_name and wl_fixes_interface, and
# the dlopen then fails on an undefined symbol. Mesa has a fallback for each; leaving the macros
# unset makes it use them. The build fails below if any of the three is still imported.
"$PYTHON" - <<'PY'
import sys

MARK = 'old-libwayland compat'

p = 'meson.build'
s = open(p).read()
for flag in ('-DHAVE_WL_DISPATCH_QUEUE_TIMEOUT', '-DHAVE_WL_CREATE_QUEUE_WITH_NAME'):
    old = "pre_args += ['%s']" % flag
    new = "message('radv-xclipse wayland build: %s left off (%s)')" % (flag, MARK)
    if new in s:
        continue
    if s.count(old) != 1:
        sys.exit('meson.build: anchor not found for ' + flag)
    s = s.replace(old, new, 1)
open(p, 'w').write(s)

p = 'src/vulkan/wsi/wsi_common_wayland.c'
s = open(p).read()
old = """#if defined(WL_FIXES_ACK_GLOBAL_REMOVE)
#define MESA_WL_FIXES_VERSION 2
#elif defined(WL_FIXES_INTERFACE)
#define MESA_WL_FIXES_VERSION 1
#endif"""
new = "/* radv-xclipse wayland build: wl_fixes left out (%s) */" % MARK
if new not in s:
    if s.count(old) != 1:
        sys.exit('wsi_common_wayland.c: MESA_WL_FIXES_VERSION block not found')
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
print('old-libwayland compat edits in place')
PY

# ---- configure + build --------------------------------------------------------------------------
cat > "$BUILD/cross.ini" <<EOF
[binaries]
c = '$BIN/aarch64-linux-android34-clang'
cpp = '$BIN/aarch64-linux-android34-clang++'
ar = '$BIN/llvm-ar'
strip = '$BIN/llvm-strip'
pkg-config = '$(command -v pkg-config)'

[properties]
cpp_link_args = ['-static-libstdc++']
sys_root = '$SYSROOT'
pkg_config_libdir = ['$TPREFIX/lib/pkgconfig', '$TPREFIX/share/pkgconfig']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

if [ ! -f "$BUILD/build.ninja" ]; then
  # Same options as build.sh, except -Dplatforms. android-strict=false is required: strict mode hides
  # VK_KHR_wayland_surface and refuses it in vkCreateInstance.
  meson setup "$BUILD" --cross-file "$BUILD/cross.ini" \
    -Dbuildtype=debugoptimized -Db_ndebug=true \
    -Dplatforms=android,wayland -Dplatform-sdk-version=34 -Dandroid-stub=true -Dandroid-strict=false \
    -Dandroid-libbacktrace=disabled \
    -Dvulkan-drivers=amd -Dgallium-drivers= -Dvulkan-layers= -Dtools= \
    -Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
    -Dglx=disabled -Dgbm=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dallow-fallback-for=libdrm,perfetto --force-fallback-for=expat,libdrm,zlib \
    -Dlibdrm:default_library=static -Dexpat:default_library=static -Dzlib:default_library=static \
    -Dc_args=-march=armv8.2-a -Dcpp_args=-march=armv8.2-a
fi

ninja -C "$BUILD" src/amd/vulkan/libvulkan_radeon.so

# ---- stage, relocate, verify --------------------------------------------------------------------
DRIVER=libvulkan_freedreno_radv.so
STAGE="$BUILD/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
"$BIN/llvm-strip" -o "$STAGE/$DRIVER" "$BUILD/src/amd/vulkan/libvulkan_radeon.so"
for l in libwayland-client.so libffi.so libandroid-support.so; do
  cp -L "$TPREFIX/lib/$l" "$STAGE/$l"
done
# AdrenoTools searches only the driver's own directory, so the bundled libraries are found via $ORIGIN.
patchelf --set-rpath '$ORIGIN' "$STAGE/$DRIVER" "$STAGE/libwayland-client.so"

RE="$BIN/llvm-readelf"
SO="$STAGE/$DRIVER"
log "NEEDED: $("$RE" -d "$SO" | grep -oP 'NEEDED.*\[\K[^]]+' | tr '\n' ' ')"
DYN="$("$RE" -d "$SO")"
grep -q 'RUNPATH.*\$ORIGIN' <<<"$DYN" || die "no DT_RUNPATH \$ORIGIN"
SYMS="$("$RE" --dyn-syms -W "$SO")"
grep -qw 'HMI' <<<"$SYMS" || die "no HMI export (AdrenoTools cannot load it)"
grep -q 'vk_icdGetInstanceProcAddr' <<<"$SYMS" || die "no vk_icdGetInstanceProcAddr export (the Khronos loader cannot load it)"
grep -q 'vk_icdNegotiateLoaderICDInterfaceVersion' <<<"$SYMS" || die "no vk_icdNegotiateLoaderICDInterfaceVersion export"
WL="$(grep -c ' UND .*wl_' <<<"$SYMS" || true)"
[ "$WL" -gt 10 ] || die "only $WL wl_* imports: the Wayland WSI is not in"
grep -q 'VK_KHR_wayland_surface' "$SO" || die "VK_KHR_wayland_surface string missing"
for sym in wl_display_dispatch_queue_timeout wl_display_create_queue_with_name wl_fixes_interface; do
  if grep -q " UND .*\b$sym\b" <<<"$SYMS"; then
    die "imports $sym: will not load against an older libwayland-client"
  fi
done
for l in libwayland-client.so libffi.so libandroid-support.so; do
  log "$l NEEDED: $("$RE" -d "$STAGE/$l" | grep -oP 'NEEDED.*\[\K[^]]+' | tr '\n' ' ')"
done
log "$WL wl_* imports, HMI + vk_icd* exported, RUNPATH \$ORIGIN"

mkdir -p dist
"$PYTHON" android/package-wayland.py "$STAGE" dist

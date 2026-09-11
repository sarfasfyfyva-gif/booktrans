#!/usr/bin/env bash
#
# Bootstraps a local Swift toolchain in WSL without root.
#
# Why this exists: the `core` job runs `swift test` on a normal Ubuntu runner,
# so the parsing/chunking/prompt logic can be developed and verified locally
# instead of waiting for CI. A stock WSL install has no libc6-dev/libgcc-dev and
# no way to install them (no sudo), so the toolchain cannot find glibc headers,
# crt objects, or libgcc.
#
# The fix is to unpack the missing development files into ~/.local/sysroot and,
# at run time, overlay them onto the real /usr/include and
# /usr/lib/x86_64-linux-gnu inside an unprivileged mount namespace. That makes
# the stock toolchain see a complete development system, so no flags have to be
# smuggled into every compiler invocation.
#
# Usage:  bash tools/setup-local-swift.sh
#         . ~/swiftenv.sh
#         swift test --package-path Packages/BookTransCore
#
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
SWIFT_BUILD="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_HOME="${SWIFT_HOME:-$HOME/swift}"
LIBS_DIR="$HOME/.local/swift-libs"
SYSROOT="${BOOKTRANS_SYSROOT:-$HOME/.local/sysroot}"
CACHE="$HOME/.local/swift-setup-cache"

UBUNTU_MAIN="http://archive.ubuntu.com/ubuntu/pool/main"

# Development packages are pinned to the host's glibc line so headers, crt
# objects and the runtime match what is already installed.
DEB_LIBC6_DEV="$UBUNTU_MAIN/g/glibc/libc6-dev_2.43-2ubuntu2_amd64.deb"
# kernel UAPI headers (linux/limits.h and friends)
DEB_LINUX_LIBC_DEV="$UBUNTU_MAIN/l/linux/linux-libc-dev_7.0.0-14.14_amd64.deb"
# libgcc.a / libgcc_s.so / crtbegin*.o / crtend*.o
DEB_LIBGCC_DEV="$UBUNTU_MAIN/g/gcc-15/libgcc-15-dev_15.2.0-16ubuntu1_amd64.deb"
DEB_GCC_BASE="$UBUNTU_MAIN/g/gcc-15/gcc-15-base_15.2.0-16ubuntu1_amd64.deb"
# zlib.h + libz.so, needed by ZIPFoundation's CZLib shim
DEB_ZLIB_DEV="$UBUNTU_MAIN/z/zlib/zlib1g-dev_1.3.dfsg+really1.3.1-1ubuntu3_amd64.deb"
# libxml2 2.15 (soname 16) is what the host ships, but the toolchain's
# swift-build links against soname 2 from the 24.04 release, so both are needed.
DEB_LIBXML2_NOBLE="$UBUNTU_MAIN/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3.8_amd64.deb"
DEB_LIBXML2_HOST="$UBUNTU_MAIN/libx/libxml2/libxml2-16_2.15.2+dfsg-0.1_amd64.deb"
DEB_LIBICU74="$UBUNTU_MAIN/i/icu/libicu74_74.2-1ubuntu3.1_amd64.deb"

DEBS=(
  "$DEB_LIBC6_DEV"
  "$DEB_LINUX_LIBC_DEV"
  "$DEB_LIBGCC_DEV"
  "$DEB_GCC_BASE"
  "$DEB_ZLIB_DEV"
  "$DEB_LIBXML2_NOBLE"
  "$DEB_LIBICU74"
)

log() { printf '\n=== %s ===\n' "$*"; }

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
  done
}
require curl tar dpkg-deb unshare find

if ! unshare -rm true 2>/dev/null; then
  echo "unprivileged user namespaces are disabled; this script cannot work." >&2
  echo "Enable with: sysctl -w kernel.unprivileged_userns_clone=1 (needs root)" >&2
  exit 1
fi

mkdir -p "$CACHE" "$LIBS_DIR" "$SYSROOT" "$HOME/bin"

# ---------------------------------------------------------------- toolchain
if [[ -x "$SWIFT_HOME/usr/bin/swift" ]]; then
  log "Swift toolchain already present at $SWIFT_HOME"
else
  log "Downloading $SWIFT_BUILD"
  curl -fsSL -o "$CACHE/swift.tar.gz" \
    "https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/${SWIFT_BUILD}/${SWIFT_BUILD}-ubuntu24.04.tar.gz"
  mkdir -p "$SWIFT_HOME"
  tar xzf "$CACHE/swift.tar.gz" -C "$SWIFT_HOME" --strip-components=1
fi

# ------------------------------------------------------- toolchain runtime
# swift-build itself links against these; they are not on the host.
log "Collecting toolchain runtime libraries"
fetch_deb() {
  local url="$1"
  local out
  out="$CACHE/$(basename "$url")"
  [[ -f "$out" ]] || curl -fsSL -o "$out" "$url"
  echo "$out"
}
if [[ ! -e "$LIBS_DIR/libxml2.so.2" ]]; then
  dpkg-deb -x "$(fetch_deb "$DEB_LIBXML2_NOBLE")" "$CACHE/xmlnoble"
  find "$CACHE/xmlnoble" -name 'libxml2.so.2*' -exec cp -a {} "$LIBS_DIR/" \;
fi
if [[ ! -e "$LIBS_DIR/libicuuc.so.74" ]]; then
  dpkg-deb -x "$(fetch_deb "$DEB_LIBICU74")" "$CACHE/icu"
  find "$CACHE/icu" -name '*.so*' -exec cp -a {} "$LIBS_DIR/" \;
fi
if ! compgen -G "$LIBS_DIR/libxml2.so.16*" >/dev/null; then
  dpkg-deb -x "$(fetch_deb "$DEB_LIBXML2_HOST")" "$CACHE/xmlhost"
  find "$CACHE/xmlhost" -name 'libxml2.so.16*' -exec cp -a {} "$LIBS_DIR/" \;
fi
# Only the wide ncurses build is installed; libncurses.so.6 is ABI compatible.
[[ -e "$LIBS_DIR/libncurses.so.6" ]] || \
  ln -sf /usr/lib/x86_64-linux-gnu/libncursesw.so.6 "$LIBS_DIR/libncurses.so.6"

# ------------------------------------------------------------------ sysroot
log "Unpacking development packages into $SYSROOT"
for url in "${DEBS[@]}"; do
  deb="$(fetch_deb "$url")"
  marker="$SYSROOT/.unpacked-$(basename "$deb")"
  [[ -f "$marker" ]] && continue
  dpkg-deb -x "$deb" "$SYSROOT"
  touch "$marker"
done

# The libc.so linker script references libc_nonshared.a by absolute path, which
# does not exist on the host.
sed -i "s|/usr/lib/x86_64-linux-gnu/libc_nonshared.a|$SYSROOT/usr/lib/x86_64-linux-gnu/libc_nonshared.a|g" \
  "$SYSROOT/usr/lib/x86_64-linux-gnu/libc.so"

# ----------------------------------------------------------- overlay layers
# Upper layers merged over the real directories at run time. Only regular files
# are copied: the sysroot also contains absolute symlinks into the real library
# directory, and copying those into the upper layer would make them point at
# themselves and break dlopen with ELOOP.
log "Building overlay layers"
LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu"
GCCDIR="$SYSROOT/usr/lib/gcc/x86_64-linux-gnu/15"
OVL="$SYSROOT/ovl"
rm -rf "$OVL/lib" "$OVL/inc" "$OVL/work" "$OVL/work2"
mkdir -p "$OVL/lib" "$OVL/inc" "$OVL/work" "$OVL/work2"

find "$LIBDIR" -maxdepth 1 -type f \( -name '*.o' -o -name '*.a' -o -name '*.so' \) \
  -exec cp -a {} "$OVL/lib/" \;
find "$GCCDIR" -maxdepth 1 -type f \( -name 'crt*.o' -o -name 'libgcc*.a' \) \
  -exec cp -a {} "$OVL/lib/" \;
ln -sf libgcc_s.so.1 "$OVL/lib/libgcc_s.so"
[[ -e "$OVL/lib/libz.so" ]] || ln -sf libz.so.1 "$OVL/lib/libz.so"
cp -a "$SYSROOT/usr/include/." "$OVL/inc/"

# ------------------------------------------------------------------ wrapper
log "Installing $HOME/bin/swift and $HOME/swiftenv.sh"
cat > "$HOME/bin/swift" <<'WRAPPER'
#!/usr/bin/env bash
# Local Swift entry point: overlays the userland sysroot onto the real system
# paths inside an unprivileged mount namespace (see tools/setup-local-swift.sh).
set -euo pipefail

REAL="${SWIFT_HOME:-$HOME/swift}/usr/bin/swift"

if [[ "${BOOKTRANS_SWIFT_NS:-0}" == "1" ]]; then
  exec "$REAL" "$@"
fi

# Inside the namespace uid 0 resolves to /root, so SwiftPM would look for its
# caches there and silently disable them; point them at the real home instead.
args=()
case "${1:-}" in
  --version|-version|--help|-h|help|--help-hidden|--find-tool)
    args=("$@")
    ;;
  build|test|run|package)
    args=("$1" --cache-path "$HOME/.cache/swiftpm" --config-path "$HOME/.config/swiftpm")
    shift
    args+=("$@")
    ;;
  *)
    args=("$@")
    ;;
esac

SYSROOT="${BOOKTRANS_SYSROOT:-$HOME/.local/sysroot}"
export BOOKTRANS_SWIFT_NS=1

exec unshare -rm bash -c '
  set -euo pipefail
  SYSROOT="$1"; shift
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/lib" "$STAGE/inc"
  mount --bind /usr/lib/x86_64-linux-gnu "$STAGE/lib"
  mount --bind /usr/include "$STAGE/inc"
  mount -t overlay overlay \
    -o "lowerdir=$STAGE/lib,upperdir=$SYSROOT/ovl/lib,workdir=$SYSROOT/ovl/work" \
    /usr/lib/x86_64-linux-gnu
  mount -t overlay overlay \
    -o "lowerdir=$STAGE/inc,upperdir=$SYSROOT/ovl/inc,workdir=$SYSROOT/ovl/work2" \
    /usr/include
  exec "$@"
' _ "$SYSROOT" "$REAL" "${args[@]}"
WRAPPER
chmod +x "$HOME/bin/swift"

cat > "$HOME/swiftenv.sh" <<'ENV'
# BookTrans local Swift environment (WSL, userland install, no root).
export SWIFT_HOME="$HOME/swift"
export PATH="$HOME/bin:$SWIFT_HOME/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/swift-libs:${LD_LIBRARY_PATH:-}"
ENV

log "Done"
cat <<EOF
Add to your shell:

  . ~/swiftenv.sh

Then verify:

  swift --version
  swift test --package-path Packages/BookTransCore
EOF

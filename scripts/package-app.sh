#!/bin/bash
#
# 86Box macOS ARM64 — Redistributable Packaging Script
#
# Takes the dev build at build/src/86Box.app and produces a self-contained
# 86Box.app (Qt frameworks + all Homebrew dylibs bundled) that runs on a
# machine with no Homebrew/Qt installed, then zips it for distribution.
#
# Usage:
#   ./scripts/setup-and-build.sh build     # first, if not already built
#   ./scripts/package-app.sh               # produces dist/86Box-*.zip
#
# Recipient: unzip, then either right-click > Open, or:
#   xattr -dr com.apple.quarantine 86Box.app
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Overridable so a side build (e.g. an LTO leg in its own build dir) can be
# packaged without disturbing the daily build or its dist folder.
APP_SRC="${APP_SRC:-$REPO_ROOT/build/src/86Box.app}"
DIST_DIR="${DIST_DIR:-$HOME/Desktop/86Box-dist}"
APP="$DIST_DIR/86Box.app"
ENTITLEMENTS="$REPO_ROOT/src/mac/entitlements.plist"

[[ -d "$APP_SRC" ]] || error "No build found at $APP_SRC — run:  ./scripts/setup-and-build.sh build"
[[ -f "$ENTITLEMENTS" ]] || error "Missing entitlements at $ENTITLEMENTS"

QT5_ROOT="$(brew --prefix qt@5)"
MACDEPLOYQT="$QT5_ROOT/bin/macdeployqt"
[[ -x "$MACDEPLOYQT" ]] || error "macdeployqt not found at $MACDEPLOYQT"

# Work on a copy so the dev build stays untouched
info "Copying app to dist/..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$APP_SRC" "$APP"

# Bundle Qt frameworks, plugins, and all linked Homebrew dylibs.
# -no-strip is REQUIRED: Qt5 macdeployqt's strip step corrupts arm64
# binaries (writes a 32-bit 0xfeedface magic; dyld then rejects them).
info "Running macdeployqt (bundling frameworks + dylibs)..."
"$MACDEPLOYQT" "$APP" -verbose=1 -no-strip

# Homebrew's Qt5 virtual-keyboard plugin is a malformed dylib (no LC_ID_DYLIB;
# install_name_tool cannot touch it) and 86Box never uses it. Drop it -- it is
# also the only thing pulling in the QtQml/QtQuick stack, GC'd below.
info "Pruning virtual-keyboard plugin..."
rm -f  "$APP/Contents/PlugIns/platforminputcontexts/libqtvirtualkeyboardplugin.dylib"
rm -rf "$APP/Contents/PlugIns/virtualkeyboard"

# Qt5's macdeployqt misses transitive deps: copied dylibs still reference
# /opt/homebrew (e.g. libpng inside libfreetype, glib inside libfluidsynth,
# Qt-to-Qt framework links). Worse, Homebrew's Qt5 plugin dylibs are strictly
# malformed Mach-O (dyld tolerates them; install_name_tool refuses to open
# them), so rewrite load commands ourselves: in-place patch of the path
# strings to @rpath/<name>, NUL-padded within the load command -- the @rpath
# form is always shorter than the /opt/homebrew original, so it always fits.
# An LC_RPATH on the main executable resolves @rpath for the whole bundle
# (same layout Qt6's macdeployqt produces).
patch_macho() {
    /usr/bin/python3 - "$1" <<'PYEOF'
import struct, sys
p = sys.argv[1]
data = bytearray(open(p, 'rb').read())
if len(data) < 0x20 or struct.unpack_from('<I', data, 0)[0] != 0xfeedfacf:
    sys.exit(0)  # not a thin 64-bit Mach-O; nothing to patch
ncmds = struct.unpack_from('<I', data, 0x10)[0]
off = 0x20
changed = False
LC_DYLIB = (0xc, 0x18, 0x1f, 0xd)  # LOAD, LOAD_WEAK, REEXPORT, ID
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', data, off)
    if cmd in LC_DYLIB:
        name_off = struct.unpack_from('<I', data, off + 8)[0]
        raw = bytes(data[off+name_off : off+cmdsize])
        # Homebrew-relocated dylibs may lack NUL termination on the name
        # (the very malformation install_name_tool rejects); trim at the
        # first non-printable byte. Our rewrite below NUL-pads properly.
        end = 0
        while end < len(raw) and 0x20 <= raw[end] < 0x7f:
            end += 1
        path = raw[:end].decode()
        if path.startswith('/opt/homebrew'):
            if '.framework/' in path:
                new = '@rpath/' + path.split('/lib/', 1)[1]
            else:
                new = '@rpath/' + path.rsplit('/', 1)[1]
            nb = new.encode()
            avail = cmdsize - name_off
            if len(nb) + 1 > avail:
                sys.exit(f'no room for {new} in {p}')
            data[off+name_off : off+cmdsize] = nb + b'\0' * (avail - len(nb))
            changed = True
    off += cmdsize
if changed:
    open(p, 'wb').write(data)
PYEOF
}

FW_DIR="$APP/Contents/Frameworks"

# Homebrew's "SDL2" is sdl2-compat, which dlopens SDL3 at runtime (tries
# @loader_path/libSDL3.dylib first). A dlopen is invisible to the link-graph
# walk below, so stage SDL3 next to it explicitly; the fixup loop then
# cleans up any Homebrew references inside it.
if [[ -e "$FW_DIR/libSDL2-2.0.0.dylib" && ! -e "$FW_DIR/libSDL3.dylib" ]]; then
    info "Staging libSDL3 for sdl2-compat's runtime dlopen..."
    cp /opt/homebrew/lib/libSDL3.dylib "$FW_DIR/libSDL3.dylib"
    chmod u+w "$FW_DIR/libSDL3.dylib"
fi

# VDE networking is dlopen'd by bare leaf name, so it resolves off the
# executable's rpath -- on a dev machine that finds Homebrew's copy and the
# leak never shows. Stage it, or the packaged app silently loses the VDE
# network option elsewhere. Absence is not fatal (SLiRP/PCap unaffected).
if [[ ! -e "$FW_DIR/libvdeplug.dylib" ]]; then
    if VDE_SRC="$(ls /opt/homebrew/lib/libvdeplug.dylib 2>/dev/null)"; then
        info "Staging libvdeplug for the VDE network backend's dlopen..."
        cp -L "$VDE_SRC" "$FW_DIR/libvdeplug.dylib"
        chmod u+w "$FW_DIR/libvdeplug.dylib"
    else
        warn "libvdeplug.dylib not found (brew install vde) -- packaged app"
        warn "will have no VDE networking."
    fi
fi

# Qt's cocoa Vulkan blitter dlopens MoltenVK from
# @executable_path/../Frameworks first. Also invisible to the link-graph
# walk, and staging it here is what lets the Vulkan renderer work on a
# machine with no Homebrew/Vulkan SDK at all -- no loader, no ICD manifest.
# Absence is not fatal: the app falls back to the software renderer.
# An optional pinned dylib in ~/r128-re/prebuilt ALWAYS wins, even over
# a dylib macdeployqt already staged -- lets a MoltenVK version A/B ride
# through packaging without touching the brew formula.
if [[ -e "$HOME/r128-re/prebuilt/libMoltenVK.dylib" ]]; then
    info "Staging pinned libMoltenVK (~/r128-re/prebuilt) for the Vulkan renderer..."
    cp -L "$HOME/r128-re/prebuilt/libMoltenVK.dylib" "$FW_DIR/libMoltenVK.dylib"
    chmod u+w "$FW_DIR/libMoltenVK.dylib"
elif [[ ! -e "$FW_DIR/libMoltenVK.dylib" ]]; then
    if [[ -e /opt/homebrew/lib/libMoltenVK.dylib ]]; then
        info "Staging libMoltenVK (brew) for the Vulkan renderer's dlopen..."
        cp -L /opt/homebrew/lib/libMoltenVK.dylib "$FW_DIR/libMoltenVK.dylib"
        chmod u+w "$FW_DIR/libMoltenVK.dylib"
    else
        warn "libMoltenVK.dylib not found (brew install molten-vk) -- packaged"
        warn "app will have no Vulkan renderer."
    fi
fi

info "Fixing up transitive Homebrew references..."
PASS=0
while :; do
    PASS=$((PASS + 1))
    CHANGED=0
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q 'Mach-O' || continue
        NEEDS_PATCH=0
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            # Some Homebrew dylibs already use @rpath internally (resolved
            # via their own LC_RPATH into /opt/homebrew); satisfy those
            # from Homebrew's lib symlink farm. No patching needed.
            if [[ "$dep" == @rpath/* ]]; then
                rel="${dep#@rpath/}"
                if [[ ! -e "$FW_DIR/$rel" ]]; then
                    base="$(basename "$rel")"
                    [[ -e "/opt/homebrew/lib/$base" ]] ||
                        error "Cannot satisfy $dep (needed by ${f#$APP/})"
                    cp "/opt/homebrew/lib/$base" "$FW_DIR/$base"
                    chmod u+w "$FW_DIR/$base"
                    CHANGED=1
                fi
                continue
            fi
            NEEDS_PATCH=1
            # Make sure the referenced library exists inside the bundle
            if [[ "$dep" == *'.framework/'* ]]; then
                fwname="$(basename "${dep%%.framework/*}").framework"
                if [[ ! -d "$FW_DIR/$fwname" ]]; then
                    ditto "${dep%%.framework/*}.framework" "$FW_DIR/$fwname"
                fi
            else
                base="$(basename "$dep")"
                dest="$FW_DIR/$base"
                if [[ ! -e "$dest" ]]; then
                    [[ -e "$dep" ]] || error "Dependency vanished: $dep (needed by ${f#$APP/})"
                    cp "$dep" "$dest"      # follows symlinks
                    chmod u+w "$dest"
                fi
            fi
        done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' |
                 LC_ALL=C sed 's/[^[:print:]].*//' |
                 grep -e '^/opt/homebrew' -e '^@rpath/' || true)
        if [[ "$NEEDS_PATCH" -eq 1 ]]; then
            chmod u+w "$f"
            patch_macho "$f" || error "Mach-O patch failed on ${f#$APP/}"
            CHANGED=1
        fi
    done < <(find "$APP" -type f -print0)
    [[ "$CHANGED" -eq 1 ]] || break
    [[ "$PASS" -lt 10 ]] || error "Fixup did not converge after 10 passes"
done
info "Fixup converged after $PASS pass(es)."

# @rpath resolution for every image in the bundle
MAIN_BIN="$APP/Contents/MacOS/86Box"
if ! otool -l "$MAIN_BIN" | grep -A2 LC_RPATH | grep -q '@executable_path/\.\./Frameworks'; then
    info "Adding LC_RPATH to main executable..."
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_BIN"
fi

# GC Qt frameworks nothing references anymore (the pruned keyboard plugin was
# the sole user of the Qml stack). Repeat until stable: Qml refs Qt internals.
info "Removing unreferenced Qt frameworks..."
while :; do
    REMOVED=0
    for fwdir in "$FW_DIR"/*.framework; do
        [[ -d "$fwdir" ]] || continue
        fw="$(basename "$fwdir" .framework)"
        REFERENCED=0
        while IFS= read -r -d '' f; do
            [[ "$f" == "$fwdir"/* ]] && continue
            file -b "$f" | grep -q 'Mach-O' || continue
            if otool -L "$f" | tail -n +2 | grep -q "/$fw.framework/"; then
                REFERENCED=1
                break
            fi
        done < <(find "$APP" -type f -print0)
        if [[ "$REFERENCED" -eq 0 ]]; then
            info "  dropping unreferenced $fw.framework"
            rm -rf "$fwdir"
            REMOVED=1
        fi
    done
    [[ "$REMOVED" -eq 1 ]] || break
done

# Every bundled reference must resolve inside the bundle
info "Checking for dangling in-bundle references..."
DANGLING=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    while IFS= read -r dep; do
        rel="${dep#@executable_path/../Frameworks/}"
        rel="${rel#@rpath/}"
        if [[ ! -e "$APP/Contents/Frameworks/$rel" ]]; then
            warn "Dangling reference in ${f#$APP/}: $dep"
            DANGLING=1
        fi
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' |
             LC_ALL=C sed 's/[^[:print:]].*//' |
             grep -e '^@executable_path' -e '^@rpath' || true)
done < <(find "$APP" -type f -print0)
[[ "$DANGLING" -eq 0 ]] || error "Bundle has dangling references — see above"

# macdeployqt + install_name_tool invalidate signatures; re-sign everything ad-hoc.
# Nested code first, then the app itself WITH the JIT entitlement
# (the dynarec needs it -- plain ad-hoc would crash on launch).
info "Re-signing bundle (ad-hoc, JIT entitlement on main app)..."
find "$APP/Contents/Frameworks" -maxdepth 1 \
     \( -name '*.dylib' -o -name '*.framework' \) -print0 |
    xargs -0 -n1 codesign --force -s -
find "$APP/Contents/PlugIns" -name '*.dylib' -print0 2>/dev/null |
    xargs -0 -n1 codesign --force -s -
codesign --force -s - --entitlements "$ENTITLEMENTS" "$APP"

# Verify signature
info "Verifying code signature..."
codesign --verify --strict --deep "$APP" || error "Signature verification failed"

# Verify no Mach-O in the bundle still references /opt/homebrew
info "Checking for leftover Homebrew references..."
LEAKS=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        if otool -L "$f" | tail -n +2 | grep -q '/opt/homebrew'; then
            warn "Still references /opt/homebrew: ${f#$APP/}"
            otool -L "$f" | grep '/opt/homebrew' | sed 's/^/    /'
            LEAKS=1
        fi
    fi
done < <(find "$APP" -type f -print0)
[[ "$LEAKS" -eq 0 ]] || error "Bundle is not self-contained — see leaks above"

# Confirm the JIT entitlement survived
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'allow-jit' ||
    error "JIT entitlement missing from final signature"

# Zip (ditto preserves bundle metadata; standard for .app distribution)
GITHASH="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ZIP="$DIST_DIR/86Box-macos-arm64-$GITHASH.zip"
info "Creating $ZIP..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
info "Done. Redistributable zip:"
echo "  $ZIP"
echo ""
info "Recipient instructions (Apple Silicon Mac):"
echo "  1. Unzip"
echo "  2. xattr -dr com.apple.quarantine 86Box.app   (or right-click > Open)"
echo "  3. ROMs go in ~/Library/Application Support/86Box/roms (or next to the app)"

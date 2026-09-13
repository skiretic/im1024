#!/bin/bash
#
# 86Box macOS Setup & Build Script (arm64 Homebrew, x86_64 MacPorts)
#
# Usage:
#   ./scripts/setup-and-build.sh deps      Install dependencies (arm64: Homebrew, x86_64: MacPorts)
#   ./scripts/setup-and-build.sh build      Clean configure + build + codesign .app
#   ./scripts/setup-and-build.sh            Show help
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

# ---------------------------------------------------------------------------
# deps — install Homebrew packages
# ---------------------------------------------------------------------------
cmd_deps() {
    if [[ "$(uname -m)" == "x86_64" ]]; then
        cmd_deps_macports
        return
    fi

    info "Checking for Homebrew..."
    if ! command -v brew &>/dev/null; then
        error "Homebrew not found. Install it from https://brew.sh"
    fi

    info "Installing required dependencies..."
    brew install cmake sdl2 rtmidi openal-soft fluidsynth libslirp vde \
                 libserialport qt@5

    info "Dependencies installed."
    echo ""
    info "Next step:  ./scripts/setup-and-build.sh build"
}

# ---------------------------------------------------------------------------
# deps on Intel -- MacPorts (Homebrew no longer builds x86_64 bottles)
# ---------------------------------------------------------------------------
cmd_deps_macports() {
    local port=/opt/local/bin/port
    local qt5_portfile=/opt/local/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/aqua/qt5/Portfile

    [[ -x "$port" ]] || error "MacPorts not found. Install it from https://www.macports.org/install.php"

    info "Syncing the MacPorts tree..."
    sudo "$port" selfupdate

    # selfupdate can restore the stock Portfile, so patch after it. Vulkan on:
    # MOLTENVK=ON needs QT_CONFIG(vulkan). qttools' clang dependency only
    # feeds qdoc and would cost a full llvm build.
    info "Patching the qt5 Portfile..."
    sudo sed -i '' \
        -e 's/-no-feature-vulkan/-feature-vulkan/g' \
        -e '/VULKAN_SDK=/!s/configure.env-append MAKE=/configure.env-append VULKAN_SDK=${prefix} MAKE=/' \
        -e 's/"port:clang-\${llvm_version}"/""/' \
        "$qt5_portfile"
    if grep -q -e '-no-feature-vulkan' -e 'port:clang-' "$qt5_portfile"; then
        error "qt5 Portfile patch did not apply: $qt5_portfile"
    fi

    info "Installing dependencies..."
    sudo "$port" install cmake ninja pkgconfig vulkan-headers vulkan-loader MoltenVK \
        SDL3 rtmidi openal-soft fluidsynth libslirp vde2 libserialport \
        libpng freetype zstd libsndfile

    # -s covers every dependency of the ports it installs, so Qt's own
    # dependencies go first and take binary archives where they exist.
    info "Installing Qt 5 dependencies..."
    sudo "$port" install '(' rdepof:qt5-qtbase or rdepof:qt5-qttools or rdepof:qt5-qtimageformats ')' \
        and not '(' qt5-qtbase or qt5-qtdeclarative or qt5-qtsvg or qt5-qttools or qt5-qtimageformats ')'

    # From source so a Vulkan-off binary archive is never used. The app bundle
    # needs qtimageformats for the ICNS plugin.
    info "Building Qt 5 from source (long)..."
    sudo "$port" -s install qt5-qtbase qt5-qttools qt5-qtimageformats

    info "Dependencies installed."
    echo ""
    info "Next step:  ./scripts/setup-and-build.sh build"
}

# ---------------------------------------------------------------------------
# build — configure, compile, codesign
# ---------------------------------------------------------------------------
cmd_build() {
    cd "$REPO_ROOT"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This script targets macOS."
    fi

    NCPU="$(sysctl -n hw.ncpu)"
    BUILD_DIR="build"

    # arm64 builds against Homebrew, x86_64 against MacPorts
    case "$(uname -m)" in
        arm64)
            QT5_ROOT="$(brew --prefix qt@5)"
            OPENAL_ROOT="$(brew --prefix openal-soft)"
            LIBSERIALPORT_ROOT="$(brew --prefix libserialport)"
            PLATFORM_ARGS=(--toolchain ./cmake/llvm-macos-aarch64.cmake)
            MVK_CANDIDATE=/opt/homebrew/lib/libMoltenVK.dylib
            ;;
        x86_64)
            QT5_ROOT=/opt/local/libexec/qt5
            OPENAL_ROOT=/opt/local
            LIBSERIALPORT_ROOT=/opt/local
            PLATFORM_ARGS=(-D MOLTENVK_INCLUDE_DIR=/opt/local/include)
            MVK_CANDIDATE=/opt/local/lib/libMoltenVK.dylib
            ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            ;;
    esac

    # Sanity-check that key deps exist
    for pkg in "$QT5_ROOT" "$OPENAL_ROOT" "$LIBSERIALPORT_ROOT"; do
        [[ -d "$pkg" ]] || error "Missing dependency at $pkg — run:  ./scripts/setup-and-build.sh deps"
    done

    # Clean previous build
    if [[ -d "$BUILD_DIR" ]]; then
        info "Removing old build directory..."
        rm -rf "$BUILD_DIR"
    fi

    # Configure
    info "Configuring (CMake)..."
    cmake -S . -B "$BUILD_DIR" --preset regular \
        "${PLATFORM_ARGS[@]}" \
        -D NEW_DYNAREC=ON \
        -D QT=ON \
        -D MOLTENVK=ON \
        -D Qt5_ROOT="$QT5_ROOT" \
        -D Qt5LinguistTools_ROOT="$QT5_ROOT" \
        -D OpenAL_ROOT="$OPENAL_ROOT" \
        -D LIBSERIALPORT_ROOT="$LIBSERIALPORT_ROOT"

    # Build
    info "Building with $NCPU parallel jobs..."
    cmake --build "$BUILD_DIR" -j"$NCPU"

    # Qt's cocoa Vulkan blitter dlopens MoltenVK from
    # @executable_path/../Frameworks first. Stage it here so the dev build
    # exercises the same bundled path the packaged app ships -- no loader,
    # no ICD manifest. Must precede codesign: adding it after invalidates
    # the signature. Absence is not fatal; the Vulkan renderer just stays off.
    FW_DIR="$BUILD_DIR/src/86Box.app/Contents/Frameworks"
    MVK_SRC=""
    if [[ -e "$MVK_CANDIDATE" ]]; then
        MVK_SRC="$MVK_CANDIDATE"
    fi
    if [[ -n "$MVK_SRC" ]]; then
        info "Staging libMoltenVK ($MVK_SRC) for the Vulkan renderer's dlopen..."
        mkdir -p "$FW_DIR"
        cp -L "$MVK_SRC" "$FW_DIR/libMoltenVK.dylib"
        chmod u+w "$FW_DIR/libMoltenVK.dylib"
        # Qt's cocoa Vulkan blitter dlopens "libvulkan.dylib" and searches
        # @executable_path/../Frameworks; the official app ships MoltenVK
        # there named libVulkan.dylib (case-insensitive match). Mirror that
        # so the Vulkan renderer works with no loader and no env vars.
        ln -sf libMoltenVK.dylib "$FW_DIR/libVulkan.dylib"
        # librashader (Vulkan shader support) is dlopen'd by bare leaf name,
        # which only searches the executable's rpath -- stage the dylib and
        # add the Frameworks rpath the official packaged app has. Absence is
        # non-fatal (renderer works, shaders unavailable).
        if [[ -e "$HOME/r128-re/prebuilt/librashader.dylib" ]]; then
            cp "$HOME/r128-re/prebuilt/librashader.dylib" "$FW_DIR/librashader.dylib"
            chmod u+w "$FW_DIR/librashader.dylib"
        fi
        install_name_tool -add_rpath "@executable_path/../Frameworks" \
            "$BUILD_DIR/src/86Box.app/Contents/MacOS/86Box" 2>/dev/null || true
    else
        warn "libMoltenVK.dylib not found at $MVK_CANDIDATE -- the Vulkan"
        warn "renderer will fall back to a host Vulkan loader, or stay off."
    fi

    # Codesign with JIT entitlements
    info "Codesigning 86Box.app (ad-hoc with JIT entitlement)..."
    codesign -s - \
        --entitlements src/mac/entitlements.plist \
        --force \
        "$BUILD_DIR/src/86Box.app"

    echo ""
    info "Build complete!  App is at:"
    echo "  $REPO_ROOT/$BUILD_DIR/src/86Box.app"
    echo ""
    info "To run:  open $BUILD_DIR/src/86Box.app"
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
cmd_help() {
    echo "86Box macOS Build Script"
    echo ""
    echo "Usage:"
    echo "  ./scripts/setup-and-build.sh deps    Install dependencies"
    echo "  ./scripts/setup-and-build.sh build   Clean build + codesign .app"
    echo ""
    echo "Requirements:"
    echo "  - arm64: Homebrew (https://brew.sh)"
    echo "  - x86_64: MacPorts (https://www.macports.org)"
    echo "  - Xcode Command Line Tools (xcode-select --install)"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    deps)  cmd_deps  ;;
    build) cmd_build ;;
    *)     cmd_help  ;;
esac

#!/bin/bash
# ---------------------------------------------------------------------------
# Cross-compile libprojectM (the C++ Milkdrop engine) for tvOS as DYNAMIC
# frameworks.
#
# Produces, for both tvOS slices (appletvos = arm64 device,
# appletvsimulator = arm64 simulator):
#     libprojectM-4.framework           (core engine, glad + projectm-eval baked in)
#     libprojectM-4-playlist.framework  (playlist management)
# each with an `@rpath/<name>.framework/<name>` install name, and packages each
# as a multi-slice .xcframework of DYNAMIC frameworks that a SwiftUI tvOS app can
# link AND embed, plus a combined header tree.
#
# LINKAGE — DYNAMIC (LGPL-2.1 compliance): libprojectM is LGPL-2.1. Shipping it
# in an App-Store binary wants DYNAMIC linking so a user could in principle
# substitute their own build of the library (LGPL's relink requirement). This
# script builds SHARED libraries (-DBUILD_SHARED_LIBS=ON), wraps each resulting
# dylib in a proper dynamic .framework with an @rpath install name, and packages
# them as .xcframeworks the app EMBEDS (see apple-tv/SpinVizTV/project.yml,
# `embed: true`). Combined with the shipped LGPL license text + NOTICE and the
# in-repo patch/build script (the "modified source"), this is the standard LGPL
# mitigation. See docs/tvos-lgpl-compliance.md. (An earlier revision of this
# script built STATIC .a archives; that is fine for local dev / side-load but not
# for store distribution of an LGPL library.)
#
# vendored deps stay static: glad and projectm-eval are declared STATIC in
# projectM's CMake regardless of BUILD_SHARED_LIBS, so they are baked INTO the
# core dylib. The only inter-framework dependency is playlist -> core, rewritten
# to @rpath below. So a shared build emits exactly two dylibs, not a swarm.
#
# ENGINE VERSION: built from projectM master @ 98101f5 (same commit the
# Android app uses) so presets behave identically across Android and tvOS.
# GLES is enabled (-DENABLE_GLES=ON) so the renderer targets OpenGL ES, which
# is what tvOS provides (OpenGLES.framework, ES 3.0).
#
# TVOS NATIVE-GLES PATCH: upstream projectM hard-requires OpenGL ES >= 3.2 and
# probes for a current GL context the macOS-desktop (CGL) way. Apple caps GLES
# at 3.0 and uses EAGL (not CGL) on tvOS/iOS, so a stock build fails its GL
# requirement gate and its context-current probe there. patches/tvos-gles30.patch
# lowers the GLES gate to 3.0/GLSL-ES-3.00 (which is all projectM's "#version 300
# es" shaders actually need) and reports a current context on TARGET_OS_IPHONE.
# It is applied to the checked-out source below so the rebuilt engine runs
# natively on Apple's GLES 3.0 with NO app-side version-spoof / CGL shim.
#
# Runs ON a Mac with Xcode + the tvOS SDK (developed against Xcode 26.2 /
# tvOS SDK 26.2). No Homebrew required: a pinned CMake is downloaded locally.
#
# Usage:
#   ./build-projectm-tvos.sh              # build + package both slices
#   ./build-projectm-tvos.sh sim          # simulator slice only
#   ./build-projectm-tvos.sh device       # device slice only
#   ./build-projectm-tvos.sh clean        # remove build trees (keeps sources)
#
# Final artifacts land in:   $BUILD_ROOT/xcframeworks/
#   libprojectM-4.xcframework           (dynamic frameworks, two slices)
#   libprojectM-4-playlist.xcframework  (dynamic frameworks, two slices)
#   include/projectM-4/*.h
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Configuration ---------------------------------------------------------
PROJECTM_REPO="https://github.com/projectM-visualizer/projectm.git"
PROJECTM_COMMIT="98101f5"          # master; matches the Android engine build
CMAKE_VERSION="3.31.7"             # pinned; matches Android's 3.22-era toolchain family
DEPLOYMENT_TARGET="17.0"           # tvOS 17+ (matches SpinVizTV app)

# Heavy build tree lives OUTSIDE the git repo (it is multi-GB of objects).
BUILD_ROOT="${BUILD_ROOT:-$HOME/spinviz-tvos/projectm-build}"
SRC_DIR="$BUILD_ROOT/projectm"
CMAKE_DIR="$BUILD_ROOT/cmake"
CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
OUT_DIR="$BUILD_ROOT/xcframeworks"

# CMake flags mirrored from the Android recipe (android-tv/build-projectm.sh),
# adapted for Apple: DYNAMIC libs (LGPL) + GLES instead of Android GL.
COMMON_FLAGS=(
    -G "Unix Makefiles"
    -DCMAKE_SYSTEM_NAME=tvOS
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DENABLE_GLES=ON
    -DENABLE_PLAYLIST=ON
    -DENABLE_SYSTEM_PROJECTM_EVAL=OFF
    -DENABLE_SYSTEM_GLM=OFF
    -DENABLE_SDL_UI=OFF
    -DBUILD_TESTING=OFF
)

# projectM version baked into the framework Info.plist (matches the built engine).
FW_VERSION="4.1.0"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

# --- Argument handling -----------------------------------------------------
SLICES=("appletvsimulator" "appletvos")
case "${1:-}" in
    sim)     SLICES=("appletvsimulator") ;;
    device)  SLICES=("appletvos") ;;
    clean)
        rm -rf "$BUILD_ROOT"/build-* "$BUILD_ROOT"/frameworks-* "$OUT_DIR"
        echo "Removed build trees and xcframework output (sources kept)."
        exit 0
        ;;
    "")      ;;
    *) echo "Usage: $0 [sim|device|clean]"; exit 1 ;;
esac

mkdir -p "$BUILD_ROOT"

# --- 1. Ensure a usable CMake ---------------------------------------------
if [ ! -x "$CMAKE_BIN" ]; then
    echo "=== Downloading CMake $CMAKE_VERSION (no Homebrew needed) ==="
    tarball="cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
    curl -fsSL -o "$BUILD_ROOT/$tarball" \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${tarball}"
    tar xzf "$BUILD_ROOT/$tarball" -C "$BUILD_ROOT"
    rm -rf "$CMAKE_DIR"
    mv "$BUILD_ROOT/cmake-${CMAKE_VERSION}-macos-universal" "$CMAKE_DIR"
    rm -f "$BUILD_ROOT/$tarball"
fi
echo "CMake: $("$CMAKE_BIN" --version | head -1)"

# --- 2. Ensure projectM source at the pinned commit (recursive) -----------
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "=== Cloning projectM (recursive) ==="
    git clone --recursive "$PROJECTM_REPO" "$SRC_DIR"
fi
echo "=== Checking out projectM @ $PROJECTM_COMMIT ==="
git -C "$SRC_DIR" fetch --all --tags --quiet || true
# Discard any previously-applied patch so checkout + re-apply is reproducible.
git -C "$SRC_DIR" checkout -- src/libprojectM/Renderer/Platform/ 2>/dev/null || true
git -C "$SRC_DIR" checkout "$PROJECTM_COMMIT" --quiet
git -C "$SRC_DIR" submodule update --init --recursive --quiet
echo "projectM HEAD: $(git -C "$SRC_DIR" rev-parse HEAD)"

# --- 2b. Apply the tvOS native-GLES-3.0 patch ------------------------------
# Lowers projectM's GLES requirement gate (3.2 -> 3.0) and adds a TARGET_OS_IPHONE
# (tvOS/iOS EAGL) current-context probe, so the engine runs on Apple's native
# GLES 3.0 without the app-side GLContextShim version-spoof / CGL stub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/tvos-gles30.patch"
if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: patch not found: $PATCH_FILE"; exit 1
fi
echo "=== Applying tvOS native-GLES-3.0 patch ==="
git -C "$SRC_DIR" apply --check "$PATCH_FILE"
git -C "$SRC_DIR" apply "$PATCH_FILE"
echo "  applied: $(basename "$PATCH_FILE")"

# --- Framework-wrapping helper ---------------------------------------------
# Wrap a plain tvOS .dylib into a flat (iOS/tvOS-style) dynamic .framework with
# an @rpath install name, so it can be embedded in an app bundle and packaged
# into an .xcframework. Copies the combined header tree into Headers/.
write_framework_plist() {
    local plist="$1" name="$2" platform="$3"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${name}</string>
    <key>CFBundleIdentifier</key><string>com.github.projectm-visualizer.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${name}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${FW_VERSION}</string>
    <key>CFBundleVersion</key><string>${FW_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>${platform}</string></array>
    <key>MinimumOSVersion</key><string>${DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST
}

wrap_framework() {
    local dylib="$1" name="$2" outdir="$3" platform="$4"
    local fw="$outdir/${name}.framework"
    rm -rf "$fw"; mkdir -p "$fw/Headers"
    cp "$dylib" "$fw/$name"
    chmod u+w "$fw/$name"
    # Own install name -> @rpath so the embedding app resolves it from
    # @executable_path/Frameworks (Xcode adds that rpath when embedding).
    install_name_tool -id "@rpath/${name}.framework/${name}" "$fw/$name"
    # Rewrite any dependency on the sibling core dylib to its @rpath framework path.
    local dep
    dep="$(otool -L "$fw/$name" | awk '/libprojectM-4[^-]/ && !/playlist/ && !/@rpath\/libprojectM-4\.framework/ {print $1; exit}')"
    if [ -n "$dep" ] && [ "$name" != "libprojectM-4" ]; then
        install_name_tool -change "$dep" "@rpath/libprojectM-4.framework/libprojectM-4" "$fw/$name"
    fi
    cp "$OUT_DIR/include/projectM-4/"*.h "$fw/Headers/" 2>/dev/null || true
    write_framework_plist "$fw/Info.plist" "$name" "$platform"
    echo "  wrapped: ${name}.framework  (id=$(otool -D "$fw/$name" | tail -1))"
}

# --- 3. Build each slice ---------------------------------------------------
for SDK in "${SLICES[@]}"; do
    echo ""
    echo "=================================================================="
    echo "=== Building libprojectM (dynamic) for $SDK (arm64) ==="
    echo "=================================================================="
    BDIR="$BUILD_ROOT/build-$SDK"
    rm -rf "$BDIR"; mkdir -p "$BDIR"

    "$CMAKE_BIN" -S "$SRC_DIR" -B "$BDIR" \
        "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_SYSROOT="$SDK"

    "$CMAKE_BIN" --build "$BDIR" -j "$JOBS" --target projectM projectM_playlist
done

# --- 4. Assemble the combined public header tree --------------------------
# One include/ dir with projectM-4/ holding every core + playlist header,
# including CMake-generated headers (version.h, *_export.h). Copied into each
# framework's Headers/ AND kept as a standalone include/ the app points
# HEADER_SEARCH_PATHS at.
echo ""
echo "=== Assembling headers ==="
INC="$OUT_DIR/include/projectM-4"
rm -rf "$OUT_DIR/include"; mkdir -p "$INC"
# Static (checked-in) headers
cp "$SRC_DIR"/src/api/include/projectM-4/*.h "$INC/"
cp "$SRC_DIR"/src/playlist/api/projectM-4/*.h "$INC/"
# Generated headers from whichever slice we built (identical across slices)
GEN_BDIR="$BUILD_ROOT/build-${SLICES[0]}"
cp "$GEN_BDIR"/src/api/include/projectM-4/*.h "$INC/"
cp "$GEN_BDIR"/src/playlist/include/projectM-4/*.h "$INC/"
echo "  headers: $(ls "$INC"/*.h | wc -l | tr -d ' ') files"

# --- 4b. Wrap each slice's dylibs into dynamic frameworks ------------------
echo ""
echo "=== Wrapping dylibs into dynamic frameworks ==="
for SDK in "${SLICES[@]}"; do
    BDIR="$BUILD_ROOT/build-$SDK"
    FWDIR="$BUILD_ROOT/frameworks-$SDK"
    rm -rf "$FWDIR"; mkdir -p "$FWDIR"
    [ "$SDK" = "appletvsimulator" ] && PLATFORM="AppleTVSimulator" || PLATFORM="AppleTVOS"

    # Pick the REAL (non-symlink) versioned dylib CMake produced for each lib.
    pick_dylib() {
        local dir="$1" base="$2" f
        for f in "$dir/$base"*.dylib; do
            [ -e "$f" ] || continue
            [ -L "$f" ] && continue
            echo "$f"; return 0
        done
        return 1
    }
    CORE_DYLIB="$(pick_dylib "$BDIR/src/libprojectM" "libprojectM-4" || true)"
    PLAY_DYLIB="$(pick_dylib "$BDIR/src/playlist" "libprojectM-4-playlist" || true)"
    for f in "$CORE_DYLIB" "$PLAY_DYLIB"; do
        [ -n "$f" ] && [ -f "$f" ] || { echo "ERROR: expected dylib missing under $BDIR"; exit 1; }
    done

    echo "--- $SDK ($PLATFORM) ---"
    wrap_framework "$CORE_DYLIB" "libprojectM-4"          "$FWDIR" "$PLATFORM"
    wrap_framework "$PLAY_DYLIB" "libprojectM-4-playlist" "$FWDIR" "$PLATFORM"
done

# --- 5. Package xcframeworks (dynamic frameworks) --------------------------
package_xcframework() {
    local libname="$1"        # libprojectM-4 | libprojectM-4-playlist
    local args=()
    for SDK in "${SLICES[@]}"; do
        args+=(-framework "$BUILD_ROOT/frameworks-$SDK/${libname}.framework")
    done
    rm -rf "$OUT_DIR/${libname}.xcframework"
    xcodebuild -create-xcframework "${args[@]}" -output "$OUT_DIR/${libname}.xcframework"
}

echo ""
echo "=== Packaging xcframeworks ==="
package_xcframework "libprojectM-4"
package_xcframework "libprojectM-4-playlist"

# --- 6. Report -------------------------------------------------------------
echo ""
echo "=================================================================="
echo "DONE. Artifacts in: $OUT_DIR"
echo "=================================================================="
ls -1 "$OUT_DIR"
VSTR=$(grep PROJECTM_VERSION_STRING "$INC/version.h" | head -1 | sed 's/.*"\(.*\)".*/\1/')
VVCS=$(grep PROJECTM_VERSION_VCS "$INC/version.h" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "projectM version: $VSTR  (vcs $VVCS)"
echo ""
echo "Confirm each core framework is a DYNAMIC lib (Mach-O type + @rpath id):"
for SDK in "${SLICES[@]}"; do
    slice="tvos-arm64"
    [ "$SDK" = "appletvsimulator" ] && slice="tvos-arm64-simulator"
    bin="$OUT_DIR/libprojectM-4.xcframework/$slice/libprojectM-4.framework/libprojectM-4"
    [ -f "$bin" ] || continue
    echo "  $slice: $(file -b "$bin" | sed 's/ (.*//')"
    echo "           id  $(otool -D "$bin" | tail -1)"
    echo "           sym $(nm "$bin" 2>/dev/null | grep -c ' T _projectm_create') exported projectm_create"
done

# --- 7. Verify the GLES-3.0 patch actually landed in the built engine -------
echo ""
echo "=== Verify native-GLES-3.0 patch is compiled into the engine ==="
GLADSRC="$SRC_DIR/src/libprojectM/Renderer/Platform/GladLoader.cpp"
RESSRC="$SRC_DIR/src/libprojectM/Renderer/Platform/GLResolver.cpp"
fail=0
if grep -q 'WithMinimumVersion(3, 0)' "$GLADSRC" && grep -q 'WithMinimumShaderLanguageVersion(3, 0)' "$GLADSRC"; then
    echo "  OK  GLES gate lowered to 3.0 / GLSL ES 3.00"
else
    echo "  FAIL GLES gate not lowered in GladLoader.cpp"; fail=1
fi
if grep -q 'WithMinimumVersion(3, 2)' "$GLADSRC"; then
    echo "  FAIL old 3.2 gate still present in GladLoader.cpp"; fail=1
fi
if grep -q 'TARGET_OS_IPHONE' "$RESSRC"; then
    echo "  OK  TARGET_OS_IPHONE (EAGL) current-context probe present"
else
    echo "  FAIL EAGL current-context probe missing in GLResolver.cpp"; fail=1
fi
[ "$fail" = 0 ] || { echo "PATCH VERIFICATION FAILED"; exit 1; }

# --- 8. Headless link test: prove the C API links against the dynamic frameworks -
echo ""
echo "=== Link test (C API resolves against the dynamic framework) ==="
LT_DIR="$SCRIPT_DIR/linktest"
if [ -f "$LT_DIR/pmlink.c" ]; then
    for SDK in "${SLICES[@]}"; do
        if [ "$SDK" = "appletvsimulator" ]; then
            slice="tvos-arm64-simulator"; triple="arm64-apple-tvos${DEPLOYMENT_TARGET}-simulator"; out="$LT_DIR/pmlink_sim"
        else
            slice="tvos-arm64"; triple="arm64-apple-tvos${DEPLOYMENT_TARGET}"; out="$LT_DIR/pmlink_dev"
        fi
        fwbin="$OUT_DIR/libprojectM-4.xcframework/$slice/libprojectM-4.framework/libprojectM-4"
        # Link directly against the framework binary (it carries an @rpath install
        # name; unresolved at runtime is fine — this only proves link-time symbols).
        xcrun --sdk "$SDK" clang++ -target "$triple" \
            -I "$OUT_DIR/include" "$LT_DIR/pmlink.c" \
            "$fwbin" \
            -framework OpenGLES -framework Foundation -o "$out" \
            && echo "  OK  $SDK: linked against dynamic framework, projectM symbols resolved -> $(basename "$out")" \
            || { echo "  FAIL $SDK: link test failed"; exit 1; }
    done
else
    echo "  (skipped: linktest/pmlink.c not found)"
fi
echo ""
echo "All verifications passed."

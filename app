#!/bin/bash
# One script for every command. Written on day one, not when it starts hurting.
# Nobody remembers an xcodebuild invocation with signing flags, and typing it by
# hand is where the drift starts.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SnaprMac"
PRODUCT="Snapr"
INSTALLED="/Applications/$PRODUCT.app"
DERIVED="$PWD/.build/xcode"
BUNDLE_ID="com.hengkysandy.snapr.mac"
VERSION="$(grep -m1 'CFBundleShortVersionString' project.yml | sed 's/.*"\(.*\)".*/\1/')"

# The signing identity is machine specific, so it lives in a gitignored file.
#
# This is NOT the usual "fall back to ad-hoc so anyone can build it" pattern.
# MEASURED on the capture probe: under ad-hoc the designated requirement is
# `designated => cdhash H"..."`. The CDHash changes on every build, macOS drops
# the Screen Recording grant with it, and the app then looks perfectly healthy
# while capturing nothing at all. So the fallback is loud rather than silent.
SIGNING=()
if [ -f .app-signing ]; then
  IDENTITY="$(cat .app-signing)"
  SIGNING=("CODE_SIGN_IDENTITY=$IDENTITY" "CODE_SIGN_STYLE=Manual")
else
  echo "############################################################"
  echo "WARNING: no .app-signing file, falling back to ad-hoc."
  echo ""
  echo "The app WILL build and WILL launch, and it will be silently"
  echo "broken after the next rebuild, because macOS ties the Screen"
  echo "Recording permission to the code signature."
  echo ""
  echo "Fix, once:"
  echo "  security find-identity -v -p codesigning"
  echo "  echo 'Apple Development: you@example.com (TEAMID)' > .app-signing"
  echo "############################################################"
fi

BUILD_FLAGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -derivedDataPath "$DERIVED"
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
)

usage() {
  cat <<'EOF'
./app <command>

  up        generate, build Debug, install to /Applications, launch
  build     generate and build Debug, do not install
  test      core tests (fast, no app) then the Mac integration tests
  dmg       Release build, staged as a drag installer, into dist/
  sig       show the designated requirement. It must NOT contain a cdhash
  icons     build art/AppIcon.icns from art/icon.png with iconutil
  logs      tail this app's os.Logger output
  trust     revoke the Screen Recording grant, to re-test first run
  clean     remove build products
EOF
}

case "${1:-}" in
  gen)
    xcodegen generate
    ;;

  build)
    xcodegen generate
    xcodebuild "${BUILD_FLAGS[@]}" -configuration Debug "${SIGNING[@]}" build
    ;;

  up)
    xcodegen generate
    xcodebuild "${BUILD_FLAGS[@]}" -configuration Debug "${SIGNING[@]}" build
    pkill -f "$PRODUCT.app" 2>/dev/null || true
    sleep 0.3
    rm -rf "$INSTALLED"
    # Install to /Applications, not a build folder inside a dot-directory.
    # MEASURED on the probe: Finder does not show a dot-directory in the
    # permission picker, and a clean build deletes the path, which silently
    # invalidates the TCC grant.
    cp -R "$DERIVED/Build/Products/Debug/$APP_NAME.app" "$INSTALLED"
    # `open`, never the binary directly. MEASURED: running the binary from a
    # terminal makes TCC attribute every permission check to the RESPONSIBLE
    # PROCESS, which is the terminal. A brand new app with nothing granted
    # reported that it held both grants.
    open "$INSTALLED"
    echo "installed and launched $INSTALLED"
    ;;

  test)
    swift test                      # core: fast, no app, no permissions
    xcodegen generate
    xcodebuild "${BUILD_FLAGS[@]}" -configuration Debug "${SIGNING[@]}" test
    ;;

  coretest)
    swift test
    ;;

  dmg)
    xcodegen generate
    # Release, not Debug. Debug carries assertions and is slower for no benefit
    # to the person installing it.
    xcodebuild "${BUILD_FLAGS[@]}" -configuration Release "${SIGNING[@]}" build
    rm -rf dist && mkdir -p dist/stage
    cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "dist/stage/$PRODUCT.app"
    ln -s /Applications "dist/stage/Applications"   # makes it a drag installer
    hdiutil create -volname "$PRODUCT $VERSION" -srcfolder dist/stage \
                   -ov -format UDZO "dist/$PRODUCT-$VERSION.dmg"
    rm -rf dist/stage
    echo
    echo "dist/$PRODUCT-$VERSION.dmg"
    echo
    echo "NOTE: a free Apple account cannot notarise. On any Mac that did not"
    echo "build this, Gatekeeper blocks the first launch. The user opens"
    echo "System Settings > Privacy & Security and presses Open Anyway."
    ;;

  sig)
    # The one check that matters. The designated requirement must contain the
    # identifier and the certificate, and must NOT contain a cdhash. If it
    # does, every rebuild silently drops the Screen Recording permission.
    TARGET="${2:-$INSTALLED}"
    codesign -dv --verbose=4 "$TARGET" 2>&1 | grep -E '^(Identifier|CDHash|Signature|TeamIdentifier|Authority)' || true
    echo
    REQ="$(codesign -d --requirements - "$TARGET" 2>&1 | grep designated || true)"
    echo "$REQ"
    echo
    if echo "$REQ" | grep -qi cdhash; then
      echo "FAIL: the requirement is pinned to the binary hash."
      echo "      Every rebuild will drop the Screen Recording permission."
      exit 1
    else
      echo "PASS: identity-based requirement, no cdhash. Survives rebuilds."
    fi
    ;;

  icons)
    [ -f art/icon.png ] || { echo "art/icon.png missing"; exit 1; }
    rm -rf art/AppIcon.iconset && mkdir -p art/AppIcon.iconset
    for s in 16 32 128 256 512; do
      sips -z $s $s art/icon.png --out "art/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
      sips -z $((s*2)) $((s*2)) art/icon.png --out "art/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns art/AppIcon.iconset -o art/AppIcon.icns
    echo "art/AppIcon.icns"
    ;;

  logs)
    # /usr/bin/log, not `log`. `log` is a zsh builtin and `log show ...` fails
    # with "too many arguments", invisibly if stderr is redirected.
    /usr/bin/log show --last "${2:-5m}" --info --debug \
      --predicate "subsystem == \"$BUNDLE_ID\"" \
      --style compact
    ;;

  trust)
    echo "revoking Screen Recording for $BUNDLE_ID"
    tccutil reset ScreenCapture "$BUNDLE_ID"
    ;;

  clean)
    rm -rf .build dist "$APP_NAME.xcodeproj"
    ;;

  *)
    usage
    ;;
esac

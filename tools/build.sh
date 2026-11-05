#!/bin/bash
# Builds Epitome.app with the Swift toolchain from Apple's Command Line Tools.
#
#   tools/build.sh build     compile (release) and assemble build/Epitome.app
#   tools/build.sh test      compile and run the engine self-tests
#   tools/build.sh run       build, then (re)launch the app
#   tools/build.sh pkg       build a universal app and an installer package in build/
#   tools/build.sh stop      quit a running copy launched from build/
#   tools/build.sh info      print toolchain / OS information
#   tools/build.sh clean     remove build products

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
ACTION="${1:-build}"
CONFIG="${EPITOME_CONFIG:-release}"
APP="$ROOT/build/Epitome.app"

info() {
  echo "== system"; sw_vers 2>/dev/null; uname -m
  echo "== toolchain"; xcode-select -p 2>/dev/null; swift --version 2>&1 | head -2
  echo "== sdk"; xcrun --show-sdk-path 2>/dev/null; xcrun --show-sdk-version 2>/dev/null
}

compile() {
  local started=$(date +%s)
  echo "== swift build -c $CONFIG"
  swift build -c "$CONFIG" --product Epitome 2>&1 | grep -v '^\[' ; local s1=${PIPESTATUS[0]}
  [ $s1 -ne 0 ] && { echo "BUILD FAILED (Epitome)"; return $s1; }
  swift build -c "$CONFIG" --product ep 2>&1 | grep -v '^\[' ; local s2=${PIPESTATUS[0]}
  [ $s2 -ne 0 ] && { echo "BUILD FAILED (ep)"; return $s2; }
  echo "compiled in $(( $(date +%s) - started ))s"
  return 0
}

# Builds the Intel (x86_64) slice next to the native one.
compile_intel() {
  echo "== swift build -c $CONFIG --triple x86_64-apple-macosx13.0"
  swift build -c "$CONFIG" --product Epitome --triple x86_64-apple-macosx13.0 2>&1 | grep -v '^\[' | grep -v 'warning:' ; local s1=${PIPESTATUS[0]}
  [ $s1 -ne 0 ] && return $s1
  swift build -c "$CONFIG" --product ep --triple x86_64-apple-macosx13.0 2>&1 | grep -v '^\[' | grep -v 'warning:' ; return ${PIPESTATUS[0]}
}

# Merges the Apple silicon and Intel binaries; prints the folder holding the results.
universal_bin() {
  local ARM X86 OUT="$ROOT/.build/universal"
  ARM="$(swift build -c "$CONFIG" --show-bin-path)"
  X86="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx13.0 --show-bin-path)"
  mkdir -p "$OUT"
  lipo -create "$ARM/Epitome" "$X86/Epitome" -output "$OUT/Epitome" >&2 || return 1
  lipo -create "$ARM/ep" "$X86/ep" -output "$OUT/ep" >&2 || return 1
  echo "$OUT"
}

assemble() {
  local BIN="$1"
  [ -z "$BIN" ] && BIN="$(swift build -c "$CONFIG" --show-bin-path)"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
  cp "$BIN/Epitome" "$APP/Contents/MacOS/Epitome" || return 1
  cp "$BIN/ep" "$APP/Contents/Helpers/ep" || return 1
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist" || return 1
  [ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
  [ -d "$ROOT/Resources/Help" ] && cp -R "$ROOT/Resources/Help" "$APP/Contents/Resources/"
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/ep" 2>&1
  codesign --force --sign - --timestamp=none --identifier app.epitome.mac "$APP" 2>&1 || return 1
  echo "assembled $APP ($(du -sh "$APP" | cut -f1))"
}

# Installer package: Epitome.app into /Applications, plus the ep command in /usr/local/bin.
make_pkg() {
  compile || return 1
  local BIN="" ARCHS="arm64"
  if compile_intel && BIN="$(universal_bin)"; then
    ARCHS="arm64,x86_64"
  else
    BIN=""
    echo "(the Intel build did not work; making an Apple silicon package)"
  fi
  assemble "$BIN" || return 1
  lipo -info "$APP/Contents/MacOS/Epitome"
  local VERSION WORK="$ROOT/build/pkg" OUT
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  OUT="$ROOT/build/Epitome-$VERSION.pkg"
  rm -rf "$WORK" "$OUT"
  mkdir -p "$WORK/root/Applications" "$WORK/scripts" "$WORK/resources"
  ditto "$APP" "$WORK/root/Applications/Epitome.app" || return 1
  cp "$ROOT/tools/pkg/postinstall" "$WORK/scripts/postinstall" && chmod 755 "$WORK/scripts/postinstall"
  cp "$ROOT/tools/pkg/welcome.html" "$ROOT/tools/pkg/conclusion.html" "$ROOT/tools/pkg/background.png" "$WORK/resources/"
  # Always install into /Applications, even when another copy (like build/) has the same bundle ID.
  pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" || return 1
  /usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$WORK/component.plist" || return 1
  pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --identifier app.epitome.mac.pkg \
    --version "$VERSION" --install-location / --scripts "$WORK/scripts" "$WORK/Epitome-app.pkg" || return 1
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCHS@/$ARCHS/g" "$ROOT/tools/pkg/distribution.xml" > "$WORK/distribution.xml"
  productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" --resources "$WORK/resources" "$OUT" || return 1
  echo "== package contents"
  pkgutil --payload-files "$WORK/Epitome-app.pkg" | head -12
  echo "package: $OUT ($(du -h "$OUT" | cut -f1)), $ARCHS"
}

stop_app() {
  # Ask a running copy to quit normally (it saves its index), then make sure it is gone.
  if pgrep -x Epitome >/dev/null; then
    [ -x "$APP/Contents/Helpers/ep" ] && "$APP/Contents/Helpers/ep" -exit >/dev/null 2>&1
    for _ in $(seq 1 30); do pgrep -x Epitome >/dev/null || break; sleep 0.5; done
    pkill -x Epitome 2>/dev/null && sleep 2
  fi
  return 0
}

case "$ACTION" in
  info)  info ;;
  build) info; compile && assemble ;;
  test)
    swift build -c "$CONFIG" --product epitome-selftest 2>&1 | grep -v '^\[' ; s=${PIPESTATUS[0]}
    [ $s -ne 0 ] && { echo "BUILD FAILED (selftest)"; exit $s; }
    "$(swift build -c "$CONFIG" --show-bin-path)/epitome-selftest" ;;
  run)
    compile && assemble || exit 1
    stop_app
    rm -f "$ROOT/.inbox/app.log"
    open -n "$APP" --args -debuglog "$ROOT/.inbox/app.log"
    sleep 4
    echo "== launched"; pgrep -lx Epitome
    [ -f "$ROOT/.inbox/app.log" ] && tail -n 60 "$ROOT/.inbox/app.log"
    [ -f "$ROOT/.inbox/app-stderr.log" ] && { echo "== stderr"; tail -n 80 "$ROOT/.inbox/app-stderr.log"; } ; true ;;
  relaunch)
    stop_app
    rm -f "$ROOT/.inbox/app.log"
    open -n "$APP" --args -debuglog "$ROOT/.inbox/app.log"
    sleep 4; pgrep -lx Epitome
    [ -f "$ROOT/.inbox/app.log" ] && tail -n 60 "$ROOT/.inbox/app.log"
    [ -f "$ROOT/.inbox/app-stderr.log" ] && { echo "== stderr"; tail -n 80 "$ROOT/.inbox/app-stderr.log"; } ; true ;;
  applog) [ -f "$ROOT/.inbox/app.log" ] && tail -n 300 "$ROOT/.inbox/app.log"
    [ -f "$ROOT/.inbox/app-stderr.log" ] && { echo "== stderr"; tail -n 200 "$ROOT/.inbox/app-stderr.log"; } ; true ;;
  pkg)   info; make_pkg ;;
  stop)  stop_app; echo stopped ;;
  clean) rm -rf "$ROOT/.build" "$ROOT/build"; echo cleaned ;;
  *) echo "unknown action: $ACTION"; exit 2 ;;
esac

#!/bin/bash
# Builds Edict.app from the SwiftPM package. No Xcode project, no Developer ID, no sudo.
#   ./scripts/build-app.sh            build + sign into ./build/Edict.app
#   ./scripts/build-app.sh install    …then copy to ~/Applications
# EDICT_KILL=1 quits a running copy without asking.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Edict"
BUNDLE_ID="com.srkk.edict"
SHORT_VERSION="0.1.0"
BUILD_VERSION="$(date +%Y%m%d%H%M)"
MIN_OS="26.0"

APP="$ROOT/build/$APP_NAME.app"
KEYCHAIN="$HOME/Library/Keychains/edict-signing.keychain-db"
KEYCHAIN_PW="edict-local"          # throwaway keychain: holds only a local self-signed cert
CERT_CN="Edict Local Signing"
INSTALL_DIR="$HOME/Applications"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m/!\\\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- running app?
running_pids() {
  # Matches both the dev copy and the installed copy by executable path.
  pgrep -f "/$APP_NAME\.app/Contents/MacOS/$APP_NAME" || true
}
ensure_not_running() {
  local PIDS; PIDS="$(running_pids)"
  [ -n "$PIDS" ] || return 0
  warn "$APP_NAME is running (pid: $(echo "$PIDS" | tr '\n' ' '))."
  warn "Overwriting a running .app leaves it half-replaced; it must be quit first."
  ANSWER=n
  if [ "${EDICT_KILL:-}" = "1" ]; then
    ANSWER=y
  elif [ -t 0 ]; then
    read -r -p "    Quit it now? [y/N] " ANSWER
  else
    die "aborted (non-interactive). Re-run with EDICT_KILL=1 to quit it automatically."
  fi
  case "$ANSWER" in
    y|Y) # SIGTERM, not osascript: telling an app to quit via AppleEvents would make
         # macOS ask the user to grant this terminal Automation access.
         #
         # Every test below is an `if`, never `[ ... ] && cmd`: under `set -e` an AND-list
         # whose left side is false returns 1 as the statement's status, which aborts the
         # script on the *healthy* path. That bug made EDICT_KILL=1 exit silently right
         # after printing the warning, so the app was never actually quit.
         kill $(running_pids) 2>/dev/null || true
         for _ in 1 2 3 4 5 6 7 8 9 10; do
           if [ -z "$(running_pids)" ]; then break; fi
           sleep 0.5
         done
         if [ -n "$(running_pids)" ]; then kill -9 $(running_pids) 2>/dev/null || true; fi
         sleep 0.5
         if [ -n "$(running_pids)" ]; then die "could not quit $APP_NAME; quit it manually."; fi ;;
    *)   die "aborted. Quit $APP_NAME and re-run." ;;
  esac
}

# Checked twice: once here, and again immediately before the bundle is replaced.
# `swift build -c release` sits between the two calls, which is a wide enough
# window for the app to get launched in the meantime. Replacing the binary of a
# running copy gets that process SIGKILLed by the kernel — CODESIGNING /
# Invalid Page — the moment it faults in a __TEXT page that no longer matches
# the signature it launched with. The failure is delayed and looks like an app
# bug, so it is worth two cheap pgreps to make it impossible.
ensure_not_running

# ---------------------------------------------------------- signing identity
# A stable local certificate is the whole point: with it the designated requirement is
#   identifier "com.srkk.edict" and certificate root = H"<sha1>"
# so TCC (Accessibility / Input Monitoring) grants survive every rebuild.
# Ad-hoc (--sign -) would pin the DR to the cdhash and lose them on every rebuild.
ensure_identity() {
  if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
    return 0
  fi
  say "Creating a local self-signed code-signing identity (no admin password needed)"
  local W; W="$(mktemp -d)"
  cat > "$W/cs.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
O  = $APP_NAME
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
subjectKeyIdentifier = hash
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
      -keyout "$W/k.pem" -out "$W/c.pem" -config "$W/cs.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$W/k.pem" -in "$W/c.pem" \
      -name "$CERT_CN" -out "$W/id.p12" -passout pass:tmp >/dev/null 2>&1
  # A DEDICATED keychain with a known password: importing into login.keychain would
  # need the user's real login password for set-key-partition-list below.
  [ -f "$KEYCHAIN" ] || security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"          # no auto-lock, no lock on sleep
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security import "$W/id.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -A >/dev/null
  # MANDATORY. Without it codesign blocks forever on an invisible GUI keychain prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null 2>&1
  rm -rf "$W"
  say "Identity created in $KEYCHAIN"
}
ensure_identity

# --------------------------------------------------------------------- build
say "swift build -c release"
( cd "$ROOT" && swift build -c release )
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || die "no executable at $BIN"

# ------------------------------------------------------------------ assemble
say "Assembling $APP"
ensure_not_running          # re-check: the build above may have taken minutes
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Assets go into Contents/Resources and are read via Bundle.main.
# NEVER put a SwiftPM <Target>_<Target>.bundle at the .app root: codesign then fails
# with "unsealed contents present in the bundle root".
for f in "$ROOT/Resources/"*; do
  case "$(basename "$f")" in
    *.entitlements) continue ;;
    *)              cp -R "$f" "$APP/Contents/Resources/" ;;
  esac
done
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  say "No AppIcon.icns yet — generating one"
  "$ROOT/scripts/make-icon.sh" >/dev/null
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>            <string>$APP_NAME</string>
	<key>CFBundleName</key>                  <string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
	<key>CFBundlePackageType</key>           <string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
	<key>CFBundleShortVersionString</key>    <string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key>               <string>$BUILD_VERSION</string>
	<key>CFBundleIconFile</key>              <string>AppIcon</string>
	<key>CFBundleIconName</key>              <string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>        <string>$MIN_OS</string>
	<key>LSApplicationCategoryType</key>     <string>public.app-category.productivity</string>
	<key>NSPrincipalClass</key>              <string>NSApplication</string>
	<key>NSHighResolutionCapable</key>       <true/>
	<key>NSSupportsAutomaticTermination</key><false/>
	<key>NSSupportsSuddenTermination</key>   <false/>
	<key>NSMicrophoneUsageDescription</key>  <string>$APP_NAME records from the microphone so it can transcribe your speech on-device.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>$APP_NAME transcribes your dictation on-device.</string>
	<!-- No NSAppleEventsUsageDescription. It is only ever shown for the matching
	     com.apple.security.automation.apple-events entitlement, which we deliberately do not ship
	     (see the entitlement notes below), and nothing in Sources/ sends an Apple Event: the
	     injection ladder is AX -> paste -> keystrokes -> clipboard. A usage string with no
	     entitlement behind it is dead weight that implies a capability the app does not have. -->
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "bad Info.plist"

# ---------------------------------------------------------------------- sign
# Entitlements we ship, and why (they cannot be documented in the .entitlements file
# itself -- see the guard below):
#   com.apple.security.app-sandbox = false
#       Non-negotiable. App Sandbox has no entitlement for the Accessibility API or
#       CGEventTap, and it redirects NSHomeDirectory() into ~/Library/Containers,
#       which would move the user's dictionary.json out from under them.
#   com.apple.security.device.audio-input = true
#       Required by the Hardened Runtime (--options runtime, below) for mic access.
# We deliberately do NOT ship com.apple.security.automation.apple-events: nothing in
# Sources/ sends an Apple Event (the injection ladder is AX -> paste -> keystrokes ->
# clipboard, none of which need it), and claiming it only earns a spurious
# "Edict wants to control other apps" TCC prompt.
#
# codesign feeds entitlements through AMFIUnserializeXML, which -- unlike plutil,
# CFPropertyList and every other plist reader -- rejects XML comments outright,
# failing with "syntax error near line N". `plutil -lint` passes such a file happily,
# so lint is not a sufficient check; grep for the comment marker explicitly.
ENT="$ROOT/Resources/$APP_NAME.entitlements"
plutil -lint "$ENT" >/dev/null || die "bad entitlements plist"
# `... && die` would return 1 on the healthy path and set -e would kill the script.
if grep -q '<!--' "$ENT"; then die "entitlements contain an XML comment; AMFI cannot parse those"; fi

say "Signing with \"$CERT_CN\""
find "$APP" -name '*.cstemp' -delete            # stale temps break the resource seal
xattr -cr "$APP" || true                        # drop com.apple.quarantine etc.
codesign --force --sign "$CERT_CN" \
         --identifier "$BUNDLE_ID" \
         --entitlements "$ENT" \
         --options runtime \
         --keychain "$KEYCHAIN" \
         --timestamp=none \
         "$APP"
codesign --verify --strict --verbose=1 "$APP"
DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

# ------------------------------------------------------------------- install
if [ "${1:-}" = "install" ]; then
  mkdir -p "$INSTALL_DIR"
  say "Installing to $INSTALL_DIR/$APP_NAME.app"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"       # ditto preserves the signature
  codesign --verify --strict "$INSTALL_DIR/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "$INSTALL_DIR/$APP_NAME.app"
  FINAL="$INSTALL_DIR/$APP_NAME.app"
else
  FINAL="$APP"
fi

cat <<NEXT

  $APP_NAME.app is ready:   $FINAL
  code identity:            $DR

  Grant permissions once (System Settings > Privacy & Security):
    1. Accessibility        -> add $FINAL     (to insert text into other apps)
    2. Input Monitoring     -> add $FINAL     (to see the hold-to-talk hotkey)
    3. Microphone           -> prompted automatically on first recording

  Because the app is signed with a stable local certificate, macOS keys those grants to
  the certificate + bundle id, NOT to the binary hash: rebuilds keep the permissions.
  Two things reset them - changing $BUNDLE_ID, or deleting $KEYCHAIN
  (which forces a new certificate). If permissions go stale, remove the $APP_NAME rows
  in those two panes with "-" and re-add the app.

  Run it:   open "$FINAL"
NEXT
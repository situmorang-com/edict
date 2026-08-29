#!/bin/bash
# Builds Edict.app from the SwiftPM package. No Xcode project, no Developer ID, no sudo.
#   ./scripts/build-app.sh            build + sign into ./build/Edict.app
#   ./scripts/build-app.sh install    …then copy to ~/Applications
# EDICT_KILL=1 quits a running copy without asking.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Edict"
BUNDLE_ID="com.edict.app"
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
#   identifier "com.edict.app" and certificate root = H"<sha1>"
# so TCC (Accessibility / Input Monitoring) grants survive every rebuild.
# Ad-hoc (--sign -) would pin the DR to the cdhash and lose them on every rebuild.
#
# UNLOCK FIRST, THEN TOUCH — and never silence a keychain call. Those two rules are the whole
# of this section, and they are here because a user of this script got a GUI dialog reading
#   'security wants to use the "edict-signing" keychain. Please enter the keychain password.'
# out of a script that has the password written into it three lines below. A keychain relocks
# at the start of every login session — set-keychain-settings turns off idle locking and
# lock-on-sleep, NOT lock-on-login — so on the first build after a login this keychain is
# locked, and the old code's first keychain call was a read, with its unlock second.
#
# Measured here on macOS 26, because the mechanism is narrower than it looks and the
# difference decides where the unlock has to go:
#   * unlock-keychain -p          never prompts. rc 0 right pw, 51 wrong pw, 50 no such file.
#   * find-certificate            does NOT prompt or unlock, even on a locked keychain, at any
#     of -c / -p / -a: certificates are public items. rc 0 found, 44 absent, and `-a` exits 0
#     with empty output when nothing matches.
#   * show-keychain-info and set-keychain-settings need authorization on a LOCKED keychain, and
#     that is where the panel comes from. First call: securityd raises the dialog and the
#     command blocks until it is answered (measured — killed after 8 s twice). Every call after
#     a cancelled dialog fails fast with rc 152, "Unable to obtain authorization for this
#     operation", for the rest of the session.
#   * set-key-partition-list -k <pw> and import -P <pw> carry their own password, so neither
#     prompts; the partition list call also unlocks the keychain as a side effect.
#   * find-identity -v -p codesigning is useless as a check: it exits 0 while printing
#     "0 valid identities found", both for an empty keychain and for this self-signed cert,
#     which is not a valid identity by policy even though codesign --sign uses it happily.
# So the old dialog was `security set-keychain-settings` on a locked keychain — a WRITE with no
# password to give, on the provisioning path, reached because create-keychain is skipped when
# the file already exists. `>/dev/null 2>&1` on the read before it is what made the whole thing
# unreadable: it suppresses the MESSAGE, not the PANEL. No keychain call here silences its
# streams any more — kc() captures both and prints everything on any failure.
KC_TIMEOUT=20
KC_OUT=""
KC_RC=0
kc() {
  # Runs one keychain command with a hard time cap, capturing stdout+stderr into KC_OUT.
  # The cap is the standing guarantee that this can never silently become a dialog again: if a
  # panel ever does appear, the build fails with keychain_die's instructions instead of waiting
  # for ever on a dialog the user has no reason to connect to this terminal.
  #
  # A watchdog subshell rather than a poll loop, because `wait` yields the command's exact
  # status with no reap race; and not timeout(1), because macOS does not ship one (the timeout
  # on this machine is Homebrew's, so the script must not depend on it).
  local out pid dog
  KC_RC=0
  out="$(mktemp -t edict-kc)"
  "$@" >"$out" 2>&1 &
  pid=$!
  ( sleep "$KC_TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
  dog=$!
  wait "$pid" || KC_RC=$?
  kill "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true
  KC_OUT="$(cat "$out")"
  rm -f "$out"
  # 137 is SIGKILL, i.e. the watchdog fired. Reported as 124 so callers can name the cause.
  if [ "$KC_RC" = 137 ]; then KC_RC=124; fi
  return "$KC_RC"
}

# Never leave the user guessing what to do about a keychain. Pass "delete-only" as $2 when
# unlocking by hand cannot fix the situation. The price of the second remedy is real and is
# stated: a new keychain means a new certificate, the certificate root is half the designated
# requirement above, so it is the one action here that genuinely costs the TCC grants.
keychain_die() {
  printf '\033[1;31mxxx\033[0m %s\n' "$1" >&2
  if [ -n "$KC_OUT" ]; then printf '    security said: %s\n' "$KC_OUT" >&2; fi
  if [ "$KC_RC" = 124 ]; then
    printf '    It stopped responding for %ss, which means securityd raised a GUI password panel\n' "$KC_TIMEOUT" >&2
    printf '    for this keychain. Nothing in this script should ever cause one.\n' >&2
  fi
  if [ "${2:-}" != "delete-only" ]; then
    cat >&2 <<MSG
    Unlock it by hand and re-run this script:
        security unlock-keychain "$KEYCHAIN"
    The password is "$KEYCHAIN_PW". It is written into this script on purpose: the keychain
    holds nothing but one local self-signed code-signing certificate.
    Or, if that does not help:
MSG
  fi
  cat >&2 <<MSG
    Delete the keychain and let this script build a new identity:
        security delete-keychain "$KEYCHAIN"
    That is a NEW certificate, so the signature's certificate root changes and macOS treats
    Edict as a different app. Re-grant Accessibility and Input Monitoring once afterwards
    (System Settings > Privacy & Security): remove the stale $APP_NAME rows in those two panes
    with "-", then re-add the app.
MSG
  exit 1
}

unlock_signing_keychain() {
  if ! kc security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"; then
    keychain_die "could not unlock $KEYCHAIN (security exited $KC_RC)"
  fi
  # The positive check the script never made. show-keychain-info is the only command that
  # answers "is this unlocked?" — it exits 0 on an unlocked keychain and cannot succeed on a
  # locked one — and it is only safe to call HERE, after the unlock and behind kc()'s cap,
  # because on a locked keychain it is one of the two commands that raise the panel.
  if ! kc security show-keychain-info "$KEYCHAIN"; then
    keychain_die "$KEYCHAIN is still locked after unlock-keychain reported success"
  fi
}

ensure_partition_list() {
  # MANDATORY, and on BOTH paths. Without a partition list naming codesign, codesign blocks
  # for ever on an invisible GUI keychain prompt. It is idempotent (measured: rc 0 on a second
  # run), so running it on every build is also the only way a keychain that still holds the
  # certificate but has lost its partition list can be repaired. The old code ran this line
  # solely in the provisioning branch — reachable only when the certificate was ABSENT — so
  # the one state it fixes was the one state it could not be reached from.
  #
  # Captured, not silenced: on success it prints a ~30-line attribute dump nobody needs, and on
  # failure the one sentence that explains a codesign hang.
  if ! kc security set-key-partition-list -S apple-tool:,apple:,codesign: \
                   -s -k "$KEYCHAIN_PW" "$KEYCHAIN"; then
    keychain_die "could not set the code-signing partition list on $KEYCHAIN (security exited $KC_RC)"
  fi
}

CERT_COUNT=0
count_certs() {
  # Sets CERT_COUNT to the number of certificates in the keychain matching common name $1, or
  # to every certificate in it when $1 is empty.
  #
  # `-a` and a count, not `-c` and an exit status, because the exit status cannot tell absence
  # from failure: find-certificate -c exits 44 both for "this keychain has no such certificate"
  # and for "there is no such keychain". `-a` exits 0 with empty output for a clean miss, so a
  # non-zero status here is a failed READ and nothing else — which is the distinction the rest
  # of this function's callers turn on.
  CERT_COUNT=0
  if [ -n "$1" ]; then
    kc security find-certificate -a -c "$1" "$KEYCHAIN" \
      || keychain_die "could not read the certificates in $KEYCHAIN (security exited $KC_RC)"
  else
    kc security find-certificate -a "$KEYCHAIN" \
      || keychain_die "could not read the certificates in $KEYCHAIN (security exited $KC_RC)"
  fi
  CERT_COUNT="$(printf '%s\n' "$KC_OUT" | grep -c '^keychain:' || true)"
}

ensure_identity() {
  local W
  if [ -f "$KEYCHAIN" ]; then
    # Unlock before the first read, not after it. Reading certificates would in fact survive a
    # locked keychain, but the write further down would not, and an unlocked keychain is a
    # cheaper precondition to establish once than to reason about per call.
    unlock_signing_keychain
    count_certs "$CERT_CN"
    if [ "$CERT_COUNT" -gt 1 ]; then
      keychain_die "$KEYCHAIN holds $CERT_COUNT certificates named \"$CERT_CN\"; codesign --sign cannot choose between them and fails \"ambiguous (matches multiple identities)\"" delete-only
    fi
    if [ "$CERT_COUNT" = 1 ]; then
      ensure_partition_list
      return 0
    fi
    # No certificate under that name. Provisioning one into an existing keychain is only safe
    # when the keychain holds no certificate at all — which is how a half-finished first run
    # leaves it. If it holds some OTHER certificate, importing would leave two code-signing
    # identities in one keychain, and that is the failure this branch exists to refuse: the old
    # code imported unconditionally, so any non-zero read became a second identity, and if the
    # duplicate is ever the one codesign picks, the certificate root changes and the grants
    # keyed to it are gone.
    count_certs ""
    if [ "$CERT_COUNT" != 0 ]; then
      keychain_die "$KEYCHAIN holds $CERT_COUNT certificate(s), none of them named \"$CERT_CN\"; this script will not add a second signing identity to it" delete-only
    fi
    say "$KEYCHAIN holds no certificate yet — creating the signing identity"
  else
    say "Creating a local self-signed code-signing identity (no admin password needed)"
    # A DEDICATED keychain with a known password: importing into login.keychain would
    # need the user's real login password for set-key-partition-list below.
    if ! kc security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"; then
      keychain_die "could not create $KEYCHAIN (security exited $KC_RC)"
    fi
    # create -> unlock -> set-keychain-settings, in that order. A keychain create-keychain has
    # just made is already unlocked, so this unlock is redundant on this path, and it is kept
    # anyway: one command buys "unlocked" as a checked precondition on both branches instead of
    # a fact inferred from which branch happened to run.
    unlock_signing_keychain
  fi

  # Past here the keychain exists and has been verified unlocked on either path, so this write
  # cannot raise the panel it used to raise whenever the file already existed and
  # create-keychain was therefore skipped.
  if ! kc security set-keychain-settings "$KEYCHAIN"; then   # no auto-lock, no lock on sleep
    keychain_die "could not disable auto-lock on $KEYCHAIN (security exited $KC_RC)"
  fi

  W="$(mktemp -d)"
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
  if ! kc security import "$W/id.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -A; then
    rm -rf "$W"
    keychain_die "could not import the new identity into $KEYCHAIN (security exited $KC_RC)"
  fi
  rm -rf "$W"
  ensure_partition_list
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

# Strip HERE, never after the codesign below. codesign seals the __LINKEDIT bytes it was handed;
# a strip that runs afterwards rewrites exactly those bytes, and the kernel then SIGKILLs the
# app on first page-in — CODESIGNING / Invalid Page, the same delayed, looks-like-an-app-bug
# failure ensure_not_running exists to prevent. The cost is one launch, not the permissions:
# the grants are keyed to the certificate root plus the bundle id (see the identity note above
# and the closing note below), so a broken seal makes the app unlaunchable until it is signed
# again, and re-signing restores it with the grants intact. And strip will not stop anyone
# getting the order wrong: against an already-signed binary it prints "warning: changes being
# made to the file will invalidate the code signature" and EXITS 0, so `set -e` catches
# nothing — the build prints success and only `codesign --verify --strict` afterwards reports
# the modified signature. Anything inserted between here and the codesign block must respect
# this.
#
# This reverses RECON's "you do not need reproducible builds at all (keep your debug symbols)".
# That recommendation was reasoned from the self-signed cert removing the reproducible-build
# motive, never from a measurement of what the symbols cost. Measured, all figures from
# `.build/release/Edict` and a `strip -S -x` copy of it — i.e. UNSIGNED, because signing then
# adds a CodeDirectory and the entitlements back into __LINKEDIT, so the binary that ships is
# necessarily larger than the stripped one measured here. The bundle's real numbers are printed
# at the end of every build; read them there rather than from a comment.
#   8,359,064 -> 3,776,584 bytes, all of it __LINKEDIT (segment 5,324,800 -> 737,280 by
#   `size -m`), whose LC_SYMTAB held 84,969 symbols over a 3,637,064-byte string table and
#   keeps 6,612 over 343,816 (`nm -a | wc -l`, `otool -l`).
# -S -x removes debugging and local symbols only: `dwarfdump --uuid` is unchanged and
# __TEXT,__text is md5-identical before and after, as are all 11 __swift5_* sections, so
# protocol conformances, field metadata and reflection are untouched and this cannot change
# behaviour. Nothing in Sources/ resolves a symbol by name either (no NSClassFromString /
# NSSelectorFromString / dlsym / Mirror). The 6,612 that remain are the global ones, so a crash
# report still names exported frames.
#
# The unstripped copy costs more than the strip saves: it is a whole 8.36 MB beside a bundle
# that just got 4.58 MB smaller, so net disk goes UP about 3.8 MB. It buys neither
# symbolication nor a byte of uniqueness — `.build/release/Edict` has the same LC_UUID and
# byte-identical __text, so `atos -o .build/release/Edict` works today. What it buys is that
# the next `swift build` overwrites `.build` while this copy stays pinned to the binary
# actually inside the shipped bundle. Symbolication is manual either way
# (`atos -o build/Edict.unstripped -l <slide> <addr>`): the shipped binary no longer carries
# the names, so Console and CrashReporter print hex for internal Swift frames.
cp "$BIN" "$ROOT/build/$APP_NAME.unstripped"
strip -S -x "$APP/Contents/MacOS/$APP_NAME"

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
	<!-- File transcription, declared so a recording can be handed to Edict from the Finder or
	     from \`open -a Edict <file>\`. LSHandlerRank is Alternate, never Owner or Default: Edict
	     must show up in "Open With" without displacing QuickTime Player as the app that opens a
	     double-clicked .m4a. Role Viewer, because nothing here writes the media back. -->
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>     <string>Audio or Video Recording</string>
			<key>CFBundleTypeRole</key>     <string>Viewer</string>
			<key>LSHandlerRank</key>        <string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.audio</string>
				<string>public.movie</string>
			</array>
		</dict>
	</array>
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

# README publishes the executable, icon and total figures, and the strip above just moved all
# three. Print the measured bytes at the end of every build so the next author regenerates them
# instead of restating a number that was measured once and then only ever repeated.
#
# Every measurement here degrades to "not measured" and none of them can fail the build. These
# lines run after the app is signed, installed and lsregistered — the work is DONE — and under
# `set -euo pipefail` a bare `stat` or `du` that returns non-zero would abort the script at that
# point, so a fully successful build would exit 1 with the permission-granting notes below never
# printed, which reads as a failed build. A line added for documentation hygiene must not be able
# to fail a build that already succeeded.
measure_bytes() {   # "<n> B", or "not measured" if stat cannot see the file
  local n
  if n="$(stat -f%z "$1" 2>/dev/null)"; then printf '%s B' "$n"; else printf 'not measured'; fi
}
measure_kb() {      # "<n> KB", or "not measured". `|| true` is needed because pipefail would
  local n           # otherwise propagate du's status out of the command substitution.
  n="$(du -sk "$1" 2>/dev/null | cut -f1 || true)"
  if [ -n "$n" ]; then printf '%s KB' "$n"; else printf 'not measured'; fi
}
EXEC_SIZE="$(measure_bytes "$FINAL/Contents/MacOS/$APP_NAME")"
ICON_SIZE="$(measure_bytes "$FINAL/Contents/Resources/AppIcon.icns")"
BUNDLE_SIZE="$(measure_kb "$FINAL")"

cat <<NEXT

  $APP_NAME.app is ready:   $FINAL
  code identity:            $DR
  measured size:            $EXEC_SIZE executable (stripped), $ICON_SIZE icon, $BUNDLE_SIZE bundle
  unstripped binary:        $ROOT/build/$APP_NAME.unstripped   (for atos -l <slide>)

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
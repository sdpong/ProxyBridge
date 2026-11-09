#!/bin/bash
# adhoc-sign.sh - sign an unsigned ProxiRoute app so its system extension can be installed.
#
# Why this exists:
#
#   The app installs a *system extension* (a network extension in the SystemExtensions
#   folder). macOS refuses to install one unless the containing app carries the
#   entitlement com.apple.developer.system-extension.install. An unsigned build has
#   no entitlements at all, so the install fails with
#   "Missing entitlement com.apple.developer.system-extension.install" and the app
#   cannot proxy anything.
#
#   A fork has no Developer ID certificate, but an *ad-hoc* signature (codesign --sign -)
#   does carry entitlements. With those embedded, macOS accepts the extension and
#   installs it; the user then approves it once in
#   System Settings > General > Login Items & Extensions > Network Extensions.
#
#   This is what an unsigned build can do. A real Developer ID build (the upstream's
#   release) is signed and notarized properly and needs none of this - so this script
#   leaves an already properly signed app alone.
#
# The app is signed WITHOUT the App Sandbox:
#
#   The sandbox is what stands between the app and the unified log, and the unified
#   log is where the system extension writes every decision it made. logd refuses to
#   serve the system scope to a sandboxed process and the /usr/bin/log tool refuses
#   to run in one at all ("Cannot run while sandboxed"). A build that is not going to
#   the App Store does not need the sandbox, and without it the window can read the
#   extension's decisions back.
#
#   The extension keeps its sandbox: it is the part that touches the traffic, and
#   nothing about reading the log back needs it changed.
#
#   Set PROXIROUTE_APP_SANDBOX=1 to sign the app with the sandbox instead, which is
#   what a build that has to run inside the App Store would use.
#
# Usage: adhoc-sign.sh <path to ProxiRoute.app>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="${1:-$APP_ROOT/output/ProxiRoute.app}"
APP_ENTITLEMENTS="$APP_ROOT/ProxiRoute/ProxiRouteReleaseNoSandbox.entitlements"
EXT_ENTITLEMENTS="$APP_ROOT/extension/extensionRelease.entitlements"
EXT_BINARY="Contents/Library/SystemExtensions/com.sdpong.proxiroute.extension.systemextension/Contents/MacOS/com.sdpong.proxiroute.extension"

if [ "${PROXIROUTE_APP_SANDBOX:-0}" = "1" ]; then
    APP_ENTITLEMENTS="$APP_ROOT/ProxiRoute/ProxiRouteRelease.entitlements"
fi

if [ ! -d "$APP" ]; then
    echo "ERROR: no app bundle at $APP"
    exit 1
fi

# A build signed with a real identity is left exactly as it is: it is signed, notarized
# and stamped already, and re-signing it ad-hoc would only make it worse.
if codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "Already signed with a Developer ID - nothing to do."
    exit 0
fi

# Already ad-hoc signed with the entitlements (the CI signs once, the packager runs
# again): nothing to do either.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.developer.system-extension.install"; then
    echo "Already signed with the needed entitlements - nothing to do."
    exit 0
fi

# The extension goes first: signing the app bundle does not re-sign the code inside it,
# and each part needs its own entitlements.
if [ -f "$APP/$EXT_BINARY" ]; then
    codesign --force --sign - \
        --entitlements "$EXT_ENTITLEMENTS" \
        --options runtime --timestamp=none \
        "$APP/$EXT_BINARY"
    echo "Signed the system extension (ad-hoc, with entitlements)."
fi

# The helper of the gateway mode travels inside the bundle until the installer
# puts it where it belongs. A bundle cannot be signed while a part of it is
# unsigned ("code object is not signed at all"), so the helper is signed as
# well - it is a program of root, and it is signed ad hoc like everything else
# here.
HELPERS_DIR="$APP/Contents/Helpers"
if [ -d "$HELPERS_DIR" ]; then
    for binary in "$HELPERS_DIR"/*; do
        [ -f "$binary" ] || continue
        # the launch daemon of the helper is a text file, not a program
        case "$binary" in
            *.plist) continue ;;
        esac
        codesign --force --sign - --timestamp=none "$binary"
        echo "Signed $(basename "$binary") (ad-hoc)."
    done
fi

codesign --force --sign - \
    --entitlements "$APP_ENTITLEMENTS" \
    --options runtime --timestamp=none \
    "$APP"
echo "Signed the app (ad-hoc, with entitlements)."

# The entitlements are the whole point of this script, so check that they are really in
# there instead of trusting the exit code.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.developer.system-extension.install"; then
    echo "ERROR: the app has no com.apple.developer.system-extension.install entitlement after signing."
    exit 1
fi

echo "✓ The app can now install its system extension (it still needs one approval in"
echo "  System Settings > General > Login Items & Extensions > Network Extensions)."

#!/bin/bash
# verify-app-signature.sh - check that an app bundle can really install its system extension.
#
# Why this exists:
#
#   The app installs a *system extension*. macOS refuses to install one unless
#   the containing app carries the entitlement
#   com.apple.developer.system-extension.install, and it refuses the whole
#   bundle when the signature does not cover everything that is inside it.
#
#   That makes a broken signature invisible until the user tries to proxy
#   something: the app starts, the window opens, and only then does the
#   system say "Missing entitlement com.apple.developer.system-extension.install".
#   The person finds out on their own machine, after the download.
#
#   The signature breaks in a way that is easy to miss: anything that writes
#   into the bundle after it was signed - a rebuild by xcodebuild, a helper
#   that is put in later - leaves the old signature behind, and the bundle
#   then looks signed (codesign -dv still prints a signature) while the
#   entitlement is gone and the nested extension is not signed at all.
#
#   So this script checks the things that actually matter, and fails when one
#   of them is not true. It is run at the end of the packaging, so a build
#   that would ship a broken app never gets to be published.
#
# Usage: verify-app-signature.sh <path to ProxiRoute.app>

set -e

APP="${1:-}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "ERROR: no app bundle given (or it does not exist): ${APP:-<empty>}"
    exit 1
fi

FAILED=0

fail() {
    echo "ERROR: $1"
    FAILED=1
}

# 1. The whole bundle has to be signed, and the signature has to be valid.
#    "code object is not signed at all" is what a bundle whose parts were
#    replaced after the signature was made looks like.
if ! codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'; then
    fail "the bundle is not signed properly (see the codesign output above)"
fi

# 2. The entitlement the system extension needs has to be in the app.
#    Without it macOS refuses to install the extension, and the app says so
#    in the log: "Missing entitlement com.apple.developer.system-extension.install".
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.developer.system-extension.install"; then
    fail "the app has no com.apple.developer.system-extension.install entitlement"
else
    echo "  ok: the app carries com.apple.developer.system-extension.install"
fi

# 3. The system extension itself has to be signed, and it has to carry the
#    network extension entitlement. A bundle that holds an unsigned extension
#    is a bundle the system refuses to load.
EXT_BUNDLE="$APP/Contents/Library/SystemExtensions/com.sdpong.proxiroute.extension.systemextension"
if [ -d "$EXT_BUNDLE" ]; then
    if ! codesign --verify --verbose=2 "$EXT_BUNDLE" 2>&1 | sed 's/^/  /'; then
        fail "the system extension inside the bundle is not signed (see the codesign output above)"
    fi
    if ! codesign -d --entitlements - "$EXT_BUNDLE" 2>/dev/null | grep -q "com.apple.developer.networking.networkextension"; then
        fail "the system extension has no com.apple.developer.networking.networkextension entitlement"
    else
        echo "  ok: the system extension is signed and carries its entitlement"
    fi
else
    fail "the bundle has no system extension in it ($EXT_BUNDLE)"
fi

# 4. The helper of the gateway mode travels inside the bundle until the
#    installer puts it where it belongs. A bundle that holds an unsigned
#    helper is a bundle the system refuses to run, so the helper has to be
#    signed as well.
HELPER="$APP/Contents/Helpers/com.sdpong.proxiroute.helper"
if [ -f "$HELPER" ]; then
    if ! codesign --verify --verbose=2 "$HELPER" 2>&1 | sed 's/^/  /'; then
        fail "the helper of the gateway mode inside the bundle is not signed"
    else
        echo "  ok: the helper of the gateway mode is signed"
    fi
else
    fail "the bundle has no helper of the gateway mode in it ($HELPER)"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "ERROR: the app bundle cannot install its system extension. Signing it again fixes this:"
    echo "  bash scripts/embed-helper.sh <path to ProxiRoute.app>"
    exit 1
fi

echo "✓ The app can install its system extension."

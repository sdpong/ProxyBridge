#!/bin/bash
# embed-helper.sh - put the helper of the gateway mode into an app bundle.
#
# Why this exists:
#
#   The helper of the gateway mode is a program of root. It travels inside the
#   app bundle until the installer puts it where it belongs
#   (/Library/PrivilegedHelperTools), and two paths take it from the bundle:
#   the install button of the app (Contents/Helpers) and the postinstall
#   script of the package. A bundle without the helper in it cannot install
#   the helper at all.
#
#   The bundle is signed, and the signature covers everything that is inside
#   it. So the bundle is signed again after the helper is put in: with the
#   identity it was signed with, or ad-hoc with the entitlements the system
#   extension needs when there is no certificate.
#
#   The order matters: the parts of the bundle are signed first, the bundle
#   itself last. A bundle whose signature does not cover its own parts is a
#   bundle the system refuses to run.
#
# Usage: embed-helper.sh <path to ProxiRoute.app> [signing identity]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HELPER_NAME="com.sdpong.proxiroute.helper"

APP="${1:-$APP_ROOT/output/ProxiRoute.app}"
IDENTITY="${2:-}"

if [ ! -d "$APP" ]; then
    echo "ERROR: no app bundle at $APP"
    exit 1
fi

# The helper is built into a temporary folder: it is put into the bundle, and
# the bundle is what is shipped.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building the helper of the gateway mode..."
bash "$SCRIPT_DIR/build-helper.sh" "$WORK/$HELPER_NAME"

# The helper is a program, so it goes into Contents/Helpers, which is where
# macOS looks for the helpers of a bundle. The daemon of the helper is a text
# file, and it goes into the resources: Contents/Helpers is a place for
# programs, and the signature of the bundle refuses anything in it that is not
# a program.
mkdir -p "$APP/Contents/Helpers"
cp -f "$WORK/$HELPER_NAME" "$APP/Contents/Helpers/$HELPER_NAME"
chmod 755 "$APP/Contents/Helpers/$HELPER_NAME"
cp -f "$SCRIPT_DIR/$HELPER_NAME.plist" "$APP/Contents/Resources/$HELPER_NAME.plist"
chmod 644 "$APP/Contents/Resources/$HELPER_NAME.plist"

if [ -n "$IDENTITY" ]; then
    EXT_BINARY="$APP/Contents/Library/SystemExtensions/com.sdpong.proxiroute.extension.systemextension/Contents/MacOS/com.sdpong.proxiroute.extension"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        --entitlements "$APP_ROOT/extension/extensionRelease.entitlements" "$EXT_BINARY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        "$APP/Contents/Helpers/$HELPER_NAME"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        --entitlements "$APP_ROOT/ProxiRoute/ProxiRouteRelease.entitlements" "$APP"
    echo "Signed the app with $IDENTITY, the helper is inside the signature."
else
    # no certificate: an ad-hoc signature carries the entitlements the system
    # extension needs, and it signs the helper of the gateway mode as well
    bash "$SCRIPT_DIR/adhoc-sign.sh" "$APP" --force
fi

# The helper has to be inside the signature of the bundle, or the system does
# not run the app at all. Say so here, where it can still be fixed.
codesign --verify --verbose=2 "$APP"

ls -la "$APP/Contents/Helpers"

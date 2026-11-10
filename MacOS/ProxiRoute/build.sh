#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="4.1.2"

# The name of the helper of the gateway mode. It is the same name in the
# privileged helper tools folder, in the launch daemon and in the log.
HELPER_NAME="com.sdpong.proxiroute.helper"

# the pkg name/version here and the version shown in the app (About page, bundle)
# come from different places, make a mismatch fail the build instead of shipping it
PROJECT_VERSIONS=$(grep "MARKETING_VERSION" "$SCRIPT_DIR/ProxiRoute.xcodeproj/project.pbxproj" | sed -E 's/.*= *([^;]+);.*/\1/' | sort -u)
if [ "$PROJECT_VERSIONS" != "$VERSION" ]; then
    echo "Version mismatch: build.sh VERSION=$VERSION but MARKETING_VERSION in the Xcode project is: $(echo $PROJECT_VERSIONS)"
    exit 1
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

APP_PATH="$SCRIPT_DIR/output/ProxiRoute.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: ProxiRoute.app not found in output directory"
    echo "Export the app from Xcode to output/ first"
    exit 1
fi

# The helper of the gateway mode is built here and not by the Xcode project.
#
# It is a program of root that lives in /Library/PrivilegedHelperTools, so it
# is not part of the app bundle in the end - but it travels inside the bundle
# until the installer puts it where it belongs.
#
# When the bundle already carries one, that one is used. The bundle is signed,
# and the signature covers the helper inside it: building a second copy and
# putting that one in would break the signature, and a bundle with a broken
# signature is an app the system refuses to run. The CI puts the helper into
# the bundle before it signs it, and the package is built from that bundle.
#
# It is built into output/ and not into build/: the build folder is wiped
# later on, and the helper has to survive that.
BUNDLED_HELPER="$APP_PATH/Contents/Helpers/$HELPER_NAME"
BUNDLED_DAEMON="$APP_PATH/Contents/Resources/$HELPER_NAME.plist"

if [ -x "$BUNDLED_HELPER" ]; then
    echo "Using the helper that is already inside the app bundle."
    HELPER_PATH="$BUNDLED_HELPER"
else
    echo "Building the helper of the gateway mode..."
    bash "$SCRIPT_DIR/scripts/build-helper.sh" "$SCRIPT_DIR/output/$HELPER_NAME"
    HELPER_PATH="$SCRIPT_DIR/output/$HELPER_NAME"

    # the helper and the daemon that starts it go into the bundle, where the
    # installer takes them from
    #
    # The helper is a program, so it goes into Contents/Helpers, which is where
    # macOS looks for the helpers of a bundle. The daemon of the helper is a text
    # file, and it goes into the resources: Contents/Helpers is a place for
    # programs, and the signature of the bundle refuses anything in it that is
    # not a program.
    mkdir -p "$APP_PATH/Contents/Helpers"
    cp -f "$HELPER_PATH" "$BUNDLED_HELPER"
    chmod 755 "$BUNDLED_HELPER"
fi

# the daemon of the helper belongs to the bundle as well, whether the helper
# came from the bundle or was built here
if [ ! -f "$BUNDLED_DAEMON" ]; then
    cp -f "$SCRIPT_DIR/scripts/$HELPER_NAME.plist" "$BUNDLED_DAEMON"
    chmod 644 "$BUNDLED_DAEMON"
fi

# The script that takes old system extension records out of the system travels
# with the app: a person who has to type a long command with the right team id
# is a person who does not do it. It is a resource of the app target in the
# Xcode project, so it is part of the build and of the signature.

# An unsigned app has no entitlements, and macOS refuses to install a system extension
# without them ("Missing entitlement com.apple.developer.system-extension.install").
# An ad-hoc signature carries them. A build signed with a real Developer ID is left
# alone. The script says what it did, so the log says where the entitlements came from.
echo "Signing the app for installation..."
bash "$SCRIPT_DIR/scripts/adhoc-sign.sh" "$APP_PATH"

# The signature is the thing that decides whether the app can install its system
# extension, and it breaks quietly: anything that writes into the bundle after
# it was signed leaves the old signature behind, so the bundle still looks signed
# while the entitlement is gone. The person finds out on their own machine, after
# the download. So the bundle is checked here, where it can still be fixed.
bash "$SCRIPT_DIR/scripts/verify-app-signature.sh" "$APP_PATH"

verify_universal() {
    local binary="$1"
    local archs
    archs="$(lipo -archs "$binary" 2>/dev/null || echo "")"
    if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
        echo "Error: $binary is not universal (found: ${archs:-none})"
        echo "Build with ARCHS=\"arm64 x86_64\" ONLY_ACTIVE_ARCH=NO before packaging."
        exit 1
    fi
    echo "  universal ok: $binary ($archs)"
}

verify_universal "$APP_PATH/Contents/MacOS/ProxiRoute"
EXT_BIN="$APP_PATH/Contents/Library/SystemExtensions/com.sdpong.proxiroute.extension.systemextension/Contents/MacOS/com.sdpong.proxiroute.extension"
if [ -f "$EXT_BIN" ]; then
    verify_universal "$EXT_BIN"
fi

# start from a clean staging directory: the script wipes it at the end, and a payload
# left over from an earlier run would be copied into itself
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$SCRIPT_DIR/build/component"

# The payload mirrors the places the files really go to.
#
# The app goes to /Applications, and the helper of the gateway mode goes to
# /Library/PrivilegedHelperTools with its launch daemon in
# /Library/LaunchDaemons. One pkgbuild call can only have one root, so the
# root holds the whole shape of the disk and the install location is the
# root of the disk.
mkdir -p "$SCRIPT_DIR/build/component/Applications"
mkdir -p "$SCRIPT_DIR/build/component/Library/PrivilegedHelperTools"
mkdir -p "$SCRIPT_DIR/build/component/Library/LaunchDaemons"
cp -R "$APP_PATH" "$SCRIPT_DIR/build/component/Applications/"

# The helper and the daemon go into the payload of the package, in the places
# where they really live on the machine.
#
# Why they are in the payload and not only copied by the postinstall script:
# the receipt of the package only knows about the files that are in the
# payload. A file that a script copies into /Library afterwards is not in the
# receipt, so taking the package away leaves the helper behind - a program of
# root that keeps running and keeps the machine changed. Putting them in the
# payload means the package owns those two places, and the removal takes the
# files away from exactly the places where they were put.
#
# The modes are set here because pkgbuild keeps the mode of the file it
# archives: 755 for the program of root, 644 for the text file of the daemon.
# The ownership is root:wheel - pkgbuild applies the recommended ownership to
# the files of the system domain.
cp -f "$HELPER_PATH" "$SCRIPT_DIR/build/component/Library/PrivilegedHelperTools/$HELPER_NAME"
chmod 755 "$SCRIPT_DIR/build/component/Library/PrivilegedHelperTools/$HELPER_NAME"
cp -f "$SCRIPT_DIR/scripts/$HELPER_NAME.plist" "$SCRIPT_DIR/build/component/Library/LaunchDaemons/$HELPER_NAME.plist"
chmod 644 "$SCRIPT_DIR/build/component/Library/LaunchDaemons/$HELPER_NAME.plist"

# The package has to carry the helper in the place where it belongs, and the
# build fails here rather than in the middle of an installation if it does not.
if [ ! -f "$SCRIPT_DIR/build/component/Library/PrivilegedHelperTools/$HELPER_NAME" ] \
   || [ ! -f "$SCRIPT_DIR/build/component/Library/LaunchDaemons/$HELPER_NAME.plist" ]; then
    echo "ERROR: the helper of the gateway mode is not in the payload of the package"
    exit 1
fi

# strip AppleDouble junk so it never lands in the payload
dot_clean "$SCRIPT_DIR/build/component" 2>/dev/null || true
find "$SCRIPT_DIR/build/component" -name '._*' -delete 2>/dev/null || true

echo "Creating installer package..."

# force BundleIsRelocatable=false so the app always installs to /Applications.
# otherwise macOS relocates the install onto any existing copy of the app it
# finds on disk (bundle relocation), leaving /Applications empty.
# pkgbuild only writes the key when the bundle is relocatable, so add it when
# it is missing instead of failing the whole build on Set.
pkgbuild --analyze --root build/component build/component.plist
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" build/component.plist 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" build/component.plist

# scripts/postinstall installs the `proxiroute` command (a launcher for the app's own executable)
# and the helper of the gateway mode.
# an installer script that is not executable is skipped silently, so check it here
[ -x "$SCRIPT_DIR/scripts/postinstall" ] || { echo "ERROR: scripts/postinstall is not executable (chmod +x)"; exit 1; }
pkgbuild \
    --root build/component \
    --component-plist build/component.plist \
    --scripts "$SCRIPT_DIR/scripts" \
    --identifier com.sdpong.ProxiRoute \
    --version "$VERSION" \
    --install-location / \
    build/temp.pkg

cat > build/distribution.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>ProxiRoute</title>
    <pkg-ref id="com.sdpong.ProxiRoute"/>
    <!-- without hostArchitectures the Installer on Apple silicon assumes an Intel-only package and offers to
         install Rosetta. the app and the extension are universal (verified above), so say so -->
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.sdpong.ProxiRoute"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.sdpong.ProxiRoute" visible="false">
        <pkg-ref id="com.sdpong.ProxiRoute"/>
    </choice>
    <pkg-ref id="com.sdpong.ProxiRoute" version="4.1.2" onConclusion="none">temp.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution build/distribution.xml \
    --package-path build \
    output/ProxiRoute-v$VERSION-Universal-Installer.pkg

echo "Package created: output/ProxiRoute-v$VERSION-Universal-Installer.pkg"

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_PASSWORD" ] && [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing installer..."
    productsign --sign "$SIGNING_IDENTITY" \
        output/ProxiRoute-v$VERSION-Universal-Installer.pkg \
        output/ProxiRoute-v$VERSION-Universal-Installer-signed.pkg

    mv output/ProxiRoute-v$VERSION-Universal-Installer-signed.pkg output/ProxiRoute-v$VERSION-Universal-Installer.pkg

    echo "Notarizing installer..."
    xcrun notarytool submit output/ProxiRoute-v$VERSION-Universal-Installer.pkg \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple output/ProxiRoute-v$VERSION-Universal-Installer.pkg
    echo "Installer signed and notarized"
else
    echo "Skipping signing/notarization - set APPLE_ID, APPLE_APP_PASSWORD, SIGNING_IDENTITY, and TEAM_ID in .env"
fi

rm -rf build

# the helper that was built here is inside the app bundle now, so that copy is
# not needed any more. The one that was already in the bundle stays there.
if [ "$HELPER_PATH" = "$SCRIPT_DIR/output/$HELPER_NAME" ]; then
    rm -f "$HELPER_PATH"
fi

echo "✓ Build complete"
echo "  App: output/ProxiRoute.app"
echo "  PKG: output/ProxiRoute-v$VERSION-Universal-Installer.pkg"

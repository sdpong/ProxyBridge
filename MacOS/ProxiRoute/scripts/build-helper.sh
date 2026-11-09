#!/bin/bash
# build-helper.sh - build the helper of the gateway mode.
#
# The helper is a program of root: it loads the rules of the packet filter,
# it turns the forwarding of the machine on and off, and it asks the kernel
# where a redirected connection was going. It is a command line tool of its
# own and it is not part of the app bundle, so it is not built by the Xcode
# project either.
#
# It is built here, with swiftc, for two reasons:
#
#   - the app bundle is signed, and a second binary inside it would have to
#     be signed with it. A program of root that lives in
#     /Library/PrivilegedHelperTools does not have to be in the bundle.
#   - the helper needs a C file (the ioctl of the filter takes a pointer and
#     Swift cannot give one to it), and the C file and the Swift files are
#     put together more easily here than in the Xcode project.
#
# The result is a universal binary: the package is for every Mac, and a
# helper that only ran on the kind of Mac it was built on would be useless.
#
# Usage: build-helper.sh <output path>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/helper"
OUTPUT="${1:-$SCRIPT_DIR/../build/helper/proxiroute-helper}"

if [ ! -d "$HELPER_DIR" ]; then
    echo "Error: the sources of the helper are not at $HELPER_DIR"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The swift files of the helper.
#
# The language between the app and the helper is written once, in the app's
# own sources, and the helper uses the same file: a language that is written
# twice is a language with two meanings.
SWIFT_SOURCES=(
    "$HELPER_DIR/main.swift"
    "$HELPER_DIR/GatewayHelper.swift"
    "$HELPER_DIR/GatewayFilter.swift"
    "$HELPER_DIR/GatewayNetwork.swift"
    "$HELPER_DIR/GatewaySocket.swift"
    "$HELPER_DIR/../ProxiRoute/GatewayProtocol.swift"
)

for source in "${SWIFT_SOURCES[@]}"; do
    if [ ! -f "$source" ]; then
        echo "Error: the source $source is not there"
        exit 1
    fi
done

# The C file is compiled for each architecture, and the object is linked into
# the binary of that architecture.
ARCHS="arm64 x86_64"
SLICES=()

for ARCH in $ARCHS; do
    echo "Building the helper for $ARCH..."

    clang \
        -c \
        -arch "$ARCH" \
        -mmacosx-version-min=11.0 \
        -Wall \
        -Wextra \
        -O2 \
        -o "$WORK/pfnatlook-$ARCH.o" \
        "$HELPER_DIR/pfnatlook.c"

    swiftc \
        -O \
        -target "$ARCH-apple-macos11" \
        -Xcc -I"$HELPER_DIR" \
        -import-objc-header "$HELPER_DIR/pfnatlook.h" \
        -o "$WORK/helper-$ARCH" \
        "${SWIFT_SOURCES[@]}" \
        "$WORK/pfnatlook-$ARCH.o"

    SLICES+=("$WORK/helper-$ARCH")
done

mkdir -p "$(dirname "$OUTPUT")"
lipo -create "${SLICES[@]}" -output "$OUTPUT"
chmod 755 "$OUTPUT"

echo "Helper built: $OUTPUT"
lipo -archs "$OUTPUT"

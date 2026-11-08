#!/bin/bash
# remove-old-extensions.sh - take the ProxyBridge system extensions that are not
# the one this build uses out of the system.
#
# Why this exists:
#
#   macOS keeps every registered version of a system extension under the same
#   bundle id, and it shows them in System Settings > General > Login Items &
#   Extensions > Network Extensions as separate entries. A build that is
#   installed while another one is still registered leaves the old record
#   behind, and the system may bind the tunnel to the old one: the app then
#   talks a protocol that build does not know, the rules and the proxies are
#   ignored, and nothing is proxied while the window shows an empty list with
#   no reason given.
#
#   The records of this project are:
#     com.sdpong.proxybridge.extension     - this build's extension
#     com.interceptsuite.ProxyBridge.fork  - an earlier bundle id of this fork
#     com.interceptsuite.ProxyBridge.extension - the upstream release
#
#   All three are removed, because the whole point is that only one record is
#   left. The app installs its extension again the next time it starts.
#
# It needs root, because it changes what the system has registered:
#
#       sudo ./remove-old-extensions.sh
#
# The team id is the thing that makes this awkward: a build signed by a
# developer has one, and an ad-hoc build has none. "systemextensionsctl
# uninstall" wants "<teamID> <bundleID>", and the manual says the team id may
# also be a single "-" ("for matching empty Team ID"). Two ways of getting this
# wrong make the tool print its usage and do nothing: leaving the team id out
# entirely, and writing "--" instead of "-". The command this script replaced
# made the first mistake, so it never removed anything.

set -u

BUNDLE_IDS="com.sdpong.proxybridge.extension com.interceptsuite.ProxyBridge.fork com.interceptsuite.ProxyBridge.extension"

if [ "$(id -u)" != "0" ]; then
    echo "This needs root. Run it again with sudo:"
    echo
    echo "    sudo $0"
    exit 1
fi

echo "ProxyBridge extensions that are registered right now:"
/usr/bin/systemextensionsctl list | /usr/bin/grep -E "$BUNDLE_IDS" || true
echo

removed=0
failed=0
for bundle in $BUNDLE_IDS; do
    # the team id of the record: the third column of the list, and a dash when
    # the build is ad-hoc. The tool wants "-" for that case ("teamID can also
    # be '-' (for matching empty Team ID)"), not an empty argument and not a
    # double dash: both of those make it print its usage and do nothing.
    teams=$(/usr/bin/systemextensionsctl list \
        | /usr/bin/awk -F'\t' -v id="$bundle" '
            $0 ~ id {
                team = $3
                gsub(/teamID\("|"\)/, "", team)
                if (team == "" || team == "-") team = "-"
                print team
            }' \
        | /usr/bin/sort -u)

    if [ -z "$teams" ]; then
        echo "  $bundle: not registered"
        continue
    fi

    for team in $teams; do
        echo "  removing $bundle (team $team) ..."
        if /usr/bin/systemextensionsctl uninstall "$team" "$bundle"; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
        fi
    done
done

echo
if [ "$removed" -gt 0 ]; then
    echo "Removed $removed record(s)."
else
    echo "Nothing was removed."
fi
if [ "$failed" -gt 0 ]; then
    echo "$failed removal(s) did not work. The records that are marked"
    echo "'terminated waiting to uninstall on reboot' are gone after the next restart."
fi
echo
echo "Now start ProxyBridge again: it installs its extension, and you approve it in"
echo "System Settings > General > Login Items & Extensions > Network Extensions."

#!/bin/bash
# remove-old-extensions.sh - take the ProxyBridge extensions that were signed by
# another team out of the system.
#
# Why this exists:
#
#   macOS keeps every registered version of a system extension under the same
#   bundle id. ProxyBridge's extension is registered as
#   com.interceptsuite.ProxyBridge.extension, so an older ProxyBridge (the
#   upstream release, signed with the upstream's Developer ID) and this build
#   (ad-hoc signed, team "none") are two separate records.
#
#   When the tunnel starts, macOS binds it to one of them. If it picks the older
#   one, the app talks a protocol that build does not know: the rules and the
#   proxies are ignored, and nothing is proxied while the window shows an empty
#   list with no reason given. Removing the old record leaves this build as the
#   only one, so the system cannot pick the wrong one.
#
#   It needs root, because it changes what the system has registered:
#
#       sudo ./remove-old-extensions.sh
#
#   It only touches extensions whose bundle id is ProxyBridge's own, and only
#   the ones signed by a team (the ad-hoc one of this build has no team and is
#   left alone).

set -e

BUNDLE_ID="com.interceptsuite.ProxyBridge.extension"

# the team id is the third column of the systemextensionsctl list; for the
# ad-hoc build that column is a dash, and some macOS versions print the team
# as teamID("XXXX")
TEAMS=$(/usr/bin/systemextensionsctl list \
    | /usr/bin/awk -F'\t' -v id="$BUNDLE_ID" '
        $0 ~ id {
            team = $3
            gsub(/teamID\("|"\)|-/, "", team)
            if (team != "") print team
        }' \
    | /usr/bin/sort -u)

if [ -z "$TEAMS" ]; then
    echo "No other ProxyBridge extension is registered. Nothing to do."
    exit 0
fi

for team in $TEAMS; do
    echo "Removing the ProxyBridge extension signed by $team ..."
    /usr/bin/systemextensionsctl uninstall "$team" "$BUNDLE_ID" || true
done

echo
echo "Done. Now approve this build in"
echo "System Settings > General > Login Items & Extensions > Network Extensions"
echo "and start ProxyBridge again."

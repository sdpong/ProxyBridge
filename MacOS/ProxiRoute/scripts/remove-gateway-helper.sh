#!/bin/bash
# remove-gateway-helper.sh - take the helper of the gateway mode out of the
# machine, and put the machine back the way it was.
#
# Why this exists:
#
#   The helper of the gateway mode is a program of root that changes the
#   machine: it loads the rules of the packet filter and turns the forwarding
#   of the machine on. If it is taken away while those rules are in place,
#   the traffic of the network is still redirected to a port where nobody is
#   listening, and it goes nowhere. That is a broken network, and the reason
#   is not written anywhere.
#
#   So the taking away is done in the right order: the rules of the machine
#   go back first, then the forwarding goes off, then the helper and its
#   daemon are taken out of the system.
#
# It needs root, because it changes what the system has:
#
#       sudo ./remove-gateway-helper.sh
#
# The rules of the machine that go back are the ones of /etc/pf.conf, which
# is the file the system itself reads. That is not "pfctl -sr": that one
# prints the filtering rules only, so the anchors of the translation would be
# lost on the way.

set -u

HELPER_NAME="com.sdpong.proxiroute.helper"
HELPER_TOOLS="/Library/PrivilegedHelperTools/$HELPER_NAME"
HELPER_DAEMON="/Library/LaunchDaemons/$HELPER_NAME.plist"
GATEWAY_RULES="/var/run/com.sdpong.proxiroute.pf.rules"
GATEWAY_ANCHOR="/var/run/com.sdpong.proxiroute.pf.anchor"

say() { echo "$@"; }

if [ "$(id -u)" -ne 0 ]; then
    say "this changes what the system has, so it has to run as root:"
    say "    sudo $0"
    exit 1
fi

say "== stopping the helper of the gateway mode =="

# The daemon is taken out of the system first, so that it does not put the
# rules back while they are being taken away.
if [ -f "$HELPER_DAEMON" ]; then
    /bin/launchctl bootout system "$HELPER_NAME" 2>&1 | sed 's/^/   /'
    /bin/launchctl unload "$HELPER_DAEMON" 2>&1 | sed 's/^/   /'
fi

say "== putting the machine back the way it was =="

# The rules of the machine go back: that file is what the system itself
# reads, so the machine is the way it was.
if [ -x /sbin/pfctl ]; then
    /sbin/pfctl -f /etc/pf.conf 2>&1 | sed 's/^/   /'
fi

# The forwarding goes off: the helper turned it on, so turning it off is
# putting things back. The switch of the filter itself is left alone, for
# the same reason: it was not ours to begin with.
if [ -x /usr/sbin/sysctl ]; then
    /usr/sbin/sysctl -w net.inet.ip.forwarding=0 2>&1 | sed 's/^/   /'
fi

# The rules of the gateway are not needed any more.
rm -f "$GATEWAY_RULES" "$GATEWAY_ANCHOR"

say "== taking the helper out of the system =="

rm -f "$HELPER_TOOLS"
rm -f "$HELPER_DAEMON"

# The socket of the helper is not there any more either.
rm -f "/var/run/$HELPER_NAME.sock"

say "== done =="
say "The helper of the gateway mode is gone and the rules of the machine are back."

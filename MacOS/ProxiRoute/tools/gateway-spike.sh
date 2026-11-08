#!/bin/sh
# gateway-spike.sh - the feasibility test of the gateway mode on macOS.
#
# The gateway mode needs two things that this machine has never done before:
# the traffic of the other terminals has to come in, and the program that
# takes it has to find out where it was going before it was redirected.
#
# This script tests both, in the smallest way that can be undone:
#
#   1. it puts one rule of its own into the packet filter, in its own anchor,
#      and puts the old ruleset back when it is done;
#   2. it sends a connection to a place, lets the filter redirect it, and asks
#      the kernel where that connection was going (DIOCNATLOOK);
#   3. it prints whether the answer came back.
#
# Nothing else on the machine is touched. The forwarding of the other
# terminals is only done with --forward, and it is put back as well.
#
# Run it with sudo:
#
#   sudo ./gateway-spike.sh
#   sudo ./gateway-spike.sh --forward
#
# The script needs: clang (or cc), python3, curl, pfctl. It cleans up after
# itself, also when it is interrupted.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="com.sdpong.spike"
TARGET_PORT=18080
REDIRECT_PORT=18081
SRC_PORT=61000
SRC_PORT_LAST=61019
FORWARD=0

TMP="$(mktemp -d /tmp/proxiroute-spike.XXXXXX)"
TARGET_PID=""
HELPER_PID=""
WAS_ENABLED="no"
OLD_FORWARDING=""

usage() {
    echo "usage: sudo $0 [--forward]"
    echo
    echo "  (no option)  test the redirect and the original destination locally"
    echo "  --forward    also turn the machine into a router and wait for a"
    echo "               client of the network (needs a second machine)"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --forward) FORWARD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

say() { echo "$@"; }
step() { echo; echo "== $* =="; }

# ---------------------------------------------------------------- the cleanup

cleanup() {
    echo
    echo "== putting the machine back as it was =="
    [ -n "$TARGET_PID" ] && kill "$TARGET_PID" 2>/dev/null
    [ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
    sleep 1
    [ -n "$TARGET_PID" ] && kill -9 "$TARGET_PID" 2>/dev/null
    [ -n "$HELPER_PID" ] && kill -9 "$HELPER_PID" 2>/dev/null

    if [ -f "$TMP/main.rules.untouched" ]; then
        echo "-- the old ruleset"
        pfctl -f "$TMP/main.rules.untouched" 2>&1 | sed 's/^/   /'
    fi
    if [ "$WAS_ENABLED" = "no" ]; then
        echo "-- the filter goes back to the way it was (off)"
        pfctl -d 2>&1 | sed 's/^/   /'
    fi
    if [ -n "$OLD_FORWARDING" ]; then
        echo "-- the forwarding goes back to $OLD_FORWARDING"
        sysctl -w "net.inet.ip.forwarding=$OLD_FORWARDING" 2>&1 | sed 's/^/   /'
    fi
    case "$TMP" in
        /tmp/proxiroute-spike.*) rm -rf "$TMP" ;;
        *) echo "the folder $TMP was not removed, it is not one of ours" ;;
    esac
    echo "== done =="
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- the checks

if [ "$(id -u)" -ne 0 ]; then
    say "this test reads and writes the packet filter, so it has to run as root:"
    say "    sudo $0"
    exit 1
fi

for tool in pfctl sysctl curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { say "the tool $tool is not there"; exit 1; }
done
CC="$(command -v clang || command -v cc || true)"
[ -n "$CC" ] || { say "no compiler (clang or cc) was found"; exit 1; }
[ -f "$HERE/gateway-natlook.c" ] || { say "gateway-natlook.c is not next to this script"; exit 1; }

# ---------------------------------------------------------------- the machine

step "what the machine looks like now"
say "the address of this machine on the network:"
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
[ -n "$IFACE" ] || IFACE=en0
LAN_IP="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
LAN_MASK="$(ipconfig getoption "$IFACE" subnet_mask 2>/dev/null || true)"
say "   interface $IFACE, address ${LAN_IP:-?}, mask ${LAN_MASK:-?}"
say "the filter:"
pfctl -s info 2>&1 | sed 's/^/   /'
if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
    WAS_ENABLED="yes"
    say "   the filter is on, and it stays on"
else
    WAS_ENABLED="no"
    say "   the filter is off, and it goes back off"
fi
OLD_FORWARDING="$(sysctl -n net.inet.ip.forwarding 2>/dev/null | tr -d '[:space:]')"
say "   the forwarding of the other terminals is ${OLD_FORWARDING:-?} (it goes back to that)"

step "the rules that are in place now (they are put back at the end)"
pfctl -sr 2>&1 | sed 's/^/   /'
pfctl -sr > "$TMP/main.rules"
cp "$TMP/main.rules" "$TMP/main.rules.untouched"

# ---------------------------------------------------------------- the build

step "building the small program that takes the redirected connection"
"$CC" -O2 -Wall -o "$TMP/gateway-natlook" "$HERE/gateway-natlook.c" 2>&1 | sed 's/^/   /'
[ -x "$TMP/gateway-natlook" ] || { say "   the program did not build"; exit 1; }
say "   ok"

# ---------------------------------------------------------------- the rules

cat > "$TMP/spike.rules" <<RULES
# The traffic of the program itself must not be redirected again.
no rdr pass on lo0 proto tcp from any port $SRC_PORT:$SRC_PORT_LAST to any
# A connection to the test place goes to the program instead.
rdr pass on lo0 proto tcp from any to 127.0.0.1 port $TARGET_PORT -> 127.0.0.1 port $REDIRECT_PORT
RULES

if [ "$FORWARD" = "1" ]; then
    SUBNET="$(python3 - "$LAN_IP" "$LAN_MASK" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
    print(net)
except Exception as exc:
    print("")
PY
)"
    [ -n "$SUBNET" ] || { say "the network of this machine could not be read, the test stops"; exit 1; }
    cat >> "$TMP/spike.rules" <<RULES
# The traffic of this machine itself must not be redirected.
no rdr pass on $IFACE proto tcp from $LAN_IP to any
# The traffic that comes in from the network is redirected to the program.
rdr pass on $IFACE proto tcp from $SUBNET to any -> 127.0.0.1 port $REDIRECT_PORT
RULES
    cat > "$TMP/nat.rules" <<RULES
nat on $IFACE from $SUBNET to any -> ($IFACE)
RULES
fi

{
    echo "# the rules of the machine, with the anchor of this test added"
    echo "# the redirect rules are only looked at in the redirect chain, and the"
    echo "# address rules only in the address chain, so both get their own anchor"
    echo "rdr-anchor \"$ANCHOR/rdr\""
    echo "load anchor \"$ANCHOR/rdr\" from \"$TMP/spike.rules\""
    if [ "$FORWARD" = "1" ]; then
        echo "nat-anchor \"$ANCHOR/nat\""
        echo "load anchor \"$ANCHOR/nat\" from \"$TMP/nat.rules\""
    fi
} >> "$TMP/main.rules"

step "putting the rules in place"
pfctl -f "$TMP/main.rules" 2>&1 | sed 's/^/   /'
pfctl -E 2>&1 | sed 's/^/   /'
if [ "$FORWARD" = "1" ]; then
    echo "the forwarding of the other terminals goes on"
    sysctl -w net.inet.ip.forwarding=1 2>&1 | sed 's/^/   /'
fi
say "the rules that are in place now:"
pfctl -a "$ANCHOR/rdr" -sr 2>&1 | sed 's/^/   /'
pfctl -a "$ANCHOR/nat" -sr 2>&1 | sed 's/^/   /'

# ---------------------------------------------------------------- the test

step "starting the test place and the program that takes the redirected traffic"
python3 -m http.server "$TARGET_PORT" --bind 127.0.0.1 > "$TMP/target.log" 2>&1 &
TARGET_PID=$!
"$TMP/gateway-natlook" "$REDIRECT_PORT" 127.0.0.1 "$TARGET_PORT" "$SRC_PORT" > "$TMP/helper.log" 2>&1 &
HELPER_PID=$!
sleep 2
say "   the test place is on 127.0.0.1:$TARGET_PORT, the program listens on 127.0.0.1:$REDIRECT_PORT"

if [ "$FORWARD" = "1" ]; then
    step "the machine is a router now: wait for a client of the network"
    say "   on another machine of $SUBNET:"
    say "      set the gateway to $LAN_IP"
    say "      then open any page and come back here"
    say "   (the filter is put back when this script ends)"
    echo
    printf "   press enter when you are done: "
    read -r _ignored
else
    step "a connection goes to the test place"
    curl -s --max-time 15 "http://127.0.0.1:$TARGET_PORT/" -o "$TMP/client.out" 2>"$TMP/client.err"
    say "   the client got $(wc -c < "$TMP/client.out" | tr -d ' ') bytes"
fi

sleep 1
step "what the kernel said"
say "the program wrote:"
sed 's/^/   /' "$TMP/helper.log"
say
say "the states of the filter (this is the official view of where the traffic was going):"
pfctl -ss 2>&1 | head -20 | sed 's/^/   /'

# ---------------------------------------------------------------- the verdict

step "the verdict"
NATLOOK_LINE="$(grep -m1 '^NATLOOK ' "$TMP/helper.log" 2>/dev/null || true)"
if [ -z "$NATLOOK_LINE" ]; then
    say "   FAIL: the kernel did not say where the connection was going."
    say "        The redirect itself worked (the connection came through), but"
    say "        the original destination could not be read."
    say "        The way out then is to read the states of the filter instead,"
    say "        which the helper can do as root: it is slower, but it works."
else
    say "   the kernel answered: $NATLOOK_LINE"
    ADDR="$(echo "$NATLOOK_LINE" | sed -n 's/.*addr=\([0-9.]*\).*/\1/p')"
    PORT_HOST="$(echo "$NATLOOK_LINE" | sed -n 's/.*port_host=\([0-9]*\).*/\1/p')"
    PORT_NET="$(echo "$NATLOOK_LINE" | sed -n 's/.*port_net=\([0-9]*\).*/\1/p')"
    if [ "$ADDR" = "127.0.0.1" ] && { [ "$PORT_HOST" = "$TARGET_PORT" ] || [ "$PORT_NET" = "$TARGET_PORT" ]; }; then
        say "   PASS: the original destination came back right."
        say "         The program can take the traffic of the other terminals and"
        say "         send it on by the rule that says where it was going."
    else
        say "   HALF: the kernel answered, but not with the place we asked for."
        say "         we asked for 127.0.0.1:$TARGET_PORT, it said ${ADDR:-?}:${PORT_HOST:-?}"
        say "         (the ports are printed in both readings, because the byte"
        say "         order of the ports is a convention the program cannot know)"
    fi
fi

echo
say "the files of this test were in $TMP and are gone now"
exit 0

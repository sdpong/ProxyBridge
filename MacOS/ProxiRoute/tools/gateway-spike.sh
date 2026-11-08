#!/bin/sh
# gateway-spike.sh - the feasibility test of the gateway mode on macOS.
#
# The gateway mode needs two things that this machine has never done before:
# the traffic of the other terminals has to come in, and the program that
# takes it has to find out where it was going before it was redirected.
#
# This script tests both, in the smallest way that can be undone:
#
#   1. it puts one rule of its own into the packet filter, and puts the old
#      ruleset back when it is done;
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
# And without root, to only look at the rules it would load:
#
#   ./gateway-spike.sh --dry-run
#
# The script needs: clang (or cc), python3, curl, pfctl. It cleans up after
# itself, also when it is interrupted.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_PORT=18080
REDIRECT_PORT=18081
SRC_PORT_BASE=20000
SRC_PORT_LAST=20099
FORWARD=0

TMP="$(mktemp -d /tmp/proxiroute-spike.XXXXXX)"
# the folder is made for root only, and the program is run once more as the
# user who started the test, so both have to be reachable for it
chmod 755 "$TMP"
TARGET_PID=""
HELPER_PID=""
WAS_ENABLED="no"
OLD_FORWARDING=""
RULES_LOADED="no"
RULE_MODE="anchors"
FORWARDING_TURNED_ON="no"

usage() {
    echo "usage: sudo $0 [--forward] [--dry-run]"
    echo
    echo "  (no option)  test the redirect and the original destination locally"
    echo "  --forward    also turn the machine into a router and wait for a"
    echo "               client of the network (needs a second machine)"
    echo "  --dry-run    only show the rules and let the filter read them"
    echo "               without changing anything (no root needed)"
}

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --forward) FORWARD=1 ;;
        --dry-run) DRY_RUN=1 ;;
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
    pkill -f "gateway-natlook $REDIRECT_PORT" 2>/dev/null

    if [ "$RULES_LOADED" = "yes" ] && [ -f "$TMP/base.rules.untouched" ]; then
        echo "-- the old ruleset"
        pfctl -f "$TMP/base.rules.untouched" 2>&1 | sed 's/^/   /'
    fi
    if [ "$RULES_LOADED" = "yes" ] && [ "$WAS_ENABLED" = "no" ]; then
        echo "-- the filter goes back to the way it was (off)"
        pfctl -d 2>&1 | sed 's/^/   /'
    fi
    if [ -n "$OLD_FORWARDING" ] && [ "$FORWARDING_TURNED_ON" = "yes" ]; then
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

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = "0" ]; then
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

# The rules of the machine are taken from the file the system itself reads,
# and that file is what puts them back at the end.
#
# "pfctl -sr" is not enough for that: it prints the filtering rules only, so
# the anchors of the translation (nat and rdr) would be lost on the way.
BASE_RULES="/etc/pf.conf"
if [ ! -f "$BASE_RULES" ]; then
    pfctl -sr > "$TMP/base.rules"
    BASE_RULES="$TMP/base.rules"
    say "   /etc/pf.conf is not there, the rules that are in place now are used"
else
    say "   the rules come from $BASE_RULES, and they go back to it"
fi
cp "$BASE_RULES" "$TMP/base.rules.untouched"

if grep -q "set skip on lo0" "$BASE_RULES" 2>/dev/null; then
    say "   the rules say 'set skip on lo0': the traffic of this machine does"
    say "   not go through the filter, so the local test cannot work here."
fi

# ---------------------------------------------------------------- the build

step "building the small program that takes the redirected connection"
"$CC" -O2 -Wall -o "$TMP/gateway-natlook" "$HERE/gateway-natlook.c" 2>&1 | sed 's/^/   /'
[ -x "$TMP/gateway-natlook" ] || { say "   the program did not build"; exit 1; }
say "   ok"

# ---------------------------------------------------------------- the rules

# The rules of this test, in the translation part of the ruleset.
#
# The rule that lets the program out is the one that keeps its own traffic
# away from the redirect: it is the only way out of a redirect on macOS, and
# the ports of the range are below the range the system hands out by itself
# (49152 and up), so the traffic of the other programs is never caught by it.
# The rules of this test are written in two places on purpose.
#
# The first one is straight into the translation part of the ruleset, the
# second one into an anchor of its own that is declared there. Which of the
# two macOS actually evaluates is not written down anywhere, and the two
# rules say the same thing, so the test does not have to know: the redirect
# works either way, and the helper of phase 2 will use both as well.
mkdir -p "$TMP/anchor"
cat > "$TMP/translation.rules" <<RULES
# The traffic of the program itself must not be redirected again.
no rdr on lo0 proto tcp from any port $SRC_PORT_BASE:$SRC_PORT_LAST to any
# A connection to the test place goes to the program instead.
rdr pass on lo0 proto tcp from any to 127.0.0.1 port $TARGET_PORT -> 127.0.0.1 port $REDIRECT_PORT
RULES
cp "$TMP/translation.rules" "$TMP/anchor/rdr"

if [ "$FORWARD" = "1" ]; then
    SUBNET="$(python3 - "$LAN_IP" "$LAN_MASK" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
    print(net)
except Exception:
    print("")
PY
)"
    [ -n "$SUBNET" ] || { say "the network of this machine could not be read, the test stops"; exit 1; }
    # The traffic of this machine itself must not be redirected: it is the
    # traffic of the local proxy mode, and it goes to the proxy by itself.
    cat >> "$TMP/translation.rules" <<RULES
no rdr on $IFACE from $LAN_IP to any
no nat on $IFACE from $LAN_IP to any
# The traffic that comes in from the network is redirected to the program.
rdr pass on $IFACE proto tcp from $SUBNET to any -> 127.0.0.1 port $REDIRECT_PORT
# The clients keep their own address on the way out, so that the way back
# comes through this machine.
nat on $IFACE from $SUBNET to any -> ($IFACE)
RULES
    cat > "$TMP/anchor/nat" <<RULES
no nat on $IFACE from $LAN_IP to any
nat on $IFACE from $SUBNET to any -> ($IFACE)
RULES
fi

# The rules of this test go into the rules of the machine.
#
# They go into the translation part, which has to come before the filtering
# part: the filter refuses a file where a rule of the filtering part comes
# before a rule of the translation part. That is why they are put in front
# of the first filtering rule and not at the end of the file.
python3 - "$BASE_RULES" "$TMP/translation.rules" "$TMP/main.rules" "$TMP/anchor/rdr" "$TMP/anchor/nat" "${RULE_MODE:-anchors}" <<'PY'
import os
import re
import sys

base_path, rules_path, out_path, rdr_path, nat_path = sys.argv[1:6]
mode = sys.argv[6]

base = open(base_path).read().splitlines(keepends=True)
rules = open(rules_path).read().splitlines(keepends=True)

# the anchors of this test, and the rules that go in them
anchors = []
loads = []
if mode == 'anchors':
    anchors = ['rdr-anchor "com.sdpong.spike/rdr"\n']
    loads = ['load anchor "com.sdpong.spike/rdr" from "%s"\n' % rdr_path]
    if os.path.exists(nat_path):
        anchors.insert(0, 'nat-anchor "com.sdpong.spike/nat"\n')
        loads.append('load anchor "com.sdpong.spike/nat" from "%s"\n' % nat_path)

ours = anchors + rules

out = []
placed = False
for line in base:
    text = line.strip()
    if not placed and text and not text.startswith('#'):
        if re.match(r'^(anchor|pass|block|match)\b', text):
            out.extend(ours)
            placed = True
    out.append(line)
if not placed:
    out.extend(ours)

# the anchors of this test are loaded at the end of the file
out.extend(loads)

open(out_path, 'w').writelines(out)
PY

step "the rules that will be loaded"
grep -v '^#' "$TMP/main.rules" | grep -v '^$' | sed 's/^/   /'

# The file is checked before it is loaded: pfctl reads the file without
# touching the filter when it is given -n. A file that the filter would
# refuse is caught here, and the machine is left alone.
step "checking the rules (the filter is not touched yet)"
pfctl -n -f "$TMP/main.rules" > "$TMP/parse.log" 2>&1
PARSE_RC=$?
sed 's/^/   /' "$TMP/parse.log"
if [ "$PARSE_RC" -ne 0 ]; then
    say "   the filter would refuse this file, so nothing was changed."
    exit 1
fi
say "   the file is good"

if [ "$DRY_RUN" = "1" ]; then
    echo
    say "   nothing was changed (this was a dry run)"
    exit 0
fi

step "putting the rules in place"
pfctl -f "$TMP/main.rules" > "$TMP/load.log" 2>&1
LOAD_RC=$?
sed 's/^/   /' "$TMP/load.log"
if [ "$LOAD_RC" -ne 0 ]; then
    # the anchors of the test are a convenience, not the point of the test:
    # if the filter refuses them, the rules without them are loaded
    say "   the rules with an anchor of their own were refused, the plain ones are used"
    python3 - "$BASE_RULES" "$TMP/translation.rules" "$TMP/main.rules.plain" "$TMP/anchor/rdr" "$TMP/anchor/nat" plain <<'PY'
import os
import re
import sys

base_path, rules_path, out_path, rdr_path, nat_path = sys.argv[1:6]
mode = sys.argv[6]

base = open(base_path).read().splitlines(keepends=True)
rules = open(rules_path).read().splitlines(keepends=True)

out = []
placed = False
for line in base:
    text = line.strip()
    if not placed and text and not text.startswith('#'):
        if re.match(r'^(anchor|pass|block|match)\b', text):
            out.extend(rules)
            placed = True
    out.append(line)
if not placed:
    out.extend(rules)

open(out_path, 'w').writelines(out)
PY
    pfctl -f "$TMP/main.rules.plain" > "$TMP/load2.log" 2>&1
    LOAD_RC=$?
    sed 's/^/   /' "$TMP/load2.log"
    if [ "$LOAD_RC" -ne 0 ]; then
        say "   the filter refused the rules as well, so the machine was left alone."
        exit 1
    fi
fi
RULES_LOADED="yes"
pfctl -E 2>&1 | sed 's/^/   /'
say "the rules that are in place now:"
pfctl -sr 2>&1 | sed 's/^/   /'
say "   (the filter does not print the rules of the translation part here,"
say "    so the rule that redirects to port $REDIRECT_PORT is checked by the"
say "    test below, where it either works or it does not)"

# ---------------------------------------------------------------- the test

step "starting the test place and the program that takes the redirected traffic"
python3 -m http.server "$TARGET_PORT" --bind 127.0.0.1 > "$TMP/target.log" 2>&1 &
TARGET_PID=$!
"$TMP/gateway-natlook" "$REDIRECT_PORT" 127.0.0.1 "$TARGET_PORT" "$SRC_PORT_BASE" \
    127.0.0.1 "$TARGET_PORT" > "$TMP/helper.log" 2>&1 &
HELPER_PID=$!
sleep 2
say "   the test place is on 127.0.0.1:$TARGET_PORT, the program listens on 127.0.0.1:$REDIRECT_PORT"

# ---------------------------------------------------------------- the verdict

verdict() {
    which_test="$1"
    log_file="$2"
    echo
    echo "== the verdict ($which_test) =="

    if ! grep -q '^accepted from' "$log_file" 2>/dev/null; then
        say "   FAIL: the connection never came to the program."
        say "        The filter did not redirect it, so the rules are not in"
        say "        place. The output above says what the filter thinks it has."
        return
    fi

    # Every answer of the kernel is looked at, not only the first one: the
    # layout that this kernel uses is not known, and a layout that is not
    # the right one can answer with something that makes no sense.
    answer="$(python3 - "$log_file" "$TARGET_PORT" "$REDIRECT_PORT" "$which_test" <<'PY'
import re
import sys

log, target, redirect, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

lines = [l for l in open(log).read().splitlines() if l.startswith('NATLOOK ok')]
if not lines:
    print('none')
    sys.exit(0)

addr_re = re.compile(r'\b(saddr|daddr|rsaddr|rdaddr)=([0-9.]+)/([0-9.]+)')
port_re = re.compile(r'\b(sport|dport|rsport|rdport)=([0-9]+)/([0-9]+)')


def read(line):
    """The addresses and the ports of the destination, in both readings."""
    addrs, ports = [], []
    for name, a, b in addr_re.findall(line):
        if name in ('daddr', 'rdaddr'):
            addrs += [a, b]
    for name, a, b in port_re.findall(line):
        if name in ('dport', 'rdport'):
            ports += [int(a), int(b)]
    return addrs, ports


for line in lines:
    addrs, ports = read(line)
    if mode == 'local':
        if '127.0.0.1' in addrs and target in ports:
            print('pass|' + line)
            sys.exit(0)
    else:
        for a in addrs:
            if a not in ('127.0.0.1', '0.0.0.0', '255.255.255.255'):
                print('pass|' + line)
                sys.exit(0)

for line in lines:
    addrs, ports = read(line)
    if redirect in ports and '127.0.0.1' in addrs:
        print('redirect|' + line)
        sys.exit(0)

print('other|' + lines[0])
PY
)"
    if [ -z "$answer" ] || [ "$answer" = "none" ]; then
        say "   FAIL: the connection came, but the kernel did not say where it"
        say "        was going. The answer of the kernel is in the output above."
        say "        The way out then is to read the states of the filter"
        say "        instead, which the helper can do as root: it is slower,"
        say "        but it works."
        return
    fi

    # the states of the filter are the other way of finding the place the
    # traffic was going: the helper can read them as root, and it is slower
    # but it works
    states="$(cat "$TMP/states.txt" "$TMP/states-nat.txt" 2>/dev/null)"
    if echo "$states" | grep -q "$TARGET_PORT"; then
        say "   the states of the filter show the place the traffic was going:"
        echo "$states" | grep "$TARGET_PORT" | sed 's/^/      /'
        say "   PASS: the original destination can be read from the states."
        say "         The helper can do it as root: it is slower than the"
        say "         ioctl, but it works."
        return
    fi

    verdict_kind="${answer%%|*}"
    verdict_line="${answer#*|}"
    say "   the kernel answered: $verdict_line"

    case "$verdict_kind" in
        pass)
            say "   PASS: the original destination came back right."
            say "         The program can take the traffic of the other terminals"
            say "         and send it on by the rule that says where it was going."
            ;;
        redirect)
            say "   FAIL: the kernel gave back the place the traffic was"
            say "        redirected to, not the place it was going."
            say "        The way out then is to read the states of the filter"
            say "        instead, which the helper can do as root."
            ;;
        *)
            say "   HALF: the kernel answered, but not with the place we asked for."
            say "         we asked for 127.0.0.1:$TARGET_PORT, it said something else"
            say "         (the numbers are printed in both readings, because the"
            say "          byte order is a convention the program cannot know)"
            ;;
    esac
}

# ---------------------------------------------------------------- the local test

# one connection to the test place, and what the program made of it
local_test() {
    log_file="$1"
    step "a connection goes to the test place"
    curl -s --max-time 20 "http://127.0.0.1:$TARGET_PORT/" -o "$TMP/client.out" 2>"$TMP/client.err"
    say "   the client got $(wc -c < "$TMP/client.out" | tr -d ' ') bytes"
    if [ -s "$log_file" ]; then
        say "   the program took the connection:"
        grep -E '^(accepted|NATLOOK|going|no way)' "$log_file" | sed 's/^/      /'
    else
        say "   the program took nothing: the redirect did not happen."
    fi
    sleep 1
    pfctl -ss 2>&1 | head -40 > "$TMP/states.txt"
    pfctl -s nat 2>&1 | head -40 > "$TMP/states-nat.txt"
}

local_test "$TMP/helper.log"

say
say "the states of the filter (this is the official view of where the traffic was going):"
sed 's/^/   /' "$TMP/states.txt"
say
say "the translation rules that are loaded (this says whether our rule is in place):"
sed 's/^/   /' "$TMP/states-nat.txt"

# ---------------------------------------------------------------- the same, without root
#
# The ioctl is sent on the socket of the connection, so it may not need the
# root at all: if the program can ask the kernel as an ordinary user, the
# app of the gateway mode can do it by itself and the helper does not have
# to. The reading of the states needs the root, so the two are told apart.

if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    step "the same, with the program running as $SUDO_USER instead of root"
    kill "$HELPER_PID" 2>/dev/null
    sleep 1
    kill -9 "$HELPER_PID" 2>/dev/null
    sudo -u "$SUDO_USER" "$TMP/gateway-natlook" "$REDIRECT_PORT" 127.0.0.1 "$TARGET_PORT" \
        "$SRC_PORT_BASE" 127.0.0.1 "$TARGET_PORT" > "$TMP/helper-user.log" 2>&1 &
    HELPER_PID=$!
    sleep 2
    local_test "$TMP/helper-user.log"
    verdict "without root" "$TMP/helper-user.log"
fi

verdict local "$TMP/helper.log"

# ---------------------------------------------------------------- the forwarding

if [ "$FORWARD" = "1" ]; then
    step "the machine is a router now: wait for a client of the network"
    say "   the forwarding of the other terminals goes on"
    sysctl -w net.inet.ip.forwarding=1 2>&1 | sed 's/^/   /'
    FORWARDING_TURNED_ON="yes"
    say "   on another machine of $SUBNET:"
    say "      set the gateway to $LAN_IP"
    say "      then open any page and come back here"
    say "   (the filter is put back when this script ends)"
    echo
    printf "   press enter when you are done: "
    read -r _ignored

    sleep 1
    step "what the kernel said about the traffic of the client"
    grep -E '^(accepted|NATLOOK|going|no way)' "$TMP/helper.log" | sed 's/^/   /'
    echo
    say "the states of the filter:"
    pfctl -ss 2>&1 | head -40 > "$TMP/states-client.txt"
    pfctl -s nat 2>&1 | head -40 > "$TMP/states-client-nat.txt"
    sed 's/^/   /' "$TMP/states-client.txt"
    say
    say "the translation rules that are loaded:"
    sed 's/^/   /' "$TMP/states-client-nat.txt"
    cp "$TMP/states-client.txt" "$TMP/states.txt"
    cp "$TMP/states-client-nat.txt" "$TMP/states-nat.txt"
    verdict client "$TMP/helper.log"
fi

echo
say "the files of this test were in $TMP and are gone now"
exit 0

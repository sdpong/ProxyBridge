# tools

Tools that are used while developing, not part of the app and **not part of the
installer package** (`build.sh` puts the whole `scripts/` folder into the pkg,
so anything that is not a package script belongs here).

## gateway-spike.sh

The feasibility test of the gateway mode on macOS.

The gateway mode needs two things this machine has never done before: the
traffic of the other terminals has to come in, and the program that takes it
has to find out where it was going before it was redirected. This tests both
in the smallest way that can be undone — it puts one rule of its own into the
packet filter, sends a connection to a place, lets the filter redirect it,
asks the kernel where that connection was going, and puts the machine back
the way it was.

```bash
./gateway-spike.sh --dry-run          # only show the rules (no root needed)
sudo ./gateway-spike.sh                # locally: redirect + original destination
sudo ./gateway-spike.sh --forward      # and the machine becomes a router
```

What it does, in order:

1. reads the rules of the filter from `/etc/pf.conf` (the file the system
   itself reads, because `pfctl -sr` prints the filtering rules only and the
   anchors of the translation would be lost on the way) and saves them;
2. builds `gateway-natlook.c` and starts it on `127.0.0.1:18081`;
3. starts a test place on `127.0.0.1:18080`;
4. puts its own rules into the **translation part** of the ruleset — the
   filter refuses a file where a rule of the filtering part comes before a
   rule of the translation part, so they go in front of the first `anchor`
   line and not at the end of the file;
5. lets the filter read the file first with `pfctl -n -f` (that only parses,
   it does not touch the filter), and stops there when the filter would
   refuse the file, so a broken file never reaches the machine;
6. loads the file, sends a connection to the test place — the filter
   redirects it to the program, which asks the kernel for the original
   destination and relays the bytes;
7. prints the verdict (`PASS` / `HALF` / `FAIL`) and puts everything back,
   also when it is interrupted.

The rule that keeps the program itself out of the redirect uses a range of
source ports below 49152, because that is where the system starts handing
out ports by itself: the traffic of the other programs must never fall into
that range.

It needs `sudo` (the filter and the forwarding are for root), and it needs
`clang` (or `cc`), `python3`, `curl` and `pfctl`.

The plan it belongs to is in [docs/GATEWAY.md](../../../docs/GATEWAY.md).

## gateway-natlook.c

The little end of the test: it takes a connection that the filter redirected,
asks the kernel where it was going before, connects there and relays the
bytes.

macOS does not ship `<net/pfvar.h>`, so the layouts of the struct that are in
the field are declared here — three of them: with a file descriptor, without
one, and the newer one with a field for the reply. All of them are tried, in
every combination of which end of the socket is given first, which number
goes into the protocol field, and which direction.

Two things that the first run of this test taught us:

- the kernel does **not** always refuse a layout that is not its own with
  `ENOTTY`. Without a state to find, it answers `ENXIO` for every layout, so
  the layout cannot be told apart by the error alone. The answer is therefore
  printed in every reading — the addresses in both byte orders, the ports in
  both byte orders — and the verdict looks at **all** the answers of the
  kernel and not at the first one;
- the struct that the kernel writes back is of its own size, so every probe
  goes into one buffer that is big enough for all of them.

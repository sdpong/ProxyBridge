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
sudo ./gateway-spike.sh              # locally: redirect + original destination
sudo ./gateway-spike.sh --forward    # and the machine becomes a router
```

What it does, in order:

1. saves the rules of the filter and the state of the forwarding;
2. builds `gateway-natlook.c` and starts it on `127.0.0.1:18081`;
3. starts a test place on `127.0.0.1:18080`;
4. puts one rule into an anchor of its own (`com.sdpong.spike`), never into
   the rules of the system or of anybody else;
5. sends a connection to the test place — the filter redirects it to the
   program, which asks the kernel for the original destination and relays
   the bytes;
6. prints the verdict (`PASS` / `HALF` / `FAIL`) and puts everything back,
   also when it is interrupted.

It needs `sudo` (the filter and the forwarding are for root), and it needs
`clang` (or `cc`), `python3`, `curl` and `pfctl`.

The plan it belongs to is in [docs/GATEWAY.md](../../../docs/GATEWAY.md).

## gateway-natlook.c

The little end of the test: it takes a connection that the filter redirected,
asks the kernel where it was going before, connects there and relays the
bytes.

macOS does not ship `<net/pfvar.h>`, so the two layouts of the struct that are
in the field are declared here, and both are tried. The size of the struct
goes into the number of the ioctl, so a layout that is not the one of this
kernel is refused with `ENOTTY` instead of being read wrong. The answer is
printed in every reading, because the byte order of the ports is a
convention this program cannot know either.

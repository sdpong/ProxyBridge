import Foundation

// The helper of the gateway mode.
//
// It is started by the system, as root, and it waits on a unix socket for
// the app to ask it things.
//
// The build is a command line tool of its own, and it is built by the
// scripts of the package (scripts/build-helper.sh), not by the Xcode
// project: the helper is a program of root and it has nothing to do with
// the window of the app.
//
// The C file of the ioctl is linked into it, because the ioctl needs a
// pointer and Swift cannot give one to Darwin's ioctl.

let helper = GatewayHelper()
let status = helper.run()
exit(status)

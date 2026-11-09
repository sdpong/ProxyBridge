import Foundation

// The socket the app talks to the helper over.
//
// The helper is a program of root and the app is a program of a person, so
// the helper has to be able to tell whether it is talking to the person it
// is meant to talk to. That is a weak check, and it is weak on purpose: an
// ad-hoc signature has no team id and its hash changes with every build, so
// the helper cannot check the identity of the app the way a program signed
// by a developer can.
//
// What it does instead: the socket is made by root, in a folder of root, and
// the helper asks the system who is on the other end of the socket and
// compares it with the person who is sitting in front of the machine. The
// person who logged in on the console is the one who may talk to it.
//
// The check is a check of the person, not of the program. Every program that
// the person runs can talk to the helper. That is what is traded away for
// the ability to build this without a developer certificate, and it is
// written down here so that it is not forgotten.

enum GatewaySocket {

    // Who is allowed to talk to the helper.
    //
    // The answer comes from the system: the owner of /dev/console is the
    // person who is sitting in front of the machine. When nobody is sitting
    // in front of it - a machine that is only a server - the owner is root,
    // and then only root may talk to the helper.
    static func consoleUserID() -> uid_t {
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return 0 }
        return info.st_uid
    }

    // Whether this person may talk to the helper.
    static func isAllowed(uid: uid_t) -> Bool {
        // root always may: the person who installed the helper may want to
        // talk to it from a terminal
        if uid == 0 { return true }
        return uid == consoleUserID()
    }
}

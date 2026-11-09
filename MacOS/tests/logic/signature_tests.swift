import Foundation

// The tests of the signature of the app.
//
// The app installs a *system extension*. macOS refuses to install one unless
// the containing app carries the entitlement
// com.apple.developer.system-extension.install, and it refuses the whole
// bundle when the signature does not cover everything that is inside it.
//
// That makes a broken signature invisible until the user tries to proxy
// something: the app starts, the window opens, and only then does the system
// say "Missing entitlement com.apple.developer.system-extension.install".
// The person finds out on their own machine, after the download.
//
// The signature breaks quietly. Anything that writes into the bundle after it
// was signed - a rebuild by xcodebuild, a helper that is put in later - leaves
// the old signature behind. The bundle then still looks signed
// (codesign -dv still prints a signature) while the entitlement is gone and
// the nested extension is not signed at all.
//
// So there has to be a check that fails loudly, and it has to be run where a
// broken build can still be fixed: at the end of the packaging, and in the CI
// before the artifacts are published. These tests read the text of the scripts
// to make sure that check stays wired up.

func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what)")
        exit(1)
    }
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  FAIL cannot read \(path)")
        exit(1)
    }
    return text
}

let scripts = ProcessInfo.processInfo.environment["PROXIRoute_SCRIPTS"] ?? ""
let root = (scripts as NSString).deletingLastPathComponent

print("app signature tests:")

// ---------------------------------------------------------------- the script exists

let verifyScript = (scripts as NSString).appendingPathComponent("verify-app-signature.sh")
check(FileManager.default.fileExists(atPath: verifyScript),
      "there is a script that checks the signature of the app")

let verify = read(verifyScript)

// it checks the four things that decide whether the extension can be installed
check(verify.contains("com.apple.developer.system-extension.install"),
      "the check looks for the entitlement the system extension needs")
check(verify.contains("com.apple.developer.networking.networkextension"),
      "the check looks for the entitlement of the system extension itself")
check(verify.contains("codesign --verify"),
      "the check verifies the signature of the bundle")
check(verify.contains("com.sdpong.proxiroute.extension.systemextension"),
      "the check looks at the system extension inside the bundle")
check(verify.contains("com.sdpong.proxiroute.helper"),
      "the check looks at the helper of the gateway mode inside the bundle")

// it has to fail, not just print. A check that only prints is a check that
// nobody notices.
check(verify.contains("exit 1"),
      "the check fails the build when something is missing")

// ---------------------------------------------------------------- the packaging runs it

let buildScript = read((root as NSString).appendingPathComponent("build.sh"))
check(buildScript.contains("verify-app-signature.sh"),
      "the packaging runs the signature check before it builds the package")

// ---------------------------------------------------------------- the CI runs it

// The CI is what publishes the artifacts, so the check has to be there too:
// a build that would ship an app that cannot install its extension has to fail
// the job, not reach the release.
let workflow = read((root as NSString)
    .appendingPathComponent("../../.github/workflows/build-mac.yml"))
check(workflow.contains("verify-app-signature.sh"),
      "the CI runs the signature check before it publishes the artifacts")
check(workflow.contains("Verify the signature of the app"),
      "the CI has a step for the signature check")

// the check has to run on the zip as well: the zip is what people download
// and unzip, so the app inside the zip is the one that has to work
check(workflow.contains("ditto -x -k"),
      "the CI checks the app after it unzips the published zip")

// ---------------------------------------------------------------- the order

// The CI builds, then signs, then checks. A check that runs before the
// signing would only ever see the broken bundle.
let buildAt = workflow.range(of: "Build Universal Binary")
let embedAt = workflow.range(of: "Put the helper of the gateway mode into the app")
let verifyAt = workflow.range(of: "Verify the signature of the app")
let packageAt = workflow.range(of: "Package App Bundle")

check(buildAt != nil && embedAt != nil && verifyAt != nil && packageAt != nil,
      "the CI has the build, the signing, the check and the packaging")
if let b = buildAt, let e = embedAt, let v = verifyAt, let p = packageAt {
    check(b.lowerBound < e.lowerBound, "the CI builds before it signs")
    check(e.lowerBound < v.lowerBound, "the CI signs before it checks")
    check(v.lowerBound < p.lowerBound, "the CI checks before it packages")
}

// ---------------------------------------------------------------- the signing script

// The ad-hoc signing is what puts the entitlement into the bundle of a build
// that has no certificate, so it has to keep doing that.
let adhoc = read((scripts as NSString).appendingPathComponent("adhoc-sign.sh"))
check(adhoc.contains("com.apple.developer.system-extension.install"),
      "the ad-hoc signing puts the entitlement into the bundle")
check(adhoc.contains("--force"),
      "the ad-hoc signing can sign a bundle again when it changed")

// The helper travels inside the bundle, so the helper has to be signed too,
// or the bundle is not a bundle the system runs.
check(adhoc.contains("Contents/Helpers"),
      "the ad-hoc signing signs the helper of the gateway mode")

print("app signature tests: ok")

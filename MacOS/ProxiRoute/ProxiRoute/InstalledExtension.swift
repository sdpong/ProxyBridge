import Foundation
import SystemExtensions

// Whether the system extension of this app is already in the system.
//
// The problem this exists for:
//
//   macOS keeps every registered version of a system extension under the same
//   bundle id, and every registration is a separate record in the database of
//   the system. Asking for the extension again - which the app did on every
//   start - does not update the record that is already there: it makes a new
//   one, under a new folder in /Library/SystemExtensions, and the old one is
//   marked "terminated waiting to uninstall on reboot". The records pile up,
//   and the network configuration of the app - which carries the signature of
//   the extension of the day it was written - can end up bound to a record
//   that is on its way out. macOS then says "the VPN app used by this
//   configuration is not installed" and nothing is proxied, while the window
//   shows no reason for it.
//
//   Asking is not free even when the extension is there: with the developer
//   mode of the system turned on, macOS asks the app whether the extension
//   that is already installed may be replaced, on every request. The app
//   says yes, the system installs a new copy, and the old one goes on its
//   way out. Every start of the app made one more.
//
//   So the app looks before it asks. The answer comes from macOS itself: the
//   request that asks for the properties of the extensions that are installed
//   does not change anything, and it is answered even by a build that is
//   signed ad hoc.
//
// The properties are asked for with a request of its own kind, and the answer
// comes back through the delegate of that request.
enum InstalledExtension {

    // the bundle id of the extension of this app
    static var bundleIdentifier: String { "com.sdpong.proxiroute.extension" }

    // What the system has for this bundle id.
    struct Information {
        // the extension of this build is in the system and it is in use
        var isCurrent: Bool = false
        // an older record of the same bundle id is on its way out
        var hasStaleRecord: Bool = false
        // how many records of this bundle id the system has
        var recordCount: Int = 0

        // Whether the app has to ask the system for the extension.
        //
        // It has to when the extension is not there. It does not have to when
        // it is: asking again makes a second record, and the first one goes
        // on its way out.
        //
        // A stale record on its own is not a reason to ask either: the record
        // that is in use is the one that matters, and the stale one goes at
        // the next restart of the machine either way.
        //
        // This is the answer for the state of the system as it is. It is not
        // the whole decision: the records that are on their way out are taken
        // out of the system, and that takes the record that is in use with
        // them - the tool of the system cannot take out one record of a
        // bundle id, only all of them. So the caller asks for the extension
        // again after it has cleaned up.
        var needsActivationRequest: Bool { !isCurrent }
    }

    // Whether the app has to ask the system for the extension, given what the
    // system has and what was done about it.
    //
    // The cleanup is what makes the second rule: taking the records out of
    // the system takes the record that is in use with them, so after a
    // cleanup the extension is not there any more and it has to be asked
    // for again - whatever the state was before the cleanup.
    static func needsActivationRequest(isCurrent: Bool, hasStaleRecord: Bool, didCleanUp: Bool) -> Bool {
        if didCleanUp { return true }
        return !isCurrent
    }

    // The information, asked for once and kept.
    //
    // It is asked for when the app starts, and the answer is used from then
    // on: the state of the system does not change while the app runs.
    private static var cached: Information?

    // Asks macOS what it has for this bundle id.
    //
    // The completion is called on the main queue.
    static func query(completion: @escaping (Information) -> Void) {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: bundleIdentifier,
            queue: .main
        )
        request.delegate = Delegate.shared
        Delegate.shared.completion = { information in
            cached = information
            completion(information)
        }
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // The information, without asking again.
    //
    // It is empty when nothing was asked yet: the app then asks, as it
    // always did.
    static var known: Information { cached ?? Information() }

    // Whether the records that are on their way out are a problem.
    //
    // They are: the network configuration of the app can be bound to one of
    // them, and then macOS says "the VPN app used by this configuration is
    // not installed" and nothing is proxied.
    //
    // They cannot be told apart from the record that is in use by their
    // state: the one that is in use is enabled, and the ones on their way
    // out are not.
    static var hasStaleRecords: Bool { known.hasStaleRecord }

    // The information of the app, built out of what macOS says.
    //
    // The properties of macOS are read-only, so they cannot be made up in a
    // test. The answer is turned into the answer of the app here, and this
    // part - the judgement about a record - is what is checked.
    static func information(from properties: [OSSystemExtensionProperties]) -> Information {
        var information = Information()
        information.recordCount = properties.count
        for property in properties {
            guard property.bundleIdentifier == bundleIdentifier else { continue }
            if isInUse(property) {
                information.isCurrent = true
            } else {
                information.hasStaleRecord = true
            }        }
        return information
    }

    // The judgement about a record of macOS.
    //
    // A record that is in use is enabled, that is not waiting for the
    // approval of the person and that is not on its way out.
    //
    // It is written the way it is - three flags - and not as the object of
    // macOS, because that object cannot be made up in a test: its values are
    // read-only and there is no way to build one.
    static func isInUse(enabled: Bool, awaitingApproval: Bool, uninstalling: Bool) -> Bool {
        return enabled && !awaitingApproval && !uninstalling
    }

    // The same judgement, about the object of macOS.
    static func isInUse(_ property: OSSystemExtensionProperties) -> Bool {
        return isInUse(enabled: property.isEnabled,
                       awaitingApproval: property.isAwaitingUserApproval,
                       uninstalling: property.isUninstalling)
    }

    // The delegate of the request that asks for the properties.
    private final class Delegate: NSObject, OSSystemExtensionRequestDelegate {
        static let shared = Delegate()
        var completion: ((Information) -> Void)?

        // The properties of the extensions that are installed.
        //
        // The request that asks for the properties does not change anything,
        // so this is the answer to "what is there".
        func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
            completion?(InstalledExtension.information(from: properties))
            completion = nil
        }

        // The request that asks for the properties does not install anything,
        // so it does not fail either. This is here so that the answer comes
        // even when the system has nothing to say.
        func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
            completion?(Information())
            completion = nil
        }

        // The request asks for properties and installs nothing, so it never
        // finishes with a result of its own. The answer comes through
        // foundProperties. This is here so that the protocol is satisfied.
        func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {}

        // The request asks for properties and does not install anything, so
        // macOS never asks whether an extension may be replaced. The method is
        // required by the protocol, and the answer is the safe one: nothing
        // is replaced.
        func request(_ request: OSSystemExtensionRequest,
                     actionForReplacingExtension existing: OSSystemExtensionProperties,
                     withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
            return .cancel
        }

        // The request asks for properties and does not install anything, so
        // macOS never asks for the approval of the person.
        func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}
    }
}
import Foundation
import NetworkExtension

struct RuleManager {
    
    static func addRule(
        session: NETunnelProviderSession,
        processNames: String,
        targetHosts: String,
        targetPorts: String,
        protocol: String,
        action: String,
        enabled: Bool = true,
        completion: @escaping (Bool, String, UInt32?) -> Void
    ) {
        sendMessage(
            session: session,
            action: "addRule",
            params: [
                "processNames": processNames,
                "targetHosts": targetHosts,
                "targetPorts": targetPorts,
                "ruleProtocol": `protocol`,
                "ruleAction": action,
                "enabled": enabled
            ]
        ) { success, result in
            if success, let result = result, result["status"] as? String == "ok" {
                let ruleId = (result["ruleId"] as? NSNumber).map { UInt32($0.intValue) }
                completion(true, L10n.t("Rule added successfully"), ruleId)
            } else {
                completion(false, result?["message"] as? String ?? L10n.t("Unknown error"), nil)
            }
        }
    }
    
    static func clearRules(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, String) -> Void
    ) {
        sendMessage(session: session, action: "clearRules", params: [:]) { success, result in
            let message = success
                ? L10n.f("Cleared %@ rule(s)", "\(result?["cleared"] as? Int ?? 0)")
                : (result?["message"] as? String ?? L10n.t("Unknown error"))
            completion(success, message)
        }
    }
    
    private static func sendMessage(
        session: NETunnelProviderSession,
        action: String,
        params: [String: Any],
        completion: @escaping (Bool, [String: Any]?) -> Void
    ) {
        var message = params
        message["action"] = action
        
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(false, nil)
            return
        }

        do {
            try session.sendProviderMessage(data) { response in
                guard let responseData = response,
                      let result = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let status = result["status"] as? String else {
                    completion(false, nil)
                    return
                }

                completion(status == "ok", result)
            }
        } catch {
            // The message could not even be sent. The system checks this channel
            // against the app's signature, and a build that is not signed by a
            // developer is refused - so the answer will never come. The caller
            // must not wait for it: this is what stops the tunnel, and a tunnel
            // that cannot be stopped is worse than one that is not cleared.
            completion(false, nil)
        }
    }
    
    static func resyncRules(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        applyRulesFromUserDefaults(session: session, completion: completion)
    }

    static func loadRulesFromUserDefaults(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        applyRulesFromUserDefaults(session: session, completion: completion)
    }

    // the whole saved list goes to the extension in one message and replaces the
    // running list atomically, so there is no moment where rules are missing
    private static func applyRulesFromUserDefaults(
        session: NETunnelProviderSession,
        completion: @escaping (Bool, Int) -> Void
    ) {
        let rules = UserDefaults.standard.array(forKey: "proxyRules") as? [[String: Any]] ?? []
        applyRules(session: session, rules: rules, completion: completion)
    }

    // replaces the extension's rule list with these rules (as saved by the app). also used
    // by the command line, which has its rules in memory instead of in the preferences
    static func applyRules(
        session: NETunnelProviderSession,
        rules: [[String: Any]],
        completion: @escaping (Bool, Int) -> Void
    ) {
        applyRulesReporting(session: session, rules: rules) { success, count, _ in
            completion(success, count)
        }
    }

    // the rules in the shape the extension reads them. the same shape is written
    // into the shared container, so the two ways of delivering them cannot drift
    static func rulePayload(_ rules: [[String: Any]]) -> [[String: Any]] {
        return rules.map { rule in
            [
                "processNames": rule["processNames"] as? String ?? "",
                "targetHosts": rule["targetHosts"] as? String ?? "",
                "targetPorts": rule["targetPorts"] as? String ?? "",
                "ruleProtocol": rule["protocol"] as? String ?? "BOTH",
                "ruleAction": rule["action"] as? String ?? "DIRECT",
                "enabled": rule["enabled"] as? Bool ?? true
            ]
        }
    }

    // the same, but the extension's own answer comes back as well. the command line
    // needs it: "some rules were rejected" is not something a person can act on,
    // but "the field 'ruleProtocol' is missing" is.
    static func applyRulesReporting(
        session: NETunnelProviderSession,
        rules: [[String: Any]],
        completion: @escaping (Bool, Int, [String: Any]?) -> Void
    ) {
        let payload = rulePayload(rules)

        sendMessage(session: session, action: "setRules", params: ["rules": payload]) { success, result in
            if success {
                let count = result?["count"] as? Int ?? payload.count
                DispatchQueue.main.async { completion(true, count, result) }
                return
            }
            // an extension that predates setRules answers nothing, fall back to
            // clear + add one by one (leaves a short gap while it runs)
            clearRules(session: session) { _, _ in
                guard !rules.isEmpty else {
                    DispatchQueue.main.async { completion(true, 0, result) }
                    return
                }
                addRulesInOrder(session: session, rules: rules, index: 0, added: 0, completion: completion)
            }
        }
    }

    private static func addRulesInOrder(        session: NETunnelProviderSession,
        rules: [[String: Any]],
        index: Int,
        added: Int,
        completion: @escaping (Bool, Int, [String: Any]?) -> Void
    ) {
        guard index < rules.count else {
            DispatchQueue.main.async { completion(true, added, nil) }
            return
        }
        let rule = rules[index]
        addRule(
            session: session,
            processNames: rule["processNames"] as? String ?? "",
            targetHosts: rule["targetHosts"] as? String ?? "",
            targetPorts: rule["targetPorts"] as? String ?? "",
            protocol: rule["protocol"] as? String ?? "BOTH",
            action: rule["action"] as? String ?? "DIRECT",
            enabled: rule["enabled"] as? Bool ?? true
        ) { success, _, _ in
            addRulesInOrder(
                session: session,
                rules: rules,
                index: index + 1,
                added: added + (success ? 1 : 0),
                completion: completion
            )
        }
    }
}

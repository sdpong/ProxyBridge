#!/bin/bash
# Compiles each logic test against the real extension sources and runs it. No installed extension or
# network needed, this is what could run on a hosted CI runner. Needs the Xcode command line tools.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$HERE/../../ProxiRoute/extension"
APP="$HERE/../../ProxiRoute/ProxiRoute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
run_test() {   # <test file> <extension sources...>
    local test="$1"; shift
    cp "$HERE/$test" "$TMP/main.swift"
    swiftc -o "$TMP/test" "$@" "$TMP/main.swift" -framework NetworkExtension -framework Network 2>"$TMP/build.log" \
        || { echo "build failed for $test"; grep -E "error:" "$TMP/build.log" | head; exit 1; }
    "$TMP/test"
}

run_test matcher_tests.swift "$EXT/AppProxyProvider.swift" "$EXT/DNSMapStore.swift" "$EXT/DNSPolicy.swift" "$EXT/DNSParser.swift" "$EXT/ChainAction.swift" "$EXT/Socks4Request.swift" "$EXT/FlowFailure.swift" "$EXT/ProviderDiagnostics.swift" "$EXT/LiveFlowRegistry.swift" "$EXT/ProxyAppIdentity.swift" "$EXT/ChainHealth.swift" "$EXT/ChainHealthProbe.swift" "$EXT/RouteOptions.swift" "$EXT/UpstreamConnection.swift" "$EXT/InterfaceWatcher.swift" "$EXT/LocalAddress.swift" "$EXT/DirectUDPSession.swift"
run_test dnsmap_tests.swift "$EXT/DNSMapStore.swift"
run_test dnspolicy_tests.swift "$EXT/DNSPolicy.swift" "$APP/DNSPolicySettings.swift" "$APP/L10n.swift"
run_test dnsparser_tests.swift "$EXT/DNSParser.swift"
run_test dnsstatus_tests.swift "$EXT/DNSStatusWriter.swift" "$APP/DNSStatusLine.swift" "$APP/ExtensionLogReader.swift" "$APP/L10n.swift"
run_test flowfailure_tests.swift "$EXT/FlowFailure.swift"
run_test diagnostics_tests.swift "$EXT/ProviderDiagnostics.swift"
run_test liveflow_tests.swift "$EXT/LiveFlowRegistry.swift"
run_test cli_tests.swift "$APP/CLIArguments.swift" "$APP/CLIProfile.swift" "$APP/CLIText.swift" "$APP/PPXImporter.swift" "$APP/ProxyChain.swift" "$APP/L10n.swift" "$APP/RouteSettings.swift"
run_test processlist_tests.swift "$APP/ProcessList.swift"
run_test chain_tests.swift "$EXT/ChainAction.swift" "$APP/ProxyChain.swift" "$APP/L10n.swift"
run_test chainstorage_tests.swift "$APP/ProxyChain.swift" "$APP/L10n.swift"
run_test ppx_tests.swift "$APP/PPXImporter.swift" "$APP/ProxyChain.swift" "$APP/L10n.swift"
run_test socks4_tests.swift "$EXT/Socks4Request.swift"
run_test handshake_tests.swift "$APP/ExtensionHandshake.swift" "$EXT/AppProxyProvider.swift" "$EXT/DNSMapStore.swift" "$EXT/DNSPolicy.swift" "$EXT/DNSParser.swift" "$EXT/ChainAction.swift" "$EXT/Socks4Request.swift" "$EXT/FlowFailure.swift" "$EXT/ProviderDiagnostics.swift" "$EXT/LiveFlowRegistry.swift" "$EXT/ProxyAppIdentity.swift" "$EXT/ChainHealth.swift" "$EXT/ChainHealthProbe.swift" "$EXT/RouteOptions.swift" "$EXT/UpstreamConnection.swift" "$EXT/InterfaceWatcher.swift" "$EXT/LocalAddress.swift" "$EXT/DirectUDPSession.swift"
run_test extensionlog_tests.swift "$APP/ExtensionLogReader.swift" "$APP/L10n.swift"
run_test rulepattern_tests.swift "$APP/RulePatternValidator.swift"
run_test ruleusage_tests.swift "$APP/RuleProgramUsage.swift" "$APP/RuleNameIndex.swift" "$APP/RulePatternValidator.swift" "$APP/ProcessList.swift"
run_test appid_tests.swift "$EXT/ProxyAppIdentity.swift"
run_test chainhealth_tests.swift "$EXT/ChainHealth.swift"
run_test l10n_tests.swift "$APP/L10n.swift"
run_test route_tests.swift "$EXT/RouteOptions.swift"
run_test localaddress_tests.swift "$EXT/LocalAddress.swift"
run_test localproxy_tests.swift "$APP/LocalProxyServer.swift" "$APP/LocalProxySocket.swift" "$APP/LocalProxyUpstream.swift" "$APP/LocalProxyUDPRelay.swift" "$APP/LocalProxySettings.swift" "$APP/LocalAddresses.swift"
run_test runtimemode_tests.swift "$APP/RuntimeMode.swift"

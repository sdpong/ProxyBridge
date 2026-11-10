#!/bin/bash
# Compiles each logic test against the real extension sources and runs it. No installed extension or
# network needed, this is what could run on a hosted CI runner. Needs the Xcode command line tools.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT="$HERE/../../ProxiRoute/extension"
HELPER="$HERE/../../ProxiRoute/helper"
APP="$HERE/../../ProxiRoute/ProxiRoute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# where the scripts of the package live, for the tests that read them.
# the test files are copied into a temporary folder before they are compiled,
# so a path derived from the place of the test file would point nowhere.
export PROXIRoute_SCRIPTS="$HERE/../../ProxiRoute/scripts"
# the sources of the app, for the tests that read them.
export PROXIRoute_APP="$HERE/../../ProxiRoute/ProxiRoute"
# the sources of the helper of the gateway mode, for the tests that read them.
export PROXIRoute_HELPER="$HERE/../../ProxiRoute/helper/GatewayFilter.swift"

run_test() {   # <test file> <extension sources...>
    local test="$1"; shift
    cp "$HERE/$test" "$TMP/main.swift"
    swiftc -o "$TMP/test" "$@" "$TMP/main.swift" -framework NetworkExtension -framework Network 2>"$TMP/build.log" \
        || { echo "build failed for $test"; grep -E "error:" "$TMP/build.log" | head; exit 1; }
    "$TMP/test"
}

run_test matcher_tests.swift "$EXT/AppProxyProvider.swift" "$EXT/DNSMapStore.swift" "$EXT/DNSPolicy.swift" "$EXT/DNSParser.swift" "$EXT/ChainAction.swift" "$EXT/Socks4Request.swift" "$EXT/FlowFailure.swift" "$EXT/ProviderDiagnostics.swift" "$EXT/LiveFlowRegistry.swift" "$EXT/ProxyAppIdentity.swift" "$EXT/ChainHealth.swift" "$EXT/ChainHealthProbe.swift" "$EXT/RouteOptions.swift" "$EXT/UpstreamConnection.swift" "$EXT/InterfaceWatcher.swift" "$EXT/LocalAddress.swift" "$EXT/DirectUDPSession.swift"
run_test udprule_tests.swift "$EXT/AppProxyProvider.swift" "$EXT/DNSMapStore.swift" "$EXT/DNSPolicy.swift" "$EXT/DNSParser.swift" "$EXT/ChainAction.swift" "$EXT/Socks4Request.swift" "$EXT/FlowFailure.swift" "$EXT/ProviderDiagnostics.swift" "$EXT/LiveFlowRegistry.swift" "$EXT/ProxyAppIdentity.swift" "$EXT/ChainHealth.swift" "$EXT/ChainHealthProbe.swift" "$EXT/RouteOptions.swift" "$EXT/UpstreamConnection.swift" "$EXT/InterfaceWatcher.swift" "$EXT/LocalAddress.swift" "$EXT/DirectUDPSession.swift"
run_test dnsmap_tests.swift "$EXT/DNSMapStore.swift"
run_test dnspolicy_tests.swift "$EXT/DNSPolicy.swift" "$APP/DNSPolicySettings.swift" "$APP/L10n.swift"
run_test dnsparser_tests.swift "$EXT/DNSParser.swift"
run_test dnsstatus_tests.swift "$EXT/DNSStatusWriter.swift" "$APP/DNSStatusLine.swift" "$APP/ExtensionLogReader.swift" "$APP/ToolRunner.swift" "$APP/L10n.swift"
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
run_test extensionlog_tests.swift "$APP/ExtensionLogReader.swift" "$APP/ToolRunner.swift" "$APP/L10n.swift"
run_test rulepattern_tests.swift "$APP/RulePatternValidator.swift"
run_test ruleusage_tests.swift "$APP/RuleProgramUsage.swift" "$APP/RuleNameIndex.swift" "$APP/RulePatternValidator.swift" "$APP/ProcessList.swift"
run_test appid_tests.swift "$EXT/ProxyAppIdentity.swift"
run_test chainhealth_tests.swift "$EXT/ChainHealth.swift"
run_test l10n_tests.swift "$APP/L10n.swift"
run_test route_tests.swift "$EXT/RouteOptions.swift"
run_test localaddress_tests.swift "$EXT/LocalAddress.swift"
run_test localproxy_tests.swift "$APP/LocalProxyServer.swift" "$APP/LocalProxySocket.swift" "$APP/LocalProxyUpstream.swift" "$APP/LocalProxyUDPRelay.swift" "$APP/LocalProxySettings.swift" "$APP/LocalAddresses.swift" "$APP/ToolRunner.swift" "$APP/ProxyRuleEngine.swift"
run_test ruleengine_tests.swift "$APP/ProxyRuleEngine.swift"
run_test runtimemode_tests.swift "$APP/RuntimeMode.swift"
run_test trafficmerge_tests.swift "$APP/TrafficMerge.swift"
run_test gatewayfilter_tests.swift "$APP/GatewayProtocol.swift" "$HELPER/GatewayFilter.swift" "$APP/ToolRunner.swift" "$HELPER/GatewayNetwork.swift"
run_test gateway_tests.swift "$APP/GatewayProtocol.swift" "$HELPER/GatewayFilter.swift" "$APP/ToolRunner.swift" "$HELPER/GatewayNetwork.swift"
run_test gateway_dataplane_tests.swift "$APP/GatewayDataPlane.swift" "$APP/GatewayUDPSession.swift" "$APP/GatewayProtocol.swift" "$APP/GatewayHelperClient.swift" "$APP/ProxyRuleEngine.swift" "$APP/LocalProxySocket.swift" "$APP/LocalProxyUpstream.swift"
run_test gateway_installer_tests.swift "$APP/GatewayInstaller.swift" "$APP/ToolRunner.swift" "$APP/GatewayHelperClient.swift" "$APP/GatewayProtocol.swift"
run_test menu_tests.swift "$APP/WindowMenuNoise.swift"
run_test signature_tests.swift "$APP/WindowMenuNoise.swift"
run_test windowdrawing_tests.swift "$APP/WindowMenuNoise.swift"
run_test toolrunner_tests.swift "$APP/ToolRunner.swift"
run_test localproxysettings_tests.swift "$APP/LocalProxySettings.swift" "$APP/ToolRunner.swift"
run_test extensioninstall_tests.swift "$APP/ExtensionDiagnosis.swift" "$APP/L10n.swift"
run_test installedextension_tests.swift "$APP/InstalledExtension.swift"
run_test extensioncleanup_tests.swift "$APP/ExtensionCleanup.swift" "$APP/ToolRunner.swift"
run_test upstreamwait_tests.swift "$APP/UpstreamWait.swift" "$APP/ToolRunner.swift" "$APP/UpstreamReadiness.swift"
run_test loginstart_tests.swift "$APP/UpstreamWait.swift" "$APP/ToolRunner.swift" "$APP/InstanceLock.swift" "$APP/NetworkReadiness.swift" "$APP/LaunchOrigin.swift"
run_test profilesafety_tests.swift
run_test interfacelist_tests.swift "$APP/InterfaceList.swift"

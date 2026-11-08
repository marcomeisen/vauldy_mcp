import Foundation
import Testing
@testable import VauldyMCPRuntime

@Suite("R4 build identity and honest local diagnosis")
struct MCPBuildDiagnosisTests {
    @Test func executableIdentityIsRealAndVersionKeepsProductSeparate() throws {
        let identity = try #require(MCPBuildIdentity.running)
        #expect(MCPBuildIdentity.read(URL(fileURLWithPath: CommandLine.arguments[0])) == identity)
        #expect(MCPBuildIdentity.fromProtocolVersion(MCPBuild.protocolVersion) == identity)
        #expect(MCPBuildIdentity.fromProtocolVersion(MCPBuild.version) == nil)
        #expect(MCPBuildIdentity.fromProtocolVersion("0.13.0+../../private") == nil)
        #expect(MCPBuildIdentity.parse(Data([0, 1, 2])) == nil)
        #expect(MCPBuildIdentity.parse(Data(repeating: 255, count: 128)) == nil)
    }

    @Test func universalAndMalformedMachOHeadersAreBounded() throws {
        func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func be(_ value: UInt32) -> [UInt8] { Array(le(value).reversed()) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let header = [UInt32(0xfeedfacf), cpu, 0, 2, 1, 24, 0, 0].flatMap(le)
        let thin = Data(header + le(27) + le(24) + Array(UInt8(0)...UInt8(15)))
        let expected = "macho.000102030405060708090a0b0c0d0e0f"
        #expect(MCPBuildIdentity.parse(thin) == expected)
        var fat = Data(be(0xcafebabe) + be(1) + be(cpu) + be(0) + be(4096) + be(UInt32(thin.count)) + be(12))
        fat.append(Data(repeating: 0, count: 4096 - fat.count)); fat.append(thin)
        #expect(MCPBuildIdentity.parse(fat) == expected)
        var wide = Data(be(0xcafebabf) + be(1) + be(cpu) + be(0) + be(0) + be(4096) + be(0) + be(UInt32(thin.count)) + be(12) + be(0))
        wide.append(Data(repeating: 0, count: 4096 - wide.count)); wide.append(thin)
        #expect(MCPBuildIdentity.parse(wide) == expected)
        #expect(MCPBuildIdentity.parse(Data(fat.dropLast())) == nil)
        var invalid = thin; invalid.replaceSubrange(36..<40, with: le(UInt32.max))
        #expect(MCPBuildIdentity.parse(invalid) == nil)
    }

    @Test func sameVersionOldBuildAndUnknownLegacyProcessNeedRestart() throws {
        var profile = MCPAccessProfile(vaultPath: "/synthetic/documents.json", allowedDocumentIDs: [UUID()], enabled: true, acknowledgedCloudDisclosure: true)
        let expected = "macho." + String(repeating: "a", count: 32)
        let old = MCPServerInstance(connectionID: profile.connectionID, version: MCPBuild.version, buildID: "macho." + String(repeating: "b", count: 32))
        let legacy = MCPServerInstance(connectionID: profile.connectionID, version: MCPBuild.version)
        for instance in [old, legacy] {
            let state = MCPConnectionState(profile: profile, instances: [instance], expectedBuildID: expected)
            #expect(state.restartRequired)
            #expect(state.headline == "Neustart im Chatbot erforderlich")
        }
        let current = MCPServerInstance(connectionID: profile.connectionID, version: MCPBuild.version, buildID: expected, lastRequestAt: Date())
        let state = MCPConnectionState(profile: profile, instances: [current], expectedBuildID: expected)
        #expect(!state.restartRequired && state.requestObserved)
        #expect(state.explanation.contains("nicht nachgewiesen"))
        var diagnostic = current; diagnostic.diagnostic = true
        #expect(!MCPConnectionState(profile: profile, instances: [diagnostic], expectedBuildID: expected).requestObserved)
        profile.enabled = false
        #expect(MCPConnectionState(profile: profile, instances: [old], expectedBuildID: expected).headline == "Dokumentzugriff pausiert")
        let bytes = Data("{\"diagnostic\":false,\"version\":\"0.13.0\"}".utf8)
        #expect(try JSONDecoder().decode(MCPServerInstance.self, from: bytes).buildID == nil)
    }

    @Test func paginatedNineToolsAndLegacySixAreDistinguishedWithoutDocuments() throws {
        try fixture { root in
            let old = try probe(root, tools: Array(MCPToolRequirements.current.subtracting(["compare_contract_versions", "get_deadline_overview", "get_document_inventory"])))
            #expect(old.serverVersion == MCPBuild.version && old.discoveredTools.count == 6)
            #expect(old.missingTools == ["compare_contract_versions", "get_deadline_overview", "get_document_inventory"])
            #expect(!old.compatible && !old.buildVerified && old.nextStep.contains("Software"))
            let current = try probe(root, tools: Array(MCPToolRequirements.current))
            #expect(current.discoveredTools.count == 9 && current.missingTools.isEmpty)
            // A script claiming a UUID is not proof of a Mach-O executable identity.
            #expect(!current.buildVerified)
        }
    }

    @Test func malformedDiscoveryAndProtocolHaveSpecificDiagnosis() throws {
        try fixture { root in
            #expect(throws: MCPLocalProbeError.discovery) { try probe(root, tools: Array(MCPToolRequirements.current), mode: "loop") }
            #expect(throws: MCPLocalProbeError.discovery) { try probe(root, tools: ["get_vault_status", "get_vault_status"]) }
            #expect(throws: MCPLocalProbeError.protocolMismatch) { try probe(root, tools: Array(MCPToolRequirements.current), mode: "protocol") }
            #expect(throws: MCPLocalProbeError.timeout) { try probe(root, tools: [], mode: "hang") }
            #expect(throws: MCPLocalProbeError.missingBinary) { try MCPLocalProbe.run(binary: root.appendingPathComponent("missing"), profile: root.appendingPathComponent("unused")) }
            #expect(throws: MCPLocalProbeError.exited) { try probe(root, tools: [], mode: "exit") }
            #expect(throws: MCPLocalProbeError.vaultUnavailable) { try probe(root, tools: Array(MCPToolRequirements.current), mode: "vault") }
        }
    }
}

private func fixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauldy-r4-unit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }; try body(root)
}
private func probe(_ root: URL, tools: [String], mode: String = "normal") throws -> MCPLocalProbeResult {
    let script = root.appendingPathComponent("fixture.py")
    let data = try JSONEncoder().encode(tools.sorted())
    let names = String(decoding: data, as: UTF8.self)
    let contents = """
    #!/usr/bin/python3
    import json,sys
    tools=\(names)
    mode='\(mode)'
    for line in sys.stdin:
        request=json.loads(line)
        if 'id' not in request: continue
        if mode=='exit': sys.exit(0)
        if mode=='hang':
            import time
            time.sleep(10)
        method=request['method']
        if method=='initialize':
            result={'protocolVersion':'wrong' if mode=='protocol' else '2025-11-25','serverInfo':{'name':'vauldy','version':'\(MCPBuild.version)'}}
        elif method=='tools/list':
            offset=int(request.get('params',{}).get('cursor','0'))
            result={'tools':[{'name':name} for name in tools[offset:offset+3]]}
            if offset+3<len(tools): result['nextCursor']=str(offset+3)
            if mode=='loop': result['nextCursor']='0'
        else:
            assert method=='tools/call' and request['params']['name']=='get_vault_status'
            result={'isError':mode=='vault','structuredContent':{'access':'disabled','grantedDocumentCount':0}}
        print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
    """
    try Data(contents.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return try MCPLocalProbe.run(binary: script, profile: root.appendingPathComponent("unused.json"), timeout: mode == "hang" ? 2 : 12)
}

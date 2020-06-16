// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystem
import LLBBuildSystemTestHelpers
import LLBBuildSystemProtocol
import LLBCASFileTree
import TSCBasic
import XCTest

struct PlatformFragmentKey: LLBConfigurationFragmentKey, Codable, Hashable {
    static let identifier = String(describing: Self.self)

    let platformName: String

    init(platformName: String) {
        self.platformName = platformName
    }
}

struct PlatformFragment: LLBConfigurationFragment, Codable {
    let expensiveCompilerPath: String

    init(expensiveCompilerPath: String) {
        self.expensiveCompilerPath = expensiveCompilerPath
    }
}

private final class PlatformFragmentFunction: LLBBuildFunction<PlatformFragmentKey, PlatformFragment> {
    override func evaluate(key: PlatformFragmentKey, _ fi: LLBBuildFunctionInterface) -> LLBFuture<PlatformFragment> {
        return engineContext.group.next().makeSucceededFuture(
            PlatformFragment(expensiveCompilerPath: "expensive_compiler_path_for_\(key.platformName)")
        )
    }
}

fileprivate struct ConfigurationTestsProvider: LLBProvider, Codable {
    let simpleString: String

    init(simpleString: String) {
        self.simpleString = simpleString
    }
}

private struct ConfigurationTestsConfiguredTarget: LLBConfiguredTarget, Codable {
    let name: String
    let dependency: LLBProviderMap?

    init(name: String, dependency: LLBProviderMap? = nil) {
        self.name = name
        self.dependency = dependency
    }
}

private final class ConfigurationTestsBuildRule: LLBBuildRule<ConfigurationTestsConfiguredTarget> {
    override func evaluate(configuredTarget: ConfigurationTestsConfiguredTarget, _ ruleContext: LLBRuleContext) throws -> LLBFuture<[LLBProvider]> {
        var returnValue = ""
        let platformConfiguration = try ruleContext.getFragment(PlatformFragment.self)
        returnValue += platformConfiguration.expensiveCompilerPath


        if let dependency = configuredTarget.dependency {
            returnValue += "-"
            returnValue += try dependency.get(ConfigurationTestsProvider.self).simpleString
        }

        return ruleContext.group.next().makeSucceededFuture([ConfigurationTestsProvider(simpleString: returnValue)])
    }
}

private final class ConfigurationTestsConfiguredTargetDelegate: LLBConfiguredTargetDelegate {
    func configuredTarget(for key: LLBConfiguredTargetKey, _ fi: LLBBuildFunctionInterface) throws -> LLBFuture<LLBConfiguredTarget> {

        if key.label.targetName == "top_level_target", try key.configurationKey.get(PlatformFragmentKey.self).platformName == "target" {
            let dependencyKey = LLBConfiguredTargetKey(
                rootID: key.rootID,
                label: try LLBLabel("//some:top_level_target"),
                configurationKey: try LLBConfigurationKey(fragmentKeys: [PlatformFragmentKey(platformName: "host")])
            )
            return fi.requestDependency(dependencyKey).map { providerMap in
                return ConfigurationTestsConfiguredTarget(name: key.label.targetName, dependency: providerMap)
            }
        }

        return fi.group.next().makeSucceededFuture(ConfigurationTestsConfiguredTarget(name: key.label.targetName))
    }
}

private final class ConfigurationTestsRuleLookupDelegate: LLBRuleLookupDelegate {
    let ruleMap: [String: LLBRule] = [
        ConfigurationTestsConfiguredTarget.identifier: ConfigurationTestsBuildRule(),
    ]

    func rule(for configuredTargetType: LLBConfiguredTarget.Type) -> LLBRule? {
        return ruleMap[configuredTargetType.identifier]
    }
}

class ConfigurationTestsFunctionMap: LLBBuildFunctionLookupDelegate {
    let functionMap: [LLBBuildKeyIdentifier: LLBFunction]

    init(engineContext: LLBBuildEngineContext) {
        self.functionMap = [
            PlatformFragmentKey.identifier: PlatformFragmentFunction(engineContext: engineContext),
        ]
    }

    func lookupBuildFunction(for identifier: LLBBuildKeyIdentifier) -> LLBFunction? {
        return self.functionMap[identifier]
    }
}


class ConfigurationTests: XCTestCase {
    // This test requires a lot of setup, but effectively it's testing that configuration transitions result in the same
    // target (as represented by the label) gets evaluated for each configuration encountered during the build. You can
    // see this by the assert at the end, where the final `simpleString` contains references to the target configuration
    // and the host configuration.
    // This works more as an integration test, since it enforces the functionalities of most of the build system to
    // achieve this result. Real life clients of llbuild2 will need to provide similar infrastructure (in a more
    // sustainable approach of course).
    func testSameTargetConfigurationTransitions() throws {
        LLBConfigurationKey.register(fragmentKeyType: PlatformFragmentKey.self)
        LLBConfigurationValue.register(fragmentType: PlatformFragment.self)

        try withTemporaryDirectory { tempDir in
            LLBConfiguredTargetValue.register(configuredTargetType: ConfigurationTestsConfiguredTarget.self)

            let configuredTargetDelegate = ConfigurationTestsConfiguredTargetDelegate()
            let ruleLookupDelegate = ConfigurationTestsRuleLookupDelegate()
            let testEngineContext = LLBTestBuildEngineContext()
            let testEngine = LLBTestBuildEngine(
                buildFunctionLookupDelegate: ConfigurationTestsFunctionMap(engineContext: testEngineContext),
                configuredTargetDelegate: configuredTargetDelegate,
                ruleLookupDelegate: ruleLookupDelegate
            )

            let dataID = try LLBCASFileTree.import(path: tempDir, to: testEngine.testDB).wait()

            let label = try LLBLabel("//some:top_level_target")
            let configurationKey = try LLBConfigurationKey(fragmentKeys: [PlatformFragmentKey(platformName: "target")])
            let configuredTargetKey = LLBConfiguredTargetKey(rootID: dataID, label: label, configurationKey: configurationKey)

            let evaluatedTargetKey = LLBEvaluatedTargetKey(configuredTargetKey: configuredTargetKey)

            let evaluatedTargetValue: LLBEvaluatedTargetValue = try testEngine.build(evaluatedTargetKey).wait()

            let simpleString = try evaluatedTargetValue.providerMap.get(ConfigurationTestsProvider.self).simpleString

            XCTAssertEqual(simpleString, "expensive_compiler_path_for_target-expensive_compiler_path_for_host")
        }
    }
}

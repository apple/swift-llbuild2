// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import LLBCAS

public extension LLBActionExecutionRequest {
    init(actionSpec: LLBActionSpec, inputs: [LLBActionInput], outputs: [LLBActionOutput]) {
        self.actionSpec = actionSpec
        self.inputs = inputs
        self.outputs = outputs
    }
}

public extension LLBActionExecutionResponse {
    init(outputs: [LLBPBDataID], exitCode: Int, stdoutID: LLBPBDataID, stderrID: LLBPBDataID) {
        self.outputs = outputs
        self.exitCode = Int32(exitCode)
        self.stdoutID = stdoutID
        self.stderrID = stderrID
    }
}

public extension LLBActionInput {
    init(path: String, dataID: LLBPBDataID, type: LLBArtifactType) {
        self = Self.with {
            $0.path = path
            $0.dataID = dataID
            $0.type = type
        }
    }
}

public extension LLBActionOutput {
    init(path: String, type: LLBArtifactType) {
        self = Self.with {
            $0.path = path
            $0.type = type
        }
    }
}

public extension LLBEnvironmentVariable {
    init(name: String, value: String) {
        self = Self.with {
            $0.name = name
            $0.value = value
        }
    }
}

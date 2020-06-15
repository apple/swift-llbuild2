// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

public enum LLBLabelError: Error {
    /// Error for finding invalid characters in the label.
    case invalidCharacters(String)

    /// Error for finding an unexpected character in label parsing.
    case unexpectedCharacter(Character)

    /// Error for an invalid prefix for the label.
    case unexpectedPrefix(String)

    /// Error for a label that has an invalid suffix.
    case unexpectedSuffix(String)

    /// Error for when a label is invalid.
    case invalidLabel(String)
}

extension LLBLabel {
    // Character set used in label scanning.
    public static let colonCharacterSet = CharacterSet(charactersIn: ":")
    public static let slashCharacterSet = CharacterSet(charactersIn: "/")

    /// Characters disallowed in label components.
    public static let invalidCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890-_:/."
    ).inverted

    public init(_ string: String) throws {
        let stringScanner = Scanner(string: string)

        // If there are any invalid characters error out.
        if let range = string.rangeOfCharacter(from: LLBLabel.invalidCharacters) {
            throw LLBLabelError.invalidCharacters("Invalid characters in range: \(String(describing: range))")
        }

        // Read exactly 2 `/` characters from the beginning.
        guard let separator = stringScanner.scanCharacters(from: LLBLabel.slashCharacterSet), separator.count == 2 else {
            throw LLBLabelError.unexpectedPrefix(string)
        }

        let unionCharacterSet = LLBLabel.colonCharacterSet.union(LLBLabel.slashCharacterSet)
        var pathComponents = [String]()

        // Read components until we find either `:` or `/`.
        while true {
            if let pathComponent = stringScanner.scanUpToCharacters(from: unionCharacterSet) {
                pathComponents.append(pathComponent)
            }

            if let nextCharacter = stringScanner.scanCharacter() {
                if nextCharacter == ":" {
                    break
                } else if nextCharacter == "/" {
                    continue
                } else {
                    throw LLBLabelError.unexpectedCharacter(nextCharacter)
                }
            } else {
                break
            }
        }

        self.logicalPathComponents = pathComponents

        // Read until we find another separator character. If there is more, it's the target name, if not, use the
        // last path component as the target name as a short-cut feature.
        if let targetName = stringScanner.scanUpToCharacters(from: unionCharacterSet) {
            self.targetName = targetName
        } else {
            guard let lastPathComponent = pathComponents.last else {
                throw LLBLabelError.invalidLabel(string)
            }
            self.targetName = lastPathComponent
        }

        // Make sure we've read all of the input, if not, the label was invalid
        if !stringScanner.isAtEnd {
            throw LLBLabelError.unexpectedSuffix(string)
        }
    }

    public var canonical: String {
        "//\(logicalPathComponents.joined(separator: "/")):\(targetName)"
    }
}

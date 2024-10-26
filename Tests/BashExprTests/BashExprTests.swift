import Foundation
import SwiftTreeSitter
import TSCBasic
import TSCUtility
import TSFCAS
import TSFFutures
import TreeSitterBash
import XCTest
import llbuild2
import llbuild2fx
import BashExpr

class BashExprTests: XCTestCase {
    func testBashExprEvalBasics() async throws {
        // replacing a variable with its binded value (e.g. $SDK)
        let exprSimpleVar: BashExpr<String> = try .polishTreeSitterOutput("echo $SDK")
        XCTAssertEqual(
            exprSimpleVar,
            .program([
                .command(
                    commandName: .literal("echo"),
                    args: [
                        .simpleExpansion([
                            .literal("$"), .literal("SDK"),
                        ])
                    ])
            ])
        )

        let resWithNoBinding = await exprSimpleVar.eval(
            cfg: CASToolEvalConfiguration(variableMappings: [:])
        )
        XCTAssertEqual(
            resWithNoBinding.expr,
            .error(.unboundedVariable(variableName: "SDK"))
        )

        let resWithBinding = await exprSimpleVar.eval(
            cfg: CASToolEvalConfiguration(variableMappings: ["SDK": .literal("/path/to/SDK")])
        )
        XCTAssertEqual(resWithBinding.stdout, "/path/to/SDK")
        XCTAssertEqual(resWithBinding.expr, .literal("/path/to/SDK"))

        // seq 1 10
        let seq = try await BashExpr<String>.polishTreeSitterOutput("seq 1 10").eval(
            cfg: TestEvalConfiguration(
                variableMappings: [:]
            )
        )

        XCTAssertEqual(seq.stdout, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
        XCTAssertEqual(seq.expr, .literal("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"))

        // non-castool commands: deny
        // conditional: deny
        // redirects to file: deny
        // pipes: deny
    }

    // $(..) syntax
    func testCommandSubstitution() async throws {
        let cmd = "cat $(./1.sh) $(./2.sh):foo"
        XCTAssertEqual(
            try BashExpr<Int>.polishTreeSitterOutput(cmd),
            .program(
                [.command(
                    commandName: .literal("cat"),
                    args: [
                        .commandSubstitution(
                            [
                                .literal("$("),
                                .command(commandName: .literal("./1.sh"), args: []),
                                .literal(")")
                            ]
                        ),
                        .concatenation(
                            [
                                .commandSubstitution(
                                    [
                                        .literal("$("),
                                        .command(commandName: .literal("./2.sh"), args: []),
                                        .literal(")")
                                    ]
                                ),
                                .literal(":foo")
                            ]
                        )
                    ]
                )]
            )
        )
    }
}

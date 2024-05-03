import Foundation
import llbuild2
import SwiftTreeSitter

// CE is short for "Configuration Error".
public indirect enum BashExprError<CE: Equatable>: LocalizedError, Equatable {
    case unknownError(String, NSRange)
    case configurationSpecificError(CE)
    case unexpectedToken(String, NSRange)
    case invalidCommandName(String, NSRange)
    case unboundedVariable(variableName: String)
    case notImplementedByEval(String)
    case unexpectedValue(String, expected: String)
    case notImplementedByToBashExpr(String)
    case manyErrors([Self])
    case castoolError(String)
}

// MARK: BashExpr
// Just enough of Bash to support argument parsing, variable substitution and command substitution.
//
// Example:
// `castool cp $(castool unarchive $SCRIPT_INPUT_0:/.BuildData/XCBuildData.aar):/path/to/XCBBuildService /Applications/Xcode.app/blah`
//

public protocol EvalConfiguration<CE>: Equatable {
    associatedtype CE: Equatable
    var variableMappings: [String: BashExpr<CE>] { get }
    func runBuiltInCommand(commandName: String, args: [String]) async -> BashExprEvaluationResult<CE>
}

public struct BashExprEvaluationResult<CE: Equatable> {
    public let stdin: String
    public let stdout: String
    public let stderr: String
    public let expr: BashExpr<CE>

    public init(
        stdin: String = "",
        stdout: String = "",
        stderr: String = "",
        expr: BashExpr<CE>
    ) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.expr = expr
    }
}

public struct TestEvalConfiguration: EvalConfiguration {
    public enum EvalError: Equatable {
        case sandboxDeny(commandName: String)
        case notImplementedByConfiguration(String)
    }

    public let variableMappings: [String: BashExpr<EvalError>]

    public init(variableMappings: [String: BashExpr<EvalError>]) {
        self.variableMappings = variableMappings
    }

    public func runBuiltInCommand(commandName: String, args: [String]) async -> BashExprEvaluationResult<EvalError> {
        if commandName == "seq" {
            let out = (1..<11).map(\.description).joined(separator: "\n") + "\n"
            return BashExprEvaluationResult(
                stdout: out,
                expr: .literal(out)
            )
        } else if commandName == "echo" {
            let out = args.joined(separator: " ")
            return BashExprEvaluationResult(
                stdout: out,
                expr: .literal(out)
            )
        } else {
            return BashExprEvaluationResult(
                expr: .error(
                    BashExprError.configurationSpecificError(
                        EvalError.notImplementedByConfiguration(commandName)
                    )
                ))
        }
    }
}

public indirect enum BashExpr<T: Equatable>: Equatable {
    case program([BashExpr])
    case command(commandName: BashExpr, args: [BashExpr])
    case literal(String)
    case casRef(LLBDataID)
    case number(Int)
    case error(BashExprError<T>)
    case concatenation([BashExpr])
    case commandSubstitution([BashExpr])
    case simpleExpansion([BashExpr])

    public func eval<CE>(cfg: some EvalConfiguration<CE>) async -> BashExprEvaluationResult<CE>{
        switch self {
        case .program(let exprs):
            guard exprs.count == 1, let expr = exprs.first else {
                return .init(expr: .error(.notImplementedByEval("programs with more than one expr are not implemented")))
            }
            return await expr.eval(cfg: cfg)
        case .number(let num):
            return .init(expr: .literal("\(num)"))
        case .simpleExpansion(let children):
            guard case .literal("$") = children.first else {
                return .init(
                    expr: .error(
                        .unexpectedToken(
                            "\(children.first), expected .literal($)",
                            NSRange(location: 0, length: 0)
                        )
                    )
                )
            }
            switch children.dropFirst().first {
            case .literal(let varName):
                return .init(
                    expr:
                        cfg.variableMappings[varName] ?? .error(.unboundedVariable(variableName: varName)))
            default:
                return .init(
                    expr: .error(
                        .unknownError(
                            "Invalid non-literal variable name",
                            NSRange(
                                location: 0,
                                length: 0
                            )
                        )
                    )
                )
            }

        case .command(let commandName, let commandArgs):
            let args: [BashExpr<CE>] = await commandArgs.asyncMap { argExpr in
                let finalExpr = await argExpr.eval(cfg: cfg).expr
                switch finalExpr {
                case .literal(let lit):
                    return finalExpr
                case .error(let err):
                    return .error(err)
                default:
                    return .error(
                        .unknownError(
                            "Not a literal",
                            NSRange(location: 0, length: 0)
                        )
                    )
                }
                return finalExpr
            }

            let errs = args.compactMap { arg in
                switch arg {
                case .error(let err):
                    return err
                default:
                    return nil
                }
            }
            if !errs.isEmpty {
                if errs.count == 1, let err = errs.first {
                    return .init(expr: .error(err))
                }
                return .init(expr: .error(.manyErrors(errs)))
            }

            guard case let .literal(commandNameString) = commandName else {
                return .init(expr: .error(.notImplementedByEval("non-string command name")))
            }

            let argsStr: [String] = args.compactMap { arg in
                guard case .literal(let lit) = arg else {
                    return nil
                }
                return lit
            }

            return await cfg.runBuiltInCommand(
                commandName: commandNameString,
                args: argsStr
            )

        case .concatenation(let exprs):
            let evaluatedExprs = await exprs.asyncMap { expr in
                await expr.eval(cfg: cfg).expr
            }
            var res: [String] = []
            for expr in evaluatedExprs {
                switch expr {
                case .literal(let val):
                    res.append(val)
                default:
                    return .init(expr: .error(.unexpectedValue("\(expr)", expected: ".literal")))
                }
            }
            return .init(expr: .literal(res.joined()))

        case .literal(let str):
            return .init(expr: .literal(str))

        default:
            return .init(expr: .error(.notImplementedByEval("\(self)")))
        }
    }
}

import SwiftTreeSitter
import TSCBasic
import TreeSitterBash

extension BashExpr {
    public static func polishTreeSitterOutput(_ source: String) throws -> BashExpr {
        let bashConfig = try LanguageConfiguration(tree_sitter_bash(), name: "Bash")

        let parser = Parser()
        try parser.setLanguage(bashConfig.language)

        guard let tree = parser.parse(source) else {
            throw StringError("Could not parse '\(source)' as bash")
        }

        return try tree.rootNode!.toBashExpr(source).get()
    }
}

extension Node {
    func toSubstr(_ source: String) -> String {
        guard let r = Range(self.range, in: source) else {
            return "\(self.range)"
        }
        return String(source[r])
    }

    func toBashExpr<T>(_ source: String) -> Result<BashExpr<T>, BashExprError<T>> {
        switch self.nodeType {
        case .none:
            return .failure(BashExprError.unexpectedToken("??", self.range))

        case .some(let nodeType):
            switch nodeType {
            case "$", "variable_name", ")", "$(":
                return .success(.literal(self.toSubstr(source)))

            case "number":
                let num = self.toSubstr(source)
                guard let num = Int(num) else {
                    return .failure(.unknownError("Not a number", self.range))
                }
                return .success(.number(num))

            case "command_name":
                return .success(.literal(self.toSubstr(source)))

            case "word":
                return .success(.literal(self.toSubstr(source)))

            case "simple_expansion":
                var res: [BashExpr<T>] = []
                self.enumerateChildren { node in
                    let maybeExpr: Result<BashExpr<T>, BashExprError<T>> = node.toBashExpr(source)
                    switch maybeExpr {
                    case .success(let expr):
                        res.append(expr)
                    case .failure(let err):
                        res.append(BashExpr.error(err))
                    }
                }
                return .success(.simpleExpansion(res))

            case "command_substitution":
                var res: [BashExpr<T>] = []
                self.enumerateChildren { node in
                    let maybeExpr: Result<BashExpr<T>, BashExprError<T>> = node.toBashExpr(source)
                    switch maybeExpr {
                    case .success(let expr):
                        res.append(expr)
                    case .failure(let err):
                        res.append(BashExpr.error(err))
                    }
                }
                return .success(.commandSubstitution(res))

            case "concatenation":
                var res: [BashExpr<T>] = []
                self.enumerateChildren { node in
                    let maybeExpr: Result<BashExpr<T>, BashExprError<T>> = node.toBashExpr(source)
                    switch maybeExpr {
                    case .success(let expr):
                        res.append(expr)
                    case .failure(let err):
                        res.append(BashExpr.error(err))
                    }
                }
                return .success(.concatenation(res))

            case "program":
                var res: [BashExpr<T>] = []
                self.enumerateChildren { node in
                    let maybeExpr: Result<BashExpr<T>, BashExprError<T>> = node.toBashExpr(source)
                    switch maybeExpr {
                    case .success(let expr):
                        res.append(expr)
                    case .failure(let err):
                        res.append(BashExpr.error(err))
                    }
                }
                return .success(.program(res))

            case "command":
                guard let firstChild = self.firstChild else {
                    return .failure(BashExprError.unknownError("Command has no first child", self.range))
                }
                if firstChild.nodeType == "command_name" {
                    var args: [BashExpr<T>] = []
                    self.enumerateChildren { node in
                        let maybeExpr: Result<BashExpr<T>, BashExprError<T>> = node.toBashExpr(source)
                        switch maybeExpr {
                        case .success(let expr):
                            args.append(expr)
                        case .failure(let err):
                            args.append(.error(err))
                        }
                    }
                    let maybeFirstChild: Result<BashExpr<T>, BashExprError<T>> = firstChild.toBashExpr(source)
                    switch maybeFirstChild {
                    case .success(let expr):
                        switch expr {
                        case .literal(let lit):
                            return .success(
                                .command(
                                    commandName: .literal(lit),
                                    args: Array(args.dropFirst())
                                )
                            )
                        default:
                            return .failure(.unknownError("Invalid non-literal \(expr)", self.range))
                        }
                    case .failure(let err):
                        return .failure(err)
                    }
                } else {
                    return .failure(.invalidCommandName(self.firstChild.debugDescription, self.range))
                }

            default:
                return .success(.error(.notImplementedByToBashExpr("\(nodeType) in tree_sitter")))
            }
        }
    }
}

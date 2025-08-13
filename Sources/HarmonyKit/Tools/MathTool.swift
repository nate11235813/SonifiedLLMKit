import Foundation

public struct MathTool: HarmonyTool {
    public let name: String = "math"
    public let description: String = "Safely evaluate a simple arithmetic expression with + - * / ^ and parentheses."
    public let parametersJSONSchema: String = "{" +
    "\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"],\"additionalProperties\":false" +
    "}"

    public init() {}

    public func invoke(args: [String : Any]) throws -> ToolResult {
        guard let expr = args["expression"] as? String else {
            return ToolResult(name: name, content: "error: missing expression", metadata: ["error": "missing expression"])
        }
        do {
            let value = try ExpressionEvaluator().evaluate(expr: expr)
            // Emit as a string content with numeric metadata for clarity
            return ToolResult(name: name, content: String(value), metadata: ["value": value])
        } catch {
            return ToolResult(name: name, content: "error: invalid expression", metadata: ["error": String(describing: error)])
        }
    }
}

// MARK: - Tiny safe expression evaluator

private struct ExpressionEvaluator {
    enum EvalError: Error, CustomStringConvertible { case invalidToken, mismatchedParens, divideByZero, empty, unexpected
        var description: String {
            switch self {
            case .invalidToken: return "invalid token"
            case .mismatchedParens: return "mismatched parentheses"
            case .divideByZero: return "divide by zero"
            case .empty: return "empty expression"
            case .unexpected: return "unexpected"
            }
        }
    }

    func evaluate(expr: String) throws -> Double {
        let tokens = try tokenize(expr: expr)
        if tokens.isEmpty { throw EvalError.empty }
        let rpn = try shuntingYard(tokens: tokens)
        return try evalRPN(tokens: rpn)
    }

    private enum Token: Equatable { case number(Double), op(Character), lparen, rparen }

    private func tokenize(expr: String) throws -> [Token] {
        var tokens: [Token] = []
        var i = expr.startIndex
        func peek() -> Character? { i < expr.endIndex ? expr[i] : nil }
        func advance() { i = expr.index(after: i) }

        while let c = peek() {
            if c.isWhitespace { advance(); continue }
            if c.isNumber || c == "." {
                var start = i
                var hasDot = c == "."
                advance()
                while let d = peek(), d.isNumber || d == "." {
                    if d == "." { if hasDot { throw EvalError.invalidToken } else { hasDot = true } }
                    advance()
                }
                let s = String(expr[start..<i])
                guard let v = Double(s) else { throw EvalError.invalidToken }
                tokens.append(.number(v))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^": tokens.append(.op(c)); advance()
            case "(": tokens.append(.lparen); advance()
            case ")": tokens.append(.rparen); advance()
            default: throw EvalError.invalidToken
            }
        }
        return tokens
    }

    private func precedence(_ op: Character) -> Int {
        switch op {
        case "+", "-": return 1
        case "*", "/": return 2
        case "^": return 3
        default: return 0
        }
    }

    private func isRightAssociative(_ op: Character) -> Bool { op == "^" }

    private func shuntingYard(tokens: [Token]) throws -> [Token] {
        var out: [Token] = []
        var stack: [Token] = []
        for t in tokens {
            switch t {
            case .number:
                out.append(t)
            case .op(let o1):
                while let top = stack.last {
                    switch top {
                    case .op(let o2) where (precedence(o2) > precedence(o1)) || (precedence(o2) == precedence(o1) && !isRightAssociative(o1)):
                        out.append(stack.removeLast())
                    case .lparen:
                        break
                    default:
                        break
                    }
                    if case .op(let o2) = top, (precedence(o2) > precedence(o1)) || (precedence(o2) == precedence(o1) && !isRightAssociative(o1)) {
                        continue
                    } else { break }
                }
                stack.append(t)
            case .lparen:
                stack.append(t)
            case .rparen:
                var found = false
                while let top = stack.last {
                    if case .lparen = top { found = true; _ = stack.popLast(); break }
                    out.append(stack.removeLast())
                }
                if !found { throw EvalError.mismatchedParens }
            }
        }
        while let top = stack.popLast() {
            if case .lparen = top { throw EvalError.mismatchedParens }
            out.append(top)
        }
        return out
    }

    private func evalRPN(tokens: [Token]) throws -> Double {
        var stack: [Double] = []
        for t in tokens {
            switch t {
            case .number(let v): stack.append(v)
            case .op(let o):
                guard let b = stack.popLast(), let a = stack.popLast() else { throw EvalError.unexpected }
                switch o {
                case "+": stack.append(a + b)
                case "-": stack.append(a - b)
                case "*": stack.append(a * b)
                case "/":
                    if b == 0 { throw EvalError.divideByZero }
                    stack.append(a / b)
                case "^": stack.append(pow(a, b))
                default: throw EvalError.unexpected
                }
            default: throw EvalError.unexpected
            }
        }
        guard let result = stack.last, stack.count == 1 else { throw EvalError.unexpected }
        return result
    }
}



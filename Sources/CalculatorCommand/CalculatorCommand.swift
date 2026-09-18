import Foundation
import ios_system

/// `bc`/`dc` — Termux ships both as thin wrappers around `bc_ios`, which has
/// no SPM repo of its own (`holzschu/bc_ios` 404s, see Docs/NEXT_STEPS.md
/// item 6). Rather than wait on that, this is a from-scratch Swift port of
/// the same two calculators, scoped down deliberately: `Double` precision,
/// not GNU bc's arbitrary-precision decimal arithmetic. That covers the
/// overwhelming majority of real Termux `bc`/`dc` usage (quick arithmetic,
/// unit conversions) but will visibly diverge from real bc on things like
/// `scale=50; 22/7` — there is no `scale` here at all.
///
/// `bc`: infix expressions, one per line (`echo "2^10" | bc`, or piped
/// stdin, or one expression per positional argument). Supports
/// `+ - * / % ^ ( )` and decimal literals.
///
/// `dc`: reverse-Polish stack machine, tokens separated by whitespace
/// (real dc parses digit-by-digit without requiring whitespace — a
/// simplification, documented here rather than silently). Supports
/// `+ - * / % ^`, `p` (print top), `f` (print whole stack), `c` (clear),
/// `d` (duplicate top), `r` (swap top two), `q` (quit).
public enum CalculatorCommand {

    public static func register() {
        replaceCommand("bc", "bc_main", true)
        replaceCommand("dc", "dc_main", true)
    }
}

@_cdecl("bc_main")
public func bc_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = commandLineArguments(argc: argc, argv: argv)

    if args.isEmpty {
        while let line = readLine() {
            evaluateAndPrintBC(line)
        }
    } else {
        for expression in args {
            evaluateAndPrintBC(expression)
        }
    }
    return 0
}

private func evaluateAndPrintBC(_ expression: String) {
    let trimmed = expression.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    do {
        var parser = BCParser(trimmed)
        let result = try parser.parseExpression()
        print(formatNumber(result))
    } catch {
        FileHandle.standardError.write("bc: \(error)\n".data(using: .utf8)!)
    }
}

@_cdecl("dc_main")
public func dc_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let args = commandLineArguments(argc: argc, argv: argv)
    var stack: [Double] = []

    func process(_ line: String) -> Bool {
        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            switch token {
            case "+", "-", "*", "/", "%", "^":
                guard stack.count >= 2 else {
                    FileHandle.standardError.write("dc: stack empty\n".data(using: .utf8)!)
                    continue
                }
                let b = stack.removeLast()
                let a = stack.removeLast()
                switch token {
                case "+": stack.append(a + b)
                case "-": stack.append(a - b)
                case "*": stack.append(a * b)
                case "/": stack.append(a / b)
                case "%": stack.append(a.truncatingRemainder(dividingBy: b))
                case "^": stack.append(pow(a, b))
                default: break
                }
            case "p":
                if let top = stack.last { print(formatNumber(top)) }
            case "f":
                for value in stack.reversed() { print(formatNumber(value)) }
            case "c":
                stack.removeAll()
            case "d":
                if let top = stack.last { stack.append(top) }
            case "r":
                guard stack.count >= 2 else { break }
                stack.swapAt(stack.count - 1, stack.count - 2)
            case "q":
                return false
            default:
                if let value = Double(token) {
                    stack.append(value)
                } else {
                    FileHandle.standardError.write("dc: unrecognized token '\(token)'\n".data(using: .utf8)!)
                }
            }
        }
        return true
    }

    if args.isEmpty {
        while let line = readLine() {
            if !process(line) { break }
        }
    } else {
        _ = process(args.joined(separator: " "))
    }
    return 0
}

private func formatNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    return String(value)
}

private func commandLineArguments(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    guard let argv else { return [] }
    return (1..<Int(argc)).compactMap { i in
        argv[i].map { String(cString: $0) }
    }
}

// MARK: - bc infix expression parser

private enum BCError: Error, CustomStringConvertible {
    case unexpectedCharacter(Character)
    case unexpectedEnd
    case divisionByZero

    var description: String {
        switch self {
        case .unexpectedCharacter(let c): return "unexpected character '\(c)'"
        case .unexpectedEnd: return "unexpected end of expression"
        case .divisionByZero: return "division by zero"
        }
    }
}

/// Recursive-descent parser/evaluator for `+ - * / % ^ ( )` with standard
/// precedence (`^` right-associative, binds tightest; unary `-` supported).
private struct BCParser {
    private let characters: [Character]
    private var index = 0

    init(_ expression: String) {
        characters = Array(expression)
    }

    mutating func parseExpression() throws -> Double {
        let result = try parseAddSub()
        skipWhitespace()
        if index < characters.count {
            throw BCError.unexpectedCharacter(characters[index])
        }
        return result
    }

    private mutating func parseAddSub() throws -> Double {
        var value = try parseMulDiv()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "+" || op == "-" else { break }
            index += 1
            let rhs = try parseMulDiv()
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseMulDiv() throws -> Double {
        var value = try parsePower()
        while true {
            skipWhitespace()
            guard let op = peek(), op == "*" || op == "/" || op == "%" else { break }
            index += 1
            let rhs = try parsePower()
            switch op {
            case "*": value *= rhs
            case "/":
                guard rhs != 0 else { throw BCError.divisionByZero }
                value /= rhs
            default:
                guard rhs != 0 else { throw BCError.divisionByZero }
                value = value.truncatingRemainder(dividingBy: rhs)
            }
        }
        return value
    }

    private mutating func parsePower() throws -> Double {
        let base = try parseUnary()
        skipWhitespace()
        if peek() == "^" {
            index += 1
            let exponent = try parsePower() // right-associative
            return pow(base, exponent)
        }
        return base
    }

    private mutating func parseUnary() throws -> Double {
        skipWhitespace()
        if peek() == "-" {
            index += 1
            return -(try parseUnary())
        }
        if peek() == "+" {
            index += 1
            return try parseUnary()
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        skipWhitespace()
        guard let char = peek() else { throw BCError.unexpectedEnd }

        if char == "(" {
            index += 1
            let value = try parseAddSub()
            skipWhitespace()
            guard peek() == ")" else { throw BCError.unexpectedEnd }
            index += 1
            return value
        }

        guard char.isNumber || char == "." else {
            throw BCError.unexpectedCharacter(char)
        }

        var numberString = ""
        while let c = peek(), c.isNumber || c == "." {
            numberString.append(c)
            index += 1
        }
        guard let value = Double(numberString) else {
            throw BCError.unexpectedCharacter(char)
        }
        return value
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" {
            index += 1
        }
    }
}

import Foundation

public struct TaskPromptTemplate: Equatable, Sendable {
    public static let applicationDefaultTemplate = TaskPromptTemplate("Run `{{cliCommand}}` and complete the listed tasks. Use `taskpond item update [task id] --status [status]` to update task status. Skip `Draft` tasks. Mark unclear, unnatural, or clearly unrelated tasks as `on-hold`. Mark tasks as `in-progress` when started and `aborted` if they cannot be completed. Group related work into appropriate commits. Use sub-agents with separate worktrees when parallelization helps, then merge their branches into the current branch. Before finishing, run `{{cliCommand}}` again because the user may add more tasks, and ensure no uncommitted changes remain.")

    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public func evaluated(variables: [String: String]) -> String {
        var result = ""
        var remaining = rawValue[...]

        while let openRange = remaining.range(of: "{{") {
            result += String(remaining[..<openRange.lowerBound])

            let tokenStart = openRange.upperBound
            guard let closeRange = remaining[tokenStart...].range(of: "}}") else {
                result += String(remaining[openRange.lowerBound...])
                return result
            }

            let token = remaining[tokenStart..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let originalToken = remaining[openRange.lowerBound..<closeRange.upperBound]
            result += variables[token] ?? String(originalToken)
            remaining = remaining[closeRange.upperBound...]
        }

        result += String(remaining)
        return result
    }
}

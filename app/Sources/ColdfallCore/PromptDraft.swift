import Foundation

/// A local scaffold, not an AI rewrite. Never invents context or permissions.
public enum PromptDraft {
    public static func build(goal: String, context: String = "", constraints: String = "",
                             success: String = "") -> String {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trim(goal).isEmpty else { return "" }
        var parts = [trim(goal)]
        for (label, value) in [("Context", context), ("Constraints", constraints),
                               ("What a good result looks like", success)] {
            if !trim(value).isEmpty { parts.append(label + ":\n" + trim(value)) }
        }
        return parts.joined(separator: "\n\n")
    }
}

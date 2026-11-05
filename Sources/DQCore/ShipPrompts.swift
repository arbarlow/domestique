import Foundation

/// The instructions Domestique sends the agent when the user ships from the UI.
/// Each one can be overridden in Settings; `nil` (or blank) means the built-in default.
public enum ShipPromptKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Commit, push the branch and open a pull request.
    case createPR
    /// Commit the remaining changes and push to the existing branch / PR.
    case push
    /// Commit, rebase and push straight to the default branch.
    case trunk

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .createPR: "Open pull request"
        case .push: "Push to pull request"
        case .trunk: "Push to trunk"
        }
    }

    public var summary: String {
        switch self {
        case .createPR: "Sent when you click Create PR"
        case .push: "Sent when you commit & push more work to an open PR"
        case .trunk: "Sent when you ship straight to the default branch"
        }
    }

    /// Placeholders this prompt understands, with what they expand to.
    public var placeholders: [(token: String, meaning: String)] {
        var list: [(String, String)] = [
            ("{base}", "default branch name"),
            ("{branch}", "this workspace's branch"),
        ]
        switch self {
        case .createPR: break
        case .push: list.append(("{pr}", "\" to update PR #12\", or empty"))
        case .trunk: list.append(("{checks}", "the trunk gate checks sentence, or empty"))
        }
        return list
    }

    public var defaultTemplate: String {
        switch self {
        case .createPR:
            """
            Ship this work as a pull request:
            1. Look at `git status` and the diff against origin/{base}. Commit everything that belongs to this change with clear commit message(s). Don't commit secrets, build output or unrelated files.
            2. Push the branch `{branch}` to origin (set upstream).
            3. Open a pull request into the default branch (`{base}`) with `gh pr create`: a concise title, and a description of what changed, why, and how it was tested.
            4. Reply with the PR URL.
            """
        case .push:
            """
            Commit the remaining changes with clear commit message(s) and push `{branch}` to origin{pr}. Don't force-push. Reply with what you pushed.
            """
        case .trunk:
            """
            Ship this work straight to the default branch (`{base}`), trunk-based, with no pull request:
            1. Commit everything that belongs to this change with clear commit message(s). Don't commit secrets, build output or unrelated files.
            2. `git fetch origin && git rebase origin/{base}`; if there are conflicts, resolve them preserving both sides' intent.{checks}
            3. `git push origin HEAD:{base}` (never force). If it's rejected because origin moved, fetch, rebase and retry.
            4. Reply with the commit(s) you pushed.
            """
        }
    }
}

public struct ShipPromptContext: Sendable, Hashable {
    public var base: String
    public var branch: String
    public var prNumber: Int?
    /// Trunk gate commands from the repo config.
    public var checks: [String]

    public init(base: String, branch: String, prNumber: Int? = nil, checks: [String] = []) {
        self.base = base
        self.branch = branch
        self.prNumber = prNumber
        self.checks = checks
    }
}

public enum ShipPrompts {
    /// Fills `{base}`, `{branch}`, `{pr}` and `{checks}` in `template`.
    public static func render(_ template: String, _ ctx: ShipPromptContext) -> String {
        let pr = ctx.prNumber.map { " to update PR #\($0)" } ?? ""
        let checks =
            ctx.checks.isEmpty
            ? ""
            : " Then run these checks and only continue if they pass: \(ctx.checks.map { "`\($0)`" }.joined(separator: ", "))."
        return template
            .replacingOccurrences(of: "{base}", with: ctx.base)
            .replacingOccurrences(of: "{branch}", with: ctx.branch)
            .replacingOccurrences(of: "{pr}", with: pr)
            .replacingOccurrences(of: "{checks}", with: checks)
    }
}

extension AppSettings {
    /// The user's template for `kind`, or the built-in one.
    public func shipPromptTemplate(_ kind: ShipPromptKind) -> String {
        if let custom = shipPrompts?[kind.rawValue], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return kind.defaultTemplate
    }

    /// Stores a custom template; blank or identical to the default clears the override.
    public mutating func setShipPromptTemplate(_ kind: ShipPromptKind, _ text: String?) {
        var map = shipPrompts ?? [:]
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || text == kind.defaultTemplate {
            map[kind.rawValue] = nil
        } else {
            map[kind.rawValue] = text
        }
        shipPrompts = map.isEmpty ? nil : map
    }

    public func isShipPromptCustomized(_ kind: ShipPromptKind) -> Bool {
        shipPrompts?[kind.rawValue] != nil
    }

    public func shipPrompt(_ kind: ShipPromptKind, _ ctx: ShipPromptContext) -> String {
        ShipPrompts.render(shipPromptTemplate(kind), ctx)
    }
}

import DQCore
import Foundation

/// The environment variables a project's sandboxes start with, one list per sandbox provider and
/// project. They're usually secrets, so they live in this Mac's Keychain.
public enum SandboxEnvironmentStore {
    private static let service = "dev.domestique.sandbox-env"

    private static func account(provider: UUID, repo: UUID) -> String {
        "\(provider.uuidString.lowercased()).\(repo.uuidString.lowercased())"
    }

    public static func variables(provider: UUID, repo: UUID) -> [EnvVariable] {
        guard let json = Keychain.read(service: service, account: account(provider: provider, repo: repo)) else { return [] }
        return (try? JSONDecoder().decode([EnvVariable].self, from: Data(json.utf8))) ?? []
    }

    /// An empty list deletes the entry. False if the Keychain refused it.
    @discardableResult
    public static func save(_ variables: [EnvVariable], provider: UUID, repo: UUID) -> Bool {
        let account = account(provider: provider, repo: repo)
        guard !variables.isEmpty else {
            Keychain.delete(service: service, account: account)
            return true
        }
        guard let data = try? JSONEncoder().encode(variables), let json = String(data: data, encoding: .utf8) else { return false }
        return Keychain.write(service: service, account: account, value: json)
    }
}

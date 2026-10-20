import Foundation

extension User {
    func toBasicUser(credentialStore: CredentialStoring) -> ServerCredential {
        if let baseUrl,
           case .found(let credential) = credentialStore.readCredential(baseUrl: baseUrl, username: username ?? "?") {
            return credential
        }
        // Pre-Keychain stores still authenticate until their migration succeeds.
        return .basic(username: username ?? "?", password: password.flatMap { $0.isEmpty ? nil : $0 } ?? "?")
    }
}

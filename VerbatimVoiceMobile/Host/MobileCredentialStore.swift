import Foundation

enum MobileCredentialStore {
    static func load() throws -> String {
        guard let data = try MobileKeychain.read("doubaoCredential", group: MobileKeychain.privateGroup),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ASRProviderError.missingAPIKey("豆包")
        }
        return key
    }
    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n") else { throw MobileStoreError.invalidCredential }
        try MobileKeychain.write(Data(key.utf8), account: "doubaoCredential", group: MobileKeychain.privateGroup)
        guard try load() == key else { throw MobileStoreError.verificationFailed }
    }
    static func importBootstrap() throws {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("totype-bootstrap.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        struct Bootstrap: Decodable { let doubaoCredential: String }
        let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: url))
        try save(bootstrap.doubaoCredential)
        try FileManager.default.removeItem(at: url)
    }
}

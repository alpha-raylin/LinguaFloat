import SwiftUI
import Security

final class Settings: ObservableObject {
    @AppStorage("endpoint") var endpoint = "http://127.0.0.1:11434/v1"
    @AppStorage("model") var model = ""
    @AppStorage("language") var language = "繁體中文"
    @AppStorage("requestTimeout") var requestTimeout = 300.0
    @AppStorage("jsonMode") var jsonMode = JSONMode.automatic
    @AppStorage("herdr") var herdr = "/opt/homebrew/bin/herdr"
    @AppStorage("pane") var pane = ""
    /// Opt-in: put the finished result on the pasteboard without a click. Off by default because it overwrites what the user copied.
    @AppStorage("autoCopy") var autoCopy = false
    @AppStorage("onboarded") var onboarded = false
    /// Where CJK text goes in follow mode (typing Chinese to an agent, say); `language` stays the reading target.
    @AppStorage("secondLanguage") var secondLanguage = "English"
    /// Optional translation-only model (HY-MT, TranslateGemma…) used for translate mode with a plain prompt; correction and notes keep `model`.
    @AppStorage("translationModel") var translationModel = ""
    @AppStorage("follow") var follow = false
    @AppStorage("followExcluded") var followExcluded = ""
    @Published var key = KeyStore.read()
    func saveKey() { KeyStore.write(key) }
}
enum KeyStore {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.linguafloat.prototype", kSecAttrAccount as String: "provider"]
    static func read() -> String {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query; q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

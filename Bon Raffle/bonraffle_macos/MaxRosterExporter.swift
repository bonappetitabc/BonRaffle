import Foundation
import Security

enum MaxConnection {
    #if BON_RAFFLE_PREVIEW
    private static let service = "com.bonraffle.preview.max"
    #elseif BON_RAFFLE_UPDATE_TEST
    private static let service = "com.bonraffle.updatetest.max"
    #else
    private static let service = ProcessInfo.processInfo.environment["BON_RAFFLE_TEST_DATA_DIR"] == nil
        ? "com.bonraffle.app.max" : "com.bonraffle.test.max"
    #endif
    private static let account = "bot-token"

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw MaxExportError.keychain }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw MaxExportError.keychain
        }
    }

    static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MaxExportError.keychain
        }
    }
}

enum MaxExportError: LocalizedError {
    case keychain, invalidResponse, empty, repeatedPage, tooLarge, certificate, invalidHost
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .keychain: return "Не удалось сохранить токен в Связке ключей macOS."
        case .invalidResponse: return "MAX вернул ответ без списка участников."
        case .empty: return "MAX не вернул участников для выгрузки."
        case .repeatedPage: return "MAX повторил страницу списка участников."
        case .tooLarge: return "В списке больше 100 000 участников — предел импорта Bon Raffle."
        case .certificate: return "Не удалось безопасно подключиться к MAX. Проверьте адрес API и рекомендацию по сертификату в настройках."
        case .invalidHost: return "Укажите HTTPS-адрес API на домене max.ru без пути, например platform-api2.max.ru."
        case .http(401): return "Токен MAX недействителен. Проверьте его в настройках."
        case .http(403): return "Бот должен быть администратором этого канала или чата MAX."
        case .http(404): return "Канал или чат MAX с таким chat_id не найден."
        case .http(let code): return "MAX вернул ошибку HTTP \(code). Попробуйте позже."
        }
    }
}

enum MaxRosterExporter {
    static func validatedHost(_ value: String) throws -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host.removeFirst(8) }
        while host.hasSuffix("/") { host.removeLast() }
        if host.isEmpty { return "platform-api.max.ru" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.hasSuffix(".max.ru"), labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 45
            }
        }) else { throw MaxExportError.invalidHost }
        return host
    }

    private struct Row {
        let id: String
        let name: String
        let username: String
        let avatar: String
    }

    static func export(token: String, chatID: Int64, apiHost: String,
                       progress: @escaping @MainActor (Int) -> Void) async throws -> (URL, Int) {
        var rows: [Row] = []
        var userIDs = Set<String>()
        var seenMarkers = Set<String>()
        let host = try validatedHost(apiHost)
        var marker: String?
        repeat {
            var components = URLComponents(string: "https://\(host)/chats/\(chatID)/members")!
            components.queryItems = [URLQueryItem(name: "count", value: "100")]
            if let marker { components.queryItems?.append(URLQueryItem(name: "marker", value: marker)) }
            var request = URLRequest(url: components.url!)
            request.setValue(token, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let data: Data
            let response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: request) }
            catch let error as URLError where error.code == .serverCertificateUntrusted ||
                                             error.code == .secureConnectionFailed {
                guard host == "platform-api2.max.ru" else { throw MaxExportError.certificate }
                components.host = "platform-api.max.ru"
                var fallback = URLRequest(url: components.url!)
                fallback.setValue(token, forHTTPHeaderField: "Authorization")
                fallback.timeoutInterval = 30
                do { (data, response) = try await URLSession.shared.data(for: fallback) }
                catch let retry as URLError where retry.code == .serverCertificateUntrusted ||
                                                   retry.code == .secureConnectionFailed {
                    throw MaxExportError.certificate
                }
            }
            guard let response = response as? HTTPURLResponse else { throw MaxExportError.invalidResponse }
            guard response.statusCode == 200 else { throw MaxExportError.http(response.statusCode) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let members = json["members"] as? [[String: Any]] else {
                throw MaxExportError.invalidResponse
            }
            for member in members {
                if member["is_bot"] as? Bool == true { continue }
                let id = string(member["user_id"])
                guard !id.isEmpty, userIDs.insert(id).inserted else { continue }
                var name = [string(member["first_name"]), string(member["last_name"])]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = string(member["name"]) }
                if name.isEmpty { name = string(member["username"]) }
                if name.isEmpty { name = id }
                rows.append(Row(id: id, name: name, username: string(member["username"]),
                                avatar: string(member["avatar_url"])))
            }
            if rows.count > 100_000 { throw MaxExportError.tooLarge }
            await progress(rows.count)
            marker = json["marker"].flatMap { $0 is NSNull ? nil : string($0) }
            if marker == "" { marker = nil }
            if let marker, !seenMarkers.insert(marker).inserted { throw MaxExportError.repeatedPage }
        } while marker != nil

        guard !rows.isEmpty else { throw MaxExportError.empty }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let file = downloads.appendingPathComponent("BonRaffle-MAX-members-\(stamp.string(from: Date())).csv")
        var csv = "\u{FEFF}user_id,name,username,avatar_url\r\n"
        for row in rows {
            csv += [row.id, row.name, row.username, row.avatar].map(escape).joined(separator: ",") + "\r\n"
        }
        try csv.write(to: file, atomically: true, encoding: .utf8)
        return (file, rows.count)
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

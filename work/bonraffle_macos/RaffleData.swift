import Foundation
import CryptoKit

struct Member: Codable, Identifiable {
    let id: String
    let name: String
    let un: String
    let av: String
}

struct RaffleSettings: Codable {
    var fullScreen = true
    var spinSeconds = 20
    var idleSpeed = 100
    var spinSpeed = 100
    var frameLimit = 0
    var showAvatars = true
    var reduceEffects = false
    var useLiquidGlass: Bool? = nil
    var winnerEffect: String? = nil
    var raffleMode: String? = nil
    var useBackgroundPhoto = true
    var backgroundDim = 55
    var maxChatID: String? = nil
    var maxAPIHost: String? = nil
    var showCountdown: Bool? = nil
    var countdownSeconds: Int? = nil
    var countdownCaption: String? = nil
}

struct WinnerHistory: Codable {
    let listFingerprint: String
    let ids: [String]

    static func fingerprint(for members: [Member]) -> String {
        let data = (try? JSONEncoder().encode(members.map(\.id))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func remaining(_ members: [Member], excluding ids: Set<String>) -> [Member] {
        members.filter { !ids.contains($0.id) }
    }
}

enum RaffleStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = base.appendingPathComponent("Settings", isDirectory: true)
        let previous = base.appendingPathComponent("SofrinoPark", isDirectory: true)
        RaffleStore.importLegacyIfNeeded(from: previous, into: destination)
        return destination
    }()

    static func importLegacyIfNeeded(from previous: URL, into destination: URL) {
        let manager = FileManager.default
        // Import once. A reset must not bring a custom asset back on the next launch.
        if manager.fileExists(atPath: destination.path) { return }
        if manager.fileExists(atPath: previous.path) {
            try? manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
            for name in ["members.json", "settings.json", "appearance.json", "winners.json", "background.custom", "logo.custom", "avatar-placeholder.custom"] {
                let old = previous.appendingPathComponent(name)
                let current = destination.appendingPathComponent(name)
                if manager.fileExists(atPath: old.path) && !manager.fileExists(atPath: current.path) {
                    try? manager.copyItem(at: old, to: current)
                }
            }
        }
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type, fallback: T) -> T {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return fallback }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    static func save<T: Encodable>(_ value: T, as name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(value)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

enum ManualRosterStore {
    static var photoFolder: URL { RaffleStore.folder.appendingPathComponent("manual-avatars", isDirectory: true) }

    static func localPhoto(_ source: String) -> URL? {
        guard let url = URL(string: source), url.isFileURL else { return nil }
        let folder = photoFolder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(folder) && FileManager.default.fileExists(atPath: path) ? url : nil
    }

    static func prepare(_ entries: [Member]) throws -> [Member] {
        guard (0...100_000).contains(entries.count) else {
            throw ImportError.invalid("В списке не может быть больше 100 000 записей.")
        }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        return try entries.map { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ImportError.invalid("У каждой записи должно быть имя или название.") }
            guard entry.id.hasPrefix("manual-"), UUID(uuidString: String(entry.id.dropFirst(7))) != nil else {
                throw ImportError.invalid("Некорректный ID ручной записи.")
            }
            var avatar = ""
            if !entry.av.isEmpty {
                if let existing = localPhoto(entry.av) { avatar = existing.absoluteString }
                else {
                    let source = URL(fileURLWithPath: entry.av).standardizedFileURL
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw ImportError.invalid("Выбранная картинка не найдена.")
                    }
                    let ext = source.pathExtension.lowercased()
                    guard ["png", "jpg", "jpeg", "webp"].contains(ext) else {
                        throw ImportError.invalid("Картинка должна быть PNG, JPG или WebP.")
                    }
                    let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard size <= 5 * 1024 * 1024 else {
                        throw ImportError.invalid("Картинка должна быть меньше 5 МБ.")
                    }
                    let destination = photoFolder.appendingPathComponent(entry.id + "." + ext)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: source, to: destination)
                    avatar = destination.absoluteString
                }
            }
            return Member(id: entry.id, name: name, un: "", av: avatar)
        }
    }

}

struct ManualListProfile: Codable, Identifiable {
    let id: String
    var name: String
    var members: [Member]
    var winnerIds: [String]
}

struct ManualListCatalog: Codable {
    var activeId: String?
    var lists: [ManualListProfile]

    static var empty: ManualListCatalog { ManualListCatalog(activeId: nil, lists: []) }
}

enum ManualListLibrary {
    private static let filename = "manual-lists.json"

    static func load() -> ManualListCatalog {
        if FileManager.default.fileExists(atPath: RaffleStore.folder.appendingPathComponent(filename).path) {
            return RaffleStore.load(filename, as: ManualListCatalog.self, fallback: .empty)
        }
        let legacy = RaffleStore.load("manual-members.json", as: [Member].self, fallback: [])
        guard !legacy.isEmpty else { return .empty }
        let current = RaffleStore.load("members.json", as: [Member].self, fallback: [])
        let isActive = WinnerHistory.fingerprint(for: legacy) == WinnerHistory.fingerprint(for: current)
        let history = RaffleStore.load("winners.json", as: WinnerHistory.self,
                                       fallback: WinnerHistory(listFingerprint: "", ids: []))
        let id = "list-" + UUID().uuidString
        let winnerIds = isActive && history.listFingerprint == WinnerHistory.fingerprint(for: legacy)
            ? history.ids.filter { winnerID in legacy.contains(where: { $0.id == winnerID }) } : []
        let catalog = ManualListCatalog(activeId: isActive ? id : nil,
            lists: [ManualListProfile(id: id, name: "Мой список", members: legacy, winnerIds: winnerIds)])
        try? RaffleStore.save(catalog, as: filename)
        return catalog
    }

    static func prepared(_ catalog: ManualListCatalog) throws -> ManualListCatalog {
        guard catalog.lists.count <= 100 else { throw ImportError.invalid("Можно сохранить не больше 100 своих списков.") }
        var copy = catalog
        var names = Set<String>()
        for index in copy.lists.indices {
            let name = copy.lists[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(name.count), names.insert(name.lowercased()).inserted,
                  copy.lists[index].id.hasPrefix("list-"),
                  UUID(uuidString: String(copy.lists[index].id.dropFirst(5))) != nil else {
                throw ImportError.invalid("Названия списков должны быть разными и не длиннее 80 символов.")
            }
            copy.lists[index].name = name
            copy.lists[index].members = try ManualRosterStore.prepare(copy.lists[index].members)
            let ids = Set(copy.lists[index].members.map(\.id))
            copy.lists[index].winnerIds = Array(Set(copy.lists[index].winnerIds).intersection(ids)).sorted()
        }
        if let activeId = copy.activeId, !copy.lists.contains(where: { $0.id == activeId }) {
            copy.activeId = nil
        }
        return copy
    }

    static func save(_ catalog: ManualListCatalog) throws -> ManualListCatalog {
        let copy = try prepared(catalog)
        try RaffleStore.save(copy, as: filename)
        return copy
    }

    static func deactivate() throws {
        var catalog = load()
        guard catalog.activeId != nil else { return }
        catalog.activeId = nil
        _ = try save(catalog)
    }

    static func recordWinner(_ id: String, in members: [Member]) throws {
        var catalog = load()
        guard let active = catalog.activeId,
              let index = catalog.lists.firstIndex(where: { $0.id == active }),
              WinnerHistory.fingerprint(for: catalog.lists[index].members) == WinnerHistory.fingerprint(for: members),
              !catalog.lists[index].winnerIds.contains(id) else { return }
        catalog.lists[index].winnerIds.append(id)
        _ = try save(catalog)
    }
}

struct Prize: Codable, Identifiable {
    let id: String
    var name: String
    var image: String
    var quantity: Int
    var weight: Int
}

enum PrizeStore {
    static var imageFolder: URL { RaffleStore.folder.appendingPathComponent("prize-images", isDirectory: true) }

    static func localImage(_ source: String) -> URL? {
        guard let url = URL(string: source), url.isFileURL else { return nil }
        let folder = imageFolder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(folder) && FileManager.default.fileExists(atPath: path) ? url : nil
    }

    static func prepare(_ entries: [Prize]) throws -> [Prize] {
        guard entries.count <= 1000 else { throw ImportError.invalid("Можно сохранить не больше 1000 видов призов.") }
        try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        return try entries.map { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...120).contains(name.count), entry.id.hasPrefix("prize-"),
                  UUID(uuidString: String(entry.id.dropFirst(6))) != nil,
                  (0...10_000).contains(entry.quantity), (1...1_000).contains(entry.weight) else {
                throw ImportError.invalid("Название: до 120 символов; количество: 0–10000; вес шанса: 1–1000.")
            }
            var image = ""
            if !entry.image.isEmpty {
                if let existing = localImage(entry.image) { image = existing.absoluteString }
                else {
                    let source = URL(fileURLWithPath: entry.image).standardizedFileURL
                    guard FileManager.default.fileExists(atPath: source.path),
                          ["png", "jpg", "jpeg", "webp"].contains(source.pathExtension.lowercased()),
                          ((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 5 * 1024 * 1024 else {
                        throw ImportError.invalid("Картинка должна быть PNG, JPG или WebP до 5 МБ.")
                    }
                    let destination = imageFolder.appendingPathComponent(entry.id + "." + source.pathExtension.lowercased())
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: source, to: destination)
                    image = destination.absoluteString
                }
            }
            return Prize(id: entry.id, name: name, image: image, quantity: entry.quantity, weight: entry.weight)
        }
    }

    static func draw(_ entries: [Prize]) throws -> Prize {
        let available = entries.filter { $0.quantity > 0 && $0.weight > 0 }
        let total = available.reduce(0) { $0 + $1.weight }
        guard total > 0 else { throw ImportError.invalid("Доступные призы закончились.") }
        var ticket = Int.random(in: 0..<total)
        for prize in available {
            if ticket < prize.weight { return prize }
            ticket -= prize.weight
        }
        throw ImportError.invalid("Не удалось выбрать приз.")
    }
}

struct PrizeListProfile: Codable, Identifiable {
    let id: String
    var name: String
    var prizes: [Prize]
}

struct PrizeListCatalog: Codable {
    var activeId: String?
    var lists: [PrizeListProfile]
    static var empty: PrizeListCatalog { PrizeListCatalog(activeId: nil, lists: []) }
}

enum PrizeListLibrary {
    private static let filename = "prize-lists.json"

    static func load() -> PrizeListCatalog {
        if FileManager.default.fileExists(atPath: RaffleStore.folder.appendingPathComponent(filename).path) {
            return RaffleStore.load(filename, as: PrizeListCatalog.self, fallback: .empty)
        }
        let legacy = RaffleStore.load("prizes.json", as: [Prize].self, fallback: [])
        guard !legacy.isEmpty else { return .empty }
        let id = "prizelist-" + UUID().uuidString
        let catalog = PrizeListCatalog(activeId: id,
            lists: [PrizeListProfile(id: id, name: "Мои призы", prizes: legacy)])
        try? RaffleStore.save(catalog, as: filename)
        return catalog
    }

    static func save(_ catalog: PrizeListCatalog) throws -> PrizeListCatalog {
        guard catalog.lists.count <= 100 else { throw ImportError.invalid("Можно сохранить не больше 100 списков призов.") }
        var copy = catalog
        var names = Set<String>()
        for index in copy.lists.indices {
            let name = copy.lists[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...80).contains(name.count), names.insert(name.lowercased()).inserted,
                  copy.lists[index].id.hasPrefix("prizelist-"),
                  UUID(uuidString: String(copy.lists[index].id.dropFirst(10))) != nil else {
                throw ImportError.invalid("Названия списков призов должны быть разными и не длиннее 80 символов.")
            }
            copy.lists[index].name = name
            copy.lists[index].prizes = try PrizeStore.prepare(copy.lists[index].prizes)
        }
        if let activeId = copy.activeId, !copy.lists.contains(where: { $0.id == activeId }) {
            copy.activeId = nil
        }
        try RaffleStore.save(copy, as: filename)
        return copy
    }
}

enum DemoData {
    private static var marker: URL { RaffleStore.folder.appendingPathComponent("demo-lists.initialized") }
    private static var currentMarker: URL { RaffleStore.folder.appendingPathComponent("demo-lists-v2.initialized") }

    private static func image(_ name: String) throws -> String {
        guard let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: "Demo") else {
            throw ImportError.invalid("Не найдена картинка демонстрационного списка: \(name).")
        }
        return path
    }

    private static func uniqueName(_ proposed: String, among names: [String]) -> String {
        let existing = Set(names.map { $0.lowercased() })
        if !existing.contains(proposed.lowercased()) { return proposed }
        var number = 2
        while existing.contains("\(proposed) (\(number))".lowercased()) { number += 1 }
        return "\(proposed) (\(number))"
    }

    static func seedIfNeeded() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: currentMarker.path) else { return }
        try manager.createDirectory(at: RaffleStore.folder, withIntermediateDirectories: true)
        do {
            var catalog = ManualListLibrary.load()
            func entry(_ name: String, _ picture: String) throws -> Member {
                Member(id: "manual-" + UUID().uuidString, name: name, un: "", av: try image(picture))
            }
            let existing = RaffleStore.load("members.json", as: [Member].self, fallback: [])
            let useNow = existing.isEmpty
            var firstDemoId: String?
            if !catalog.lists.contains(where: { $0.name.caseInsensitiveCompare("Пример · участники") == .orderedSame }) {
            let people = ManualListProfile(id: "list-" + UUID().uuidString,
                name: "Пример · участники", members: [
                    try entry("Алина", "demo-person-1"),
                    try entry("Кирилл", "demo-person-2"),
                    try entry("Марина", "demo-person-3"),
                    try entry("Денис", "demo-person-4")
                ], winnerIds: [])
            catalog.lists.append(people)
            firstDemoId = people.id
            }
            if !catalog.lists.contains(where: { $0.name.caseInsensitiveCompare("Пример · столики") == .orderedSame }) {
            let tables = ManualListProfile(id: "list-" + UUID().uuidString,
                name: "Пример · столики", members: [
                    try entry("Стол № 12", "demo-table"),
                    try entry("Стол № 15", "demo-table")
                ], winnerIds: [])
            catalog.lists.append(tables)
            firstDemoId = firstDemoId ?? tables.id
            }
            if useNow, let firstDemoId { catalog.activeId = firstDemoId }
            let saved = try ManualListLibrary.save(catalog)
            if useNow, let firstDemoId,
               let prepared = saved.lists.first(where: { $0.id == firstDemoId }) {
                try RaffleStore.save(prepared.members, as: "members.json")
                try RaffleStore.save(WinnerHistory(
                    listFingerprint: WinnerHistory.fingerprint(for: prepared.members), ids: []),
                    as: "winners.json")
            }
        }
        do {
            var catalog = PrizeListLibrary.load()
            func gift(_ name: String, _ picture: String, _ quantity: Int, _ weight: Int) throws -> Prize {
                Prize(id: "prize-" + UUID().uuidString, name: name,
                      image: try image(picture), quantity: quantity, weight: weight)
            }
            var firstDemoId: String?
            if !catalog.lists.contains(where: { $0.name.caseInsensitiveCompare("Пример · подарки") == .orderedSame }) {
            let gifts = PrizeListProfile(id: "prizelist-" + UUID().uuidString,
                name: "Пример · подарки", prizes: [
                    try gift("Подарочная карта", "demo-prize-card", 2, 3),
                    try gift("Наушники", "demo-prize-headphones", 1, 1)
                ])
            catalog.lists.append(gifts)
            firstDemoId = gifts.id
            }
            if !catalog.lists.contains(where: { $0.name.caseInsensitiveCompare("Пример · для дома") == .orderedSame }) {
            let home = PrizeListProfile(id: "prizelist-" + UUID().uuidString,
                name: "Пример · для дома", prizes: [
                    try gift("Настольная лампа", "demo-prize-lamp", 1, 2),
                    try gift("Термокружка", "demo-prize-cup", 3, 4)
                ])
            catalog.lists.append(home)
            firstDemoId = firstDemoId ?? home.id
            }
            if catalog.activeId == nil { catalog.activeId = firstDemoId }
            _ = try PrizeListLibrary.save(catalog)
        }
        try "1".write(to: marker, atomically: true, encoding: .utf8)
        try "2".write(to: currentMarker, atomically: true, encoding: .utf8)
    }
}

enum ImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum MemberImporter {
    static func load(_ url: URL) throws -> [Member] {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 25 * 1024 * 1024 { throw ImportError.invalid("Файл больше 25 МБ.") }
        guard url.pathExtension.lowercased() == "csv" else { throw ImportError.invalid("Выберите CSV.") }
        let rows = try readCSV(url)
        guard let header = rows.first else { throw ImportError.invalid("Файл пуст.") }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "") }
        guard let idColumn = normalized.firstIndex(of: "user_id") else {
            throw ImportError.invalid("Нужен столбец user_id.")
        }
        if rows.count > 100_001 { throw ImportError.invalid("В файле больше 100 000 строк.") }
        func column(_ names: [String], _ row: [String]) -> String {
            guard let index = normalized.firstIndex(where: { names.contains($0) }), index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seen = Set<String>()
        var result: [Member] = []
        result.reserveCapacity(rows.count)
        for row in rows.dropFirst() {
            guard idColumn < row.count else { continue }
            let id = row[idColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let name = column(["name", "Имя", "имя"], row)
            result.append(Member(id: id, name: name.isEmpty ? "?" : name,
                                 un: column(["username", "Username", "юзернейм"], row),
                                 av: column(["avatar_url", "Аватар", "аватар"], row)))
        }
        if result.isEmpty { throw ImportError.invalid("В файле нет участников с user_id.") }
        return result
    }

    private static func readCSV(_ url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        let cp1251 = String.Encoding(rawValue: 0x80000507)
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: cp1251) else {
            throw ImportError.invalid("Не удалось прочитать кодировку CSV.")
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        // Swift Character treats CRLF as one grapheme; normalize it before scanning CSV rows.
        let chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
                    field.append("\"")
                    i += 1
                } else { quoted.toggle() }
            } else if char == "," && !quoted {
                row.append(field); field = ""
            } else if (char == "\n" || char == "\r") && !quoted {
                if char == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                if rows.count > 100_001 { throw ImportError.invalid("В файле больше 100 000 строк.") }
            } else { field.append(char) }
            i += 1
        }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        return rows
    }

}

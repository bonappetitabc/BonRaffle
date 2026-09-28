import AppKit
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

private let forest = Color(red: 0.06, green: 0.14, blue: 0.09)
private let gold = Color(red: 0.95, green: 0.82, blue: 0.53)
private var liquidGlassAvailable: Bool {
#if HAS_LIQUID_GLASS
    if #available(macOS 26.0, *) { return true }
#endif
    return false
}

private struct SettingsGlassChrome: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
#if HAS_LIQUID_GLASS
        if #available(macOS 26.0, *), enabled {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else if enabled {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content
        }
#else
        if enabled {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content
        }
#endif
    }
}

private struct ColoredSurface: ViewModifier {
    let color: Color
    let opacity: Double
    let cornerRadius: CGFloat
    let glassEnabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
#if HAS_LIQUID_GLASS
        if #available(macOS 26.0, *), glassEnabled {
            content.glassEffect(.regular.tint(color.opacity(opacity)), in: shape)
                .overlay(shape.stroke(.white.opacity(0.17), lineWidth: 1))
        } else if glassEnabled {
            content.background(color.opacity(opacity * 0.55), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.17), lineWidth: 1))
        } else {
            content.background(color.opacity(opacity), in: shape)
        }
#else
        if glassEnabled {
            content.background(color.opacity(opacity * 0.55), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.17), lineWidth: 1))
        } else {
            content.background(color.opacity(opacity), in: shape)
        }
#endif
    }
}

@MainActor
final class AvatarCache: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var activeCount = 0
    @Published private(set) var waitingCount = 0
    @Published private(set) var sizeBytes: Int64 = 0
    @Published private(set) var revision = 0
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchCompleted = 0
    @Published private(set) var batchFailed = 0
    private let folder = RaffleStore.folder.appendingPathComponent("avatars", isDirectory: true)
    private var requested: Set<String> = []
    private var failed: Set<String> = []
    private var queue: [String] = []
    private var imageOrder: [String] = []
    private var generation = 0
    private var batchGeneration = 0
    private var batchURLs: [String] = []
    private var batchCursor = 0
    private var processedCount = 0
    private var failedCount = 0

    init() { refreshSize() }

    func request(_ source: String) {
        if let url = URL(string: source), url.isFileURL {
            let base = RaffleStore.folder.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            let local = path.hasPrefix(base + "manual-avatars/") || path.hasPrefix(base + "prize-images/")
            if local, images[source] == nil,
               let image = NSImage(contentsOfFile: path) { remember(image, for: source) }
            return
        }
        guard let url = URL(string: source), ["http", "https"].contains(url.scheme ?? ""),
              images[source] == nil, !requested.contains(source), !failed.contains(source) else { return }
        let file = path(for: source)
        if let image = NSImage(contentsOf: file) {
            remember(image, for: source)
            return
        }
        requested.insert(source)
        queue.append(source)
        waitingCount = queue.count
        pump()
    }

    private func pump() {
        while activeCount < 4 && !queue.isEmpty {
            let source = queue.removeFirst()
            waitingCount = queue.count
            guard let url = URL(string: source) else { continue }
            let currentGeneration = generation
            activeCount += 1
            Task {
                defer {
                    activeCount -= 1
                    if currentGeneration == generation { requested.remove(source) }
                    pump()
                }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard currentGeneration == generation, data.count <= 3 * 1024 * 1024,
                          let response = response as? HTTPURLResponse,
                          response.statusCode == 200,
                          response.mimeType?.hasPrefix("image/") == true,
                          let image = NSImage(data: data) else { return }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = path(for: source)
                    let existed = FileManager.default.fileExists(atPath: file.path)
                    if !existed { try data.write(to: file, options: .atomic) }
                    remember(image, for: source)
                    if !existed { sizeBytes += Int64(data.count) }
                } catch { failed.insert(source) }
            }
        }
    }

    func clear() {
        generation += 1
        batchGeneration += 1
        batchURLs.removeAll()
        batchCursor = 0
        batchTotal = 0
        batchCompleted = 0
        batchFailed = 0
        processedCount = 0
        failedCount = 0
        revision += 1
        queue.removeAll()
        waitingCount = 0
        requested.removeAll()
        failed.removeAll()
        images.removeAll()
        imageOrder.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        refreshSize()
    }

    func startBatch(_ sources: [String]) {
        batchGeneration += 1
        let current = batchGeneration
        batchURLs = Array(Set(sources.filter {
            guard let url = URL(string: $0) else { return false }
            return ["http", "https"].contains(url.scheme ?? "")
        }))
        batchCursor = 0
        batchTotal = batchURLs.count
        batchCompleted = 0
        batchFailed = 0
        processedCount = 0
        failedCount = 0
        failed.removeAll()
        for _ in 0..<min(3, batchURLs.count) {
            Task { await batchWorker(current) }
        }
    }

    private func batchWorker(_ current: Int) async {
        while current == batchGeneration && batchCursor < batchURLs.count {
            let source = batchURLs[batchCursor]
            batchCursor += 1
            let cacheGeneration = generation
            let succeeded = await fetchBatch(source, cacheGeneration)
            guard current == batchGeneration else { break }
            processedCount += 1
            if !succeeded { failedCount += 1 }
            if processedCount % 20 == 0 || processedCount == batchTotal {
                batchCompleted = processedCount
                batchFailed = failedCount
                await Task.yield()
            }
        }
    }

    private func fetchBatch(_ source: String, _ cacheGeneration: Int) async -> Bool {
        let file = path(for: source)
        if FileManager.default.fileExists(atPath: file.path) { return true }
        guard let url = URL(string: source) else { return false }
        activeCount += 1
        defer { activeCount -= 1 }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard cacheGeneration == generation, data.count <= 3 * 1024 * 1024,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200, response.mimeType?.hasPrefix("image/") == true else { return false }
            if FileManager.default.fileExists(atPath: file.path) { return true }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            sizeBytes += Int64(data.count)
            return true
        } catch { return false }
    }

    private func path(for source: String) -> URL {
        let name = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".img")
    }

    private func remember(_ image: NSImage, for source: String) {
        if images.count >= 256, !imageOrder.isEmpty {
            images.removeValue(forKey: imageOrder.removeFirst())
        }
        imageOrder.append(source)
        images[source] = image
    }

    private func refreshSize() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        sizeBytes = files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

struct RaffleAppearance: Codable {
    var homeCardHex = "#000000"
    var homeCardOpacity = 0.60
    var drumHex = "#000000"
    var drumOpacity = 0.60
    var selectionHex = "#3A6A96"
    var selectionColorVersion = 1
    var winnerCardHex = "#D2691E"
    var winnerCardBorderHex = "#F2D187"
    var countdownRingHex = "#D2691E"
    var winnerCardColorVersion = 1
    var primaryButtonHex = "#D2691E"
    var primaryButtonColorVersion = 1
    var showRemainingHeader = true
    var participantsCaption = "ЕЩЁ МОГУТ ВЫИГРАТЬ"
    var prizesCaption = "ДОСТУПНЫХ ВИДОВ ПРИЗОВ"

    private enum CodingKeys: String, CodingKey {
        case homeCardHex, homeCardOpacity, drumHex, drumOpacity, selectionHex, selectionColorVersion, winnerCardHex, winnerCardBorderHex, countdownRingHex, winnerCardColorVersion, primaryButtonHex, primaryButtonColorVersion, showRemainingHeader, participantsCaption, prizesCaption
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        homeCardHex = try values.decodeIfPresent(String.self, forKey: .homeCardHex) ?? "#000000"
        homeCardOpacity = min(max(try values.decodeIfPresent(Double.self, forKey: .homeCardOpacity) ?? 0.60, 0), 1)
        drumHex = try values.decodeIfPresent(String.self, forKey: .drumHex) ?? "#000000"
        drumOpacity = min(max(try values.decodeIfPresent(Double.self, forKey: .drumOpacity) ?? 0.60, 0), 1)
        let savedSelection = try values.decodeIfPresent(String.self, forKey: .selectionHex) ?? "#D36A1C"
        let savedSelectionVersion = try values.decodeIfPresent(Int.self, forKey: .selectionColorVersion) ?? 0
        selectionHex = savedSelectionVersion == 0 && savedSelection.caseInsensitiveCompare("#D36A1C") == .orderedSame
            ? "#3A6A96" : savedSelection
        selectionColorVersion = 1
        let savedWinnerCard = try values.decodeIfPresent(String.self, forKey: .winnerCardHex) ?? "#4B250E"
        let savedWinnerCardVersion = try values.decodeIfPresent(Int.self, forKey: .winnerCardColorVersion) ?? 0
        winnerCardHex = savedWinnerCardVersion == 0 && savedWinnerCard.caseInsensitiveCompare("#4B250E") == .orderedSame
            ? "#D2691E" : savedWinnerCard
        winnerCardColorVersion = 1
        winnerCardBorderHex = try values.decodeIfPresent(String.self, forKey: .winnerCardBorderHex) ?? "#F2D187"
        countdownRingHex = try values.decodeIfPresent(String.self, forKey: .countdownRingHex) ?? "#D2691E"
        let savedPrimaryButton = try values.decodeIfPresent(String.self, forKey: .primaryButtonHex) ?? "#D36A1C"
        let savedPrimaryButtonVersion = try values.decodeIfPresent(Int.self, forKey: .primaryButtonColorVersion) ?? 0
        primaryButtonHex = savedPrimaryButtonVersion == 0 && savedPrimaryButton.caseInsensitiveCompare("#D36A1C") == .orderedSame
            ? "#D2691E" : savedPrimaryButton
        primaryButtonColorVersion = 1
        showRemainingHeader = try values.decodeIfPresent(Bool.self, forKey: .showRemainingHeader) ?? true
        participantsCaption = Self.caption(try values.decodeIfPresent(String.self, forKey: .participantsCaption), fallback: "ЕЩЁ МОГУТ ВЫИГРАТЬ")
        prizesCaption = Self.caption(try values.decodeIfPresent(String.self, forKey: .prizesCaption), fallback: "ДОСТУПНЫХ ВИДОВ ПРИЗОВ")
    }

    var homeCardColor: Color {
        Self.color(from: homeCardHex, fallback: 0x000000)
    }

    var drumColor: Color {
        Self.color(from: drumHex, fallback: 0x000000)
    }

    var selectionColor: Color {
        Self.color(from: selectionHex, fallback: 0x3A6A96)
    }

    var winnerCardColor: Color {
        Self.color(from: winnerCardHex, fallback: 0xD2691E)
    }

    var winnerCardBorderColor: Color {
        Self.color(from: winnerCardBorderHex, fallback: 0xF2D187)
    }

    var countdownRingColor: Color {
        Self.color(from: countdownRingHex, fallback: 0xD2691E)
    }

    var participantsDisplayCaption: String {
        Self.caption(participantsCaption, fallback: "ЕЩЁ МОГУТ ВЫИГРАТЬ")
    }

    var prizesDisplayCaption: String {
        Self.caption(prizesCaption, fallback: "ДОСТУПНЫХ ВИДОВ ПРИЗОВ")
    }

    private static func caption(_ value: String?, fallback: String) -> String {
        let cleaned = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(200))
    }

    var primaryButtonColor: Color {
        Self.color(from: primaryButtonHex, fallback: 0xD2691E)
    }

    private static func color(from hex: String, fallback: Int) -> Color {
        let rgb = Int(hex.dropFirst(), radix: 16) ?? fallback
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    static func hex(for color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int((converted.redComponent * 255).rounded()),
                      Int((converted.greenComponent * 255).rounded()),
                      Int((converted.blueComponent * 255).rounded()))
    }
}

@MainActor
final class RaffleModel: ObservableObject {
    let updates = AppUpdater()
    let avatarCache = AvatarCache()
    weak var mainWindow: NSWindow?
    enum Screen: Equatable { case home, raffle, winner }
    enum Modal: String, Identifiable, Equatable {
        case settings, help, avatarStatus, manualList, prizes
        var id: String { rawValue }
    }
    struct DrumFrame {
        var index = 0
        var offset: CGFloat = 0
    }
    struct DrumEntry: Identifiable {
        let id: Int
        let member: Member
    }

    @Published var members: [Member] = RaffleStore.load("members.json", as: [Member].self, fallback: [])
    @Published var winnerIDs: Set<String> = []
    @Published var prizeMode = false
    @Published var prizes: [Prize] = []
    @Published var activePrizeName = ""
    private var participantMembers: [Member] = []
    private var participantWinnerIDs: Set<String> = []
    @Published var appearance: RaffleAppearance = RaffleStore.load("appearance.json", as: RaffleAppearance.self, fallback: .init()) {
        didSet {
            do { try RaffleStore.save(appearance, as: "appearance.json") }
            catch { errorMessage = "Не удалось сохранить внешний вид: \(error.localizedDescription)" }
        }
    }
    @Published var settings: RaffleSettings = RaffleStore.load("settings.json", as: RaffleSettings.self, fallback: .init()) {
        didSet {
            do { try RaffleStore.save(settings, as: "settings.json") }
            catch { errorMessage = "Не удалось сохранить настройки: \(error.localizedDescription)" }
            if oldValue.useBackgroundPhoto != settings.useBackgroundPhoto {
                background = Self.readBackground(settings)
            }
        }
    }
    @Published var background: NSImage?
    @Published var logo: NSImage?
    @Published var avatarPlaceholder: NSImage?
    @Published var screen: Screen = .home {
        didSet { if screen == .home { Task { await updates.notifyIfNeeded() } } }
    }
    @Published var modal: Modal?
    @Published var status = "Выберите файл со списком"
    @Published var importing = false
    @Published var maxExporting = false
    @Published var spinning = false
    @Published var winner: Member?
    @Published var drumFrame = DrumFrame()
    @Published var backgroundRevision = 0
    @Published var burstStarted = Date.distantPast
    @Published var selectedWinnerEffect = "balloons"
    @Published var errorMessage: String?

    var visualPool: [Member] = []
    private var visualOverrides: [Int: Member] = [:]
    private var spinStarted = Date.distantPast
    private var spinStartDistance = 0.0
    private var spinEndDistance = 0.0
    private var spinTargetIndex = 0
    private var lastTick = Date()
    private var nextVisualTick = Date.distantPast

    private static let spinTravelArea = 113.4 + 1150.0 * 0.44 + 1150.0 * 0.38 / 2.8

    private static func spinTravelFraction(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        let area: Double
        if t < 0.18 {
            area = 110 * t + 1040 * t * t / (2 * 0.18)
        } else if t < 0.62 {
            area = 113.4 + 1150 * (t - 0.18)
        } else {
            let remainder = (1 - t) / 0.38
            area = 619.4 + 1150 * 0.38 / 2.8 * (1 - pow(remainder, 2.8))
        }
        return area / spinTravelArea
    }

    var remainingCount: Int { members.count - winnerIDs.count }

    init() {
        do { try DemoData.seedIfNeeded() }
        catch { errorMessage = "Не удалось создать демонстрационные списки: \(error.localizedDescription)" }
        members = RaffleStore.load("members.json", as: [Member].self, fallback: [])
        background = Self.readBackground(settings)
        logo = Self.readLogo()
        avatarPlaceholder = Self.readAvatarPlaceholder()
        let saved = RaffleStore.load("winners.json", as: WinnerHistory.self,
                                     fallback: WinnerHistory(listFingerprint: "", ids: []))
        if saved.listFingerprint == WinnerHistory.fingerprint(for: members) {
            let memberIDs = Set(members.map(\.id))
            winnerIDs = Set(saved.ids).intersection(memberIDs)
        }
        let manualCatalog = ManualListLibrary.load()
        if let active = manualCatalog.lists.first(where: { $0.id == manualCatalog.activeId }),
           WinnerHistory.fingerprint(for: active.members) == WinnerHistory.fingerprint(for: members) {
            status = "Свой список «\(active.name)» · \(members.count.formatted()) записей"
        }
        participantMembers = members
        participantWinnerIDs = winnerIDs
        if settings.raffleMode == "prizes" {
            let catalog = PrizeListLibrary.load()
            if let profile = catalog.lists.first(where: { $0.id == catalog.activeId }) {
                prizeMode = true
                prizes = profile.prizes
                activePrizeName = profile.name
                members = Self.prizeMembers(profile.prizes)
                winnerIDs = []
                status = "Список призов «\(profile.name)»"
            }
        }
        if !members.isEmpty { avatarCache.startBatch(members.map(\.av)) }
        updates.canNotify = { [weak self] in self?.screen == .home }
    }

    private static func prizeMembers(_ prizes: [Prize]) -> [Member] {
        prizes.filter { $0.quantity > 0 }.map { prize in
            Member(id: prize.id, name: prize.name, un: "", av: prize.image)
        }
    }

    func activatePrizeList(_ catalog: PrizeListCatalog, id: String) throws {
        var selected = catalog
        selected.activeId = id
        let saved = try PrizeListLibrary.save(selected)
        guard let profile = saved.lists.first(where: { $0.id == id }) else {
            throw ImportError.invalid("Выберите список призов.")
        }
        if !prizeMode { participantMembers = members; participantWinnerIDs = winnerIDs }
        prizeMode = true
        prizes = profile.prizes
        activePrizeName = profile.name
        members = Self.prizeMembers(prizes)
        winnerIDs = []
        winner = nil
        settings.raffleMode = "prizes"
        status = "Список призов «\(profile.name)» · Осталось: \(prizes.reduce(0) { $0 + $1.quantity })"
        screen = .home
        avatarCache.startBatch(members.map(\.av))
    }

    func switchToParticipants() {
        guard prizeMode else { return }
        prizeMode = false
        members = participantMembers
        winnerIDs = participantWinnerIDs
        winner = nil
        settings.raffleMode = "participants"
        status = "Список участников: \(members.count.formatted())"
        screen = .home
        avatarCache.startBatch(members.map(\.av))
    }

    func switchToPrizes() {
        let catalog = PrizeListLibrary.load()
        guard let id = catalog.activeId else { modal = .prizes; return }
        do { try activatePrizeList(catalog, id: id) }
        catch { errorMessage = error.localizedDescription }
    }

    func clearManualListIfCurrent(_ profile: ManualListProfile, wasActive: Bool) throws {
        guard wasActive,
              WinnerHistory.fingerprint(for: profile.members) == WinnerHistory.fingerprint(for: members) else { return }
        try RaffleStore.save([Member](), as: "members.json")
        try RaffleStore.save(WinnerHistory(listFingerprint: "", ids: []), as: "winners.json")
        members = []
        winnerIDs = []
        participantMembers = []
        participantWinnerIDs = []
        status = "Свой список удалён"
        screen = .home
        avatarCache.startBatch([])
    }

    func clearPrizeListIfCurrent(_ profile: PrizeListProfile, wasActive: Bool) {
        guard wasActive else { return }
        if prizeMode && activePrizeName == profile.name { switchToParticipants() }
        prizes = []
        activePrizeName = ""
    }

    func clearCreatedLists() throws {
        let catalog = ManualListLibrary.load()
        let currentParticipants = prizeMode ? participantMembers : members
        let ownActive = catalog.lists.contains {
            $0.id == catalog.activeId &&
            WinnerHistory.fingerprint(for: $0.members) == WinnerHistory.fingerprint(for: currentParticipants)
        }
        if prizeMode { switchToParticipants() }
        let fileManager = FileManager.default
        for name in ["manual-lists.json", "manual-members.json", "prize-lists.json", "prizes.json",
                     "manual-avatars", "prize-images"] {
            let target = RaffleStore.folder.appendingPathComponent(name)
            guard target.deletingLastPathComponent().standardizedFileURL == RaffleStore.folder.standardizedFileURL else {
                throw ImportError.invalid("Некорректный путь данных.")
            }
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        }
        prizes = []
        activePrizeName = ""
        if ownActive {
            members = []
            winnerIDs = []
            participantMembers = []
            participantWinnerIDs = []
            try RaffleStore.save([Member](), as: "members.json")
            try RaffleStore.save(WinnerHistory(listFingerprint: "", ids: []), as: "winners.json")
            status = "Свои списки удалены"
        }
        settings.raffleMode = "participants"
        winner = nil
        screen = .home
        avatarCache.startBatch(members.map(\.av))
    }

    func visibleDrumEntries() -> [DrumEntry] {
        guard !visualPool.isEmpty else { return [] }
        return (0..<6).map { slot in
            let position = drumFrame.index + slot
            return DrumEntry(id: position,
                             member: visualOverrides[position] ?? visualPool[position % visualPool.count])
        }
    }

    func chooseMembers() {
        guard !importing && !maxExporting && !spinning else { return }
        importing = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard response == .OK, let url = panel.url else {
                    self?.importing = false
                    return
                }
                await self?.importFile(url)
            }
        }
    }

    private func importFile(_ url: URL) async {
        importing = true
        defer { importing = false }
        status = "Читаю файл…"
        let task = Task.detached(priority: .userInitiated) { try MemberImporter.load(url) }
        let result = await task.result
        switch result {
        case .success(let imported):
            do {
                try RaffleStore.save(imported, as: "members.json")
                members = imported
                winnerIDs = []
                try RaffleStore.save(WinnerHistory(listFingerprint: WinnerHistory.fingerprint(for: imported), ids: []),
                                     as: "winners.json")
                try ManualListLibrary.deactivate()
                prizeMode = false
                participantMembers = imported
                participantWinnerIDs = []
                settings.raffleMode = "participants"
                status = "Загружено: \(imported.count.formatted()) участников"
                screen = .home
                avatarCache.startBatch(imported.map(\.av))
            } catch { errorMessage = "Не удалось сохранить список: \(error.localizedDescription)" }
        case .failure(let error):
            status = "Выберите файл со списком"
            errorMessage = error.localizedDescription
        }
    }

    func openRaffle() {
        guard !importing && !spinning else { return }
        let remaining = WinnerHistory.remaining(members, excluding: winnerIDs)
        guard !remaining.isEmpty else { return }
        visualPool = Array(remaining.shuffled().prefix(120))
        visualOverrides = [:]
        drumFrame = DrumFrame()
        winner = nil
        spinning = false
        lastTick = Date()
        nextVisualTick = lastTick
        screen = .raffle
    }

    func startSpin() {
        guard !spinning && !importing else { return }
        let remaining = WinnerHistory.remaining(members, excluding: winnerIDs)
        let selected = prizeMode
            ? (try? PrizeStore.draw(prizes)).flatMap { prize in remaining.first(where: { $0.id == prize.id }) }
            : remaining.randomElement()
        guard let selected else {
            errorMessage = prizeMode ? "Доступные призы закончились." : "Все участники уже выиграли. Загрузите новый список."
            return
        }
        winner = selected
        spinStartDistance = Double(drumFrame.index) * 64 + Double(drumFrame.offset)
        let travel = Self.spinTravelArea * Double(settings.spinSeconds) * Double(settings.spinSpeed) / 100
        let rows = max(12, Int(ceil(travel / 64)))
        spinTargetIndex = drumFrame.index + rows
        spinEndDistance = Double(spinTargetIndex) * 64
        visualOverrides[spinTargetIndex + 2] = selected
        spinning = true
        spinStarted = Date()
        lastTick = spinStarted
        nextVisualTick = spinStarted
    }

    func tick(_ now: Date) {
        guard screen == .raffle, !visualPool.isEmpty else { return }
        if !NSApp.isActive || modal != nil {
            if spinning && now.timeIntervalSince(spinStarted) >= Double(settings.spinSeconds) + 0.7 {
                drumFrame = DrumFrame(index: spinTargetIndex, offset: 0)
                finishSpin(now)
            }
            lastTick = now
            nextVisualTick = now
            return
        }

        let screenFPS = min(max(NSApp.keyWindow?.screen?.maximumFramesPerSecond
                                ?? NSScreen.main?.maximumFramesPerSecond ?? 60, 30), 144)
        let desiredFPS = settings.frameLimit == 0 ? screenFPS : min(settings.frameLimit, screenFPS)
        let frameInterval = 1.0 / Double(desiredFPS)
        if now < nextVisualTick { return }
        let late = now.timeIntervalSince(nextVisualTick)
        nextVisualTick = late > 0.25 ? now.addingTimeInterval(frameInterval)
            : nextVisualTick.addingTimeInterval((floor(max(late, 0) / frameInterval) + 1) * frameInterval)
        let delta = min(max(now.timeIntervalSince(lastTick), 0), 0.05)
        lastTick = now
        if spinning {
            let elapsed = now.timeIntervalSince(spinStarted)
            let duration = Double(settings.spinSeconds)
            if elapsed >= duration {
                if drumFrame.index != spinTargetIndex || drumFrame.offset != 0 {
                    drumFrame = DrumFrame(index: spinTargetIndex, offset: 0)
                }
                if elapsed >= duration + 0.7 { finishSpin(now) }
                return
            }
            let distance = spinStartDistance + (spinEndDistance - spinStartDistance) * Self.spinTravelFraction(elapsed / duration)
            let index = Int(distance / 64)
            drumFrame = DrumFrame(index: index, offset: CGFloat(distance - Double(index) * 64))
            return
        }
        let speed = settings.reduceEffects ? 0 : 34 * Double(settings.idleSpeed) / 100
        if speed <= 0 { return }
        var nextFrame = drumFrame
        nextFrame.offset += CGFloat(speed * delta)
        while nextFrame.offset >= 64 {
            nextFrame.offset -= 64
            nextFrame.index += 1
        }
        drumFrame = nextFrame
    }

    private func finishSpin(_ now: Date) {
        spinning = false
        guard let winner else { return }
        do {
            if prizeMode {
                var catalog = PrizeListLibrary.load()
                guard let profileIndex = catalog.lists.firstIndex(where: { $0.id == catalog.activeId }),
                      let prizeIndex = catalog.lists[profileIndex].prizes.firstIndex(where: {
                          $0.id == winner.id && $0.quantity > 0
                      }) else { throw ImportError.invalid("Этот приз уже закончился.") }
                catalog.lists[profileIndex].prizes[prizeIndex].quantity -= 1
                catalog = try PrizeListLibrary.save(catalog)
                prizes = catalog.lists[profileIndex].prizes
                members = Self.prizeMembers(prizes)
                status = "Список призов «\(activePrizeName)» · Осталось: \(prizes.reduce(0) { $0 + $1.quantity })"
            } else {
                var updated = winnerIDs
                updated.insert(winner.id)
                try RaffleStore.save(WinnerHistory(listFingerprint: WinnerHistory.fingerprint(for: members),
                                                   ids: updated.sorted()), as: "winners.json")
                try ManualListLibrary.recordWinner(winner.id, in: members)
                winnerIDs = updated
            }
        } catch {
            self.winner = nil
            errorMessage = "Не удалось сохранить победителя: \(error.localizedDescription)"
            return
        }
        let effect = settings.winnerEffect ?? "balloons"
        selectedWinnerEffect = effect == "random" ? ["balloons", "stars", "sparks"].randomElement()! : effect
        screen = .winner
        burstStarted = now
    }

    func toggleFullScreen() {
        guard let window = mainWindow ?? NSApp.windows.first(where: { $0.title == "Bon Raffle" }) else {
            errorMessage = "Главное окно Bon Raffle не найдено. Откройте его и повторите действие."
            return
        }
        let goFullScreen = !window.styleMask.contains(.fullScreen)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        settings.fullScreen = goFullScreen
    }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try FileManager.default.createDirectory(at: RaffleStore.folder, withIntermediateDirectories: true, attributes: nil)
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024, NSImage(data: data) != nil else {
                    throw ImportError.invalid("Выберите изображение меньше 20 МБ.")
                }
                try data.write(to: RaffleStore.folder.appendingPathComponent("background.custom"), options: .atomic)
                self?.settings.useBackgroundPhoto = true
                if let settings = self?.settings { self?.background = Self.readBackground(settings) }
                self?.backgroundRevision += 1
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func restoreBackground() {
        guard removeCustomAsset("background.custom") else { return }
        settings.useBackgroundPhoto = true
        background = Self.readBackground(settings)
        backgroundRevision += 1
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20 * 1024 * 1024, NSImage(data: data) != nil else {
                    throw ImportError.invalid("Выберите изображение меньше 20 МБ.")
                }
                try FileManager.default.createDirectory(at: RaffleStore.folder, withIntermediateDirectories: true, attributes: nil)
                try data.write(to: RaffleStore.folder.appendingPathComponent("logo.custom"), options: .atomic)
                self?.logo = Self.readLogo()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func restoreLogo() {
        guard removeCustomAsset("logo.custom") else { return }
        logo = Self.readLogo()
    }

    func chooseAvatarPlaceholder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 5 * 1024 * 1024, let image = NSImage(data: data),
                      image.size.width <= 4096, image.size.height <= 4096 else {
                    throw ImportError.invalid("Выберите картинку до 5 МБ и 4096 × 4096 пикселей.")
                }
                try FileManager.default.createDirectory(at: RaffleStore.folder, withIntermediateDirectories: true)
                try data.write(to: RaffleStore.folder.appendingPathComponent("avatar-placeholder.custom"), options: .atomic)
                self?.avatarPlaceholder = Self.readAvatarPlaceholder()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func restoreAvatarPlaceholder() {
        guard removeCustomAsset("avatar-placeholder.custom") else { return }
        avatarPlaceholder = Self.readAvatarPlaceholder()
    }

    func saveMaxConnection(chatID: String, token: String, apiHost: String) throws {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.isEmpty || Int64(id) != nil else {
            throw NSError(domain: "BonRaffle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "chat_id MAX должен быть целым числом."])
        }
        let host = try MaxRosterExporter.validatedHost(apiHost)
        if !token.isEmpty { try MaxConnection.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines)) }
        settings.maxChatID = id
        settings.maxAPIHost = host
    }

    func exportMaxRoster() async {
        guard !maxExporting && !importing && !spinning else { return }
        guard let idText = settings.maxChatID, let chatID = Int64(idText),
              let token = MaxConnection.loadToken(), !token.isEmpty else {
            errorMessage = "Укажите токен бота и chat_id в разделе «Настройки» → «Данные»."
            return
        }
        maxExporting = true
        status = "Получаю участников из MAX…"
        defer { maxExporting = false }
        do {
            let (url, count) = try await MaxRosterExporter.export(token: token, chatID: chatID,
                apiHost: settings.maxAPIHost ?? "platform-api.max.ru") { [weak self] received in
                    self?.status = "Получено из MAX: \(received.formatted()) участников…"
                }
            status = "CSV сохранён в «Загрузки»: \(count.formatted()) участников. Теперь загрузите этот файл."
            let result = NSAlert()
            result.messageText = "Выгрузка MAX готова"
            result.informativeText = "Сохранено \(count.formatted()) участников в файл:\n\(url.path)\n\nЗагрузите этот CSV кнопкой «Загрузить участников»."
            result.addButton(withTitle: "Открыть Загрузки")
            result.addButton(withTitle: "Закрыть")
            if result.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            status = "Выберите файл со списком"
            errorMessage = "Не удалось выгрузить участников MAX: \(error.localizedDescription)"
        }
    }

    func activateManualRoster(_ catalog: ManualListCatalog, id: String) throws {
        var selected = catalog
        selected.activeId = id
        let saved = try ManualListLibrary.save(selected)
        guard let profile = saved.lists.first(where: { $0.id == id }), !profile.members.isEmpty else {
            throw ImportError.invalid("Добавьте хотя бы одну запись в выбранный список.")
        }
        try RaffleStore.save(profile.members, as: "members.json")
        try RaffleStore.save(WinnerHistory(listFingerprint: WinnerHistory.fingerprint(for: profile.members),
                                           ids: profile.winnerIds),
                             as: "winners.json")
        members = profile.members
        winnerIDs = Set(profile.winnerIds)
        participantMembers = profile.members
        participantWinnerIDs = winnerIDs
        prizeMode = false
        settings.raffleMode = "participants"
        winner = nil
        screen = .home
        status = "Свой список «\(profile.name)»: \(profile.members.count.formatted()) записей. Данные сохранены в папке Bon Raffle."
        avatarCache.startBatch(profile.members.map(\.av))
    }

    private func removeCustomAsset(_ name: String) -> Bool {
        let url = RaffleStore.folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            errorMessage = "Не удалось восстановить стандартное изображение: \(error.localizedDescription)"
            return false
        }
    }

    func openDataFolder() {
        do {
            try FileManager.default.createDirectory(at: RaffleStore.folder,
                                                    withIntermediateDirectories: true, attributes: nil)
        } catch {
            errorMessage = "Не удалось открыть папку данных: \(error.localizedDescription)"
            return
        }
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                Self.showDataFolderInFinder()
            }
        } else {
            Self.showDataFolderInFinder()
        }
    }

    private static func showDataFolderInFinder() {
        if !NSWorkspace.shared.open(RaffleStore.folder) {
            NSWorkspace.shared.activateFileViewerSelecting([RaffleStore.folder])
        }
    }

    private static func readBackground(_ settings: RaffleSettings) -> NSImage? {
        guard settings.useBackgroundPhoto else { return nil }
        let custom = RaffleStore.folder.appendingPathComponent("background.custom")
        if let image = NSImage(contentsOf: custom) { return image }
        guard let path = Bundle.main.path(forResource: "background-bon-raffle", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static func readLogo() -> NSImage? {
        let custom = RaffleStore.folder.appendingPathComponent("logo.custom")
        if let image = NSImage(contentsOf: custom) { return image }
        guard let path = Bundle.main.path(forResource: "logo-bon-raffle", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static func readAvatarPlaceholder() -> NSImage? {
        let custom = RaffleStore.folder.appendingPathComponent("avatar-placeholder.custom")
        if let image = NSImage(contentsOf: custom) { return image }
        guard let path = Bundle.main.path(forResource: "avatar-placeholder", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

@main
struct BonRaffleApp: App {
    @StateObject private var model = RaffleModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        #if !BON_RAFFLE_UPDATE_TEST
        let defaults = UserDefaults.standard
        let oldID = "ru.fan-fable.bonraffle"
        let currentID = "com.bonraffle.app"
        if let oldValues = defaults.persistentDomain(forName: oldID) {
            var currentValues = defaults.persistentDomain(forName: currentID) ?? [:]
            for (key, value) in oldValues where currentValues[key] == nil {
                currentValues[key] = value
            }
            defaults.setPersistentDomain(currentValues, forName: currentID)
        }
        defaults.removePersistentDomain(forName: oldID)
        #endif
    }

    var body: some Scene {
        WindowGroup("Bon Raffle") {
            MainView(model: model)
                .frame(minWidth: 720, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: .bonRaffleUpdateRequested)) { _ in
                    openWindow(id: "updates")
                }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { openWindow(id: "updates"); model.updates.check() }
            }
            CommandGroup(after: .sidebar) {
                Button("Главная") { model.screen = .home }
                Button(model.appearance.showRemainingHeader
                       ? "Скрыть число участников"
                       : "Показать число участников") {
                    model.appearance.showRemainingHeader.toggle()
                }
                Button("Переключить полный экран") { model.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu("Розыгрыш") {
                Button("Загрузить участников…") { model.chooseMembers() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Справка по приложению…") { model.modal = .help }
            }
        }
        Window("Настройки — Bon Raffle", id: "settings") {
            SettingsView(model: model)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1060, height: 780)
        Window("Обновления — Bon Raffle", id: "updates") {
            ScrollView { AppUpdateView(updater: model.updates).padding(24) }
                .frame(minWidth: 600, minHeight: 420)
        }
        .defaultSize(width: 700, height: 520)
    }
}

private struct MainWindowReader: NSViewRepresentable {
    let attached: (NSWindow) -> Void

    final class ReaderView: NSView {
        var attached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.attached?(window)
            }
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.attached = attached
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.attached = attached
    }
}

private struct MainView: View {
    @ObservedObject var model: RaffleModel
    @Environment(\.openWindow) private var openWindow
    private let timer = Timer.publish(every: 1.0 / 144.0, on: .main, in: .common).autoconnect()
    @State private var countdownRemaining: TimeInterval = 300
    @State private var countdownDeadline: Date?

    private var configuredCountdown: Int { min(max(model.settings.countdownSeconds ?? 300, 60), 86_400) }

    private var countdownText: String {
        let label = (model.settings.countdownCaption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Конкурс начнётся через" : String(label.prefix(200))
    }

    private var countdownClock: String {
        let seconds = Int(ceil(max(countdownRemaining, 0)))
        return seconds >= 3600
            ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func toggleCountdown() {
        if let deadline = countdownDeadline {
            countdownRemaining = max(0, deadline.timeIntervalSinceNow)
            countdownDeadline = nil
        } else {
            if countdownRemaining <= 0 { countdownRemaining = Double(configuredCountdown) }
            countdownDeadline = Date().addingTimeInterval(countdownRemaining)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                forest.ignoresSafeArea()
                if let image = model.background {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().ignoresSafeArea()
                        .id(model.backgroundRevision)
                }
                Color.black.opacity(Double(model.settings.backgroundDim) / 100).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Group {
                        switch model.screen {
                        case .home: home
                        case .raffle: raffle(in: geometry.size)
                        case .winner: winnerView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(20)
                AvatarActivityView(cache: model.avatarCache) { model.modal = .avatarStatus }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { countdownRemaining = Double(configuredCountdown); model.updates.automaticCheck() }
        .onChange(of: model.settings.countdownSeconds) { _, _ in
            countdownDeadline = nil
            countdownRemaining = Double(configuredCountdown)
        }
        .onChange(of: model.settings.showCountdown) { _, enabled in
            if enabled != true {
                countdownDeadline = nil
                countdownRemaining = Double(configuredCountdown)
            }
        }
        .background(MainWindowReader { window in
            model.mainWindow = window
            if model.settings.fullScreen && !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        })
        .sheet(item: $model.modal) { modal in
            switch modal {
            case .settings: SettingsView(model: model)
            case .help: HelpView()
            case .manualList: ManualListView(model: model)
            case .prizes: PrizeRaffleView(model: model)
            case .avatarStatus: AvatarStatusView(cache: model.avatarCache) {
                model.avatarCache.startBatch(model.members.map(\.av))
            }
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        ), actions: {
            Button("ОК") { model.errorMessage = nil }
        }, message: {
            Text(model.errorMessage ?? "")
        })
    }

    private var header: some View {
        HStack {
            if let image = model.logo {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: min(300, image.size.width), height: min(70, image.size.height))
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Главная") { model.screen = .home }
                Button("Настройки") { openWindow(id: "settings") }
            }
            .buttonStyle(.bordered)
            .padding(8)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 20) {
                AppUpdateNotice(updater: model.updates)
                Text("Проведите розыгрыш").font(.system(size: 38, weight: .bold, design: .rounded))
                Text(model.prizeMode
                     ? "Выберите список призов. Вес задаёт шанс, а количество уменьшается после каждого выигрыша."
                     : "Загрузите участников или выберите свой список для розыгрыша.")
                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
                VStack(spacing: 16) {
                    Picker("Режим", selection: Binding(
                        get: { model.prizeMode ? 1 : 0 },
                        set: { $0 == 1 ? model.switchToPrizes() : model.switchToParticipants() }
                    )) {
                        Text("Участники").tag(0)
                        Text("Призы").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Text(model.prizeMode
                         ? "\(model.members.count.formatted()) видов призов"
                         : "\(model.members.count.formatted()) участников")
                        .font(.system(size: 30, weight: .bold))
                    if !model.prizeMode && !model.winnerIDs.isEmpty {
                        Text("Могут выиграть: \(model.remainingCount.formatted()) · Уже выиграли: \(model.winnerIDs.count.formatted())")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if !model.prizeMode && !model.members.isEmpty && model.remainingCount == 0 {
                        Text("Все участники уже выиграли. Загрузите новый список.")
                            .multilineTextAlignment(.center).foregroundStyle(gold)
                    }
                    Text(model.status).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                    if model.importing { ProgressView().controlSize(.large) }
                    if model.maxExporting { ProgressView().controlSize(.large) }
                    if model.prizeMode {
                        Button("Создать или изменить призы") { model.modal = .prizes }
                            .frame(maxWidth: .infinity)
                    } else {
                        Button("Загрузить участников") { model.chooseMembers() }
                            .disabled(model.importing || model.maxExporting).frame(maxWidth: .infinity)
                        Button("Создать свой список") { model.modal = .manualList }
                            .disabled(model.importing).frame(maxWidth: .infinity)
                        Button("Выгрузить участников из MAX") { Task { await model.exportMaxRoster() } }
                            .disabled(model.maxExporting || model.importing)
                            .frame(maxWidth: .infinity)
                        if model.maxExporting { ProgressView("Получение списка MAX…") }
                    }
                    Button(model.prizeMode ? "Открыть розыгрыш призов" : "Открыть розыгрыш") { model.openRaffle() }
                        .disabled(model.remainingCount == 0 || model.importing)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(model.appearance.primaryButtonColor)
                        .modifier(GentleHover(enabled: !model.settings.reduceEffects))
                        .frame(maxWidth: .infinity)
                }
                .padding(28)
                .frame(maxWidth: 560)
                .modifier(ColoredSurface(color: model.appearance.homeCardColor,
                                         opacity: model.appearance.homeCardOpacity,
                                         cornerRadius: 18,
                                         glassEnabled: model.settings.useLiquidGlass ?? true))
            }
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private func raffle(in size: CGSize) -> some View {
        let roomy = size.height >= 850 || ((model.mainWindow?.styleMask.contains(.fullScreen) ?? false) && size.height >= 720)
        let diameter = roomy ? min(156, max(132, min(size.width * 0.14, size.height * 0.19))) : 108.0
        let scale = diameter / 108.0
        return GeometryReader { viewport in
        ScrollView {
        VStack(spacing: 10) {
            if model.settings.showCountdown == true {
                VStack(spacing: 8) {
                    Text(countdownText)
                        .font(.callout).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button(action: toggleCountdown) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.22), lineWidth: 8 * scale)
                            Circle()
                                .trim(from: 0, to: max(0, min(1, countdownRemaining / Double(configuredCountdown))))
                                .stroke(model.appearance.countdownRingColor, style: StrokeStyle(lineWidth: 8 * scale, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 2) {
                                Text(countdownClock).font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                                Text(countdownDeadline == nil ? "Запустить" : "Пауза")
                                    .font(.system(size: 10 * scale))
                            }
                        }
                        .frame(width: diameter, height: diameter)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(countdownRemaining <= 0 ? "Запустить заново" : countdownDeadline == nil ? "Запустить таймер" : "Поставить таймер на паузу")
                }
            }
            if model.appearance.showRemainingHeader {
                VStack(spacing: 4) {
                Text(model.remainingCount.formatted())
                    .font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(gold)
                Text(model.prizeMode ? model.appearance.prizesDisplayCaption : model.appearance.participantsDisplayCaption)
                    .font(.caption).tracking(1.2).multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                }
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.appearance.selectionColor.opacity(0.28 * model.appearance.drumOpacity))
                    .frame(height: 58)
                    .offset(y: 2 * 64)
                VStack(spacing: 0) {
                    ForEach(model.visibleDrumEntries()) { entry in
                        HStack(spacing: 14) {
                            AvatarView(cache: model.avatarCache, member: entry.member, showRemote: model.settings.showAvatars,
                                       fallback: model.avatarPlaceholder, size: 40, isPrize: model.prizeMode)
                            Text(entry.member.name).lineLimit(1).font(.system(size: 17))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 58)
                        .background(Color.black.opacity(0.10 * model.appearance.drumOpacity),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 6)
                    }
                }
                .offset(y: -model.drumFrame.offset)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(model.appearance.selectionColor.opacity(0.9), lineWidth: 2)
                    .frame(height: 58)
                    .offset(y: 2 * 64)
                    .allowsHitTesting(false)
            }
            .frame(width: 440, height: 5 * 64, alignment: .top)
            .clipped()
            .padding(12)
            .modifier(ColoredSurface(color: model.appearance.drumColor,
                                     opacity: model.appearance.drumOpacity,
                                     cornerRadius: 18,
                                     glassEnabled: model.settings.useLiquidGlass ?? true))
            Button(model.spinning ? "Идёт розыгрыш…" : (model.prizeMode ? "Разыграть приз" : "Выбрать победителя")) { model.startSpin() }
                .disabled(model.spinning)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(model.appearance.primaryButtonColor)
                .modifier(GentleHover(enabled: !model.settings.reduceEffects))
                .controlSize(.large)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .frame(minHeight: viewport.size.height, alignment: .center)
        }
        .onReceive(timer) { now in
            model.tick(now)
            if let deadline = countdownDeadline {
                let remaining = max(0, deadline.timeIntervalSince(now))
                if remaining <= 0 {
                    countdownDeadline = nil
                    model.settings.showCountdown = false
                } else if abs(remaining - countdownRemaining) >= 0.05 {
                    countdownRemaining = remaining
                }
            }
        }
        }
    }

    private var winnerView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text(model.prizeMode ? "Выпал приз!" : "Поздравляем с победой!")
                .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(gold)
            ZStack {
                if !model.settings.reduceEffects && model.selectedWinnerEffect == "stars" {
                    WinnerParticles(start: model.burstStarted, kind: "stars")
                        .frame(width: 760, height: 430)
                        .allowsHitTesting(false)
                }
                if let member = model.winner {
                    VStack(spacing: 14) {
                        AvatarView(cache: model.avatarCache, member: member, showRemote: model.settings.showAvatars,
                                   fallback: model.avatarPlaceholder, size: 96, isPrize: model.prizeMode)
                            .padding(5)
                            .overlay(Circle().stroke(gold, lineWidth: 3))
                        Text(member.name)
                            .font(.system(size: 34, weight: .semibold)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 390)
                        if !member.un.isEmpty { Text("@\(member.un)").foregroundStyle(.white.opacity(0.8)) }
                        if !member.id.hasPrefix("manual-") && !member.id.hasPrefix("prize-") {
                            Text("ID: \(member.id)")
                                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(.white.opacity(0.09), in: Capsule())
                            if let position = model.members.firstIndex(where: { $0.id == member.id }) {
                                Text("Позиция в списке: \((position + 1).formatted())")
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                            Button("Скопировать ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(member.id, forType: .string)
                            }
                            .buttonStyle(.bordered).tint(gold)
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 26)
                    .frame(width: 460)
                    .modifier(ColoredSurface(color: model.appearance.winnerCardColor,
                                             opacity: 1,
                                             cornerRadius: 24,
                                             glassEnabled: model.settings.useLiquidGlass ?? true))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(model.appearance.winnerCardBorderColor.opacity(0.85), lineWidth: 2))
                    .shadow(color: gold.opacity(0.30), radius: 22, y: 10)
                    .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 20)))
                }
                if !model.settings.reduceEffects && model.selectedWinnerEffect != "stars" {
                    Group {
                        if model.selectedWinnerEffect == "balloons" {
                            BalloonRise(start: model.burstStarted)
                        } else {
                            WinnerParticles(start: model.burstStarted, kind: model.selectedWinnerEffect)
                        }
                    }
                    .frame(width: 760, height: 430)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 430)
            Spacer(minLength: 0)
            Button(model.remainingCount == 0
                   ? (model.prizeMode ? "Призы закончились" : "Все участники выиграли")
                   : (model.prizeMode ? "Разыграть ещё один приз" : "Провести ещё один розыгрыш")) {
                model.openRaffle()
            }
                .disabled(model.remainingCount == 0)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(model.appearance.primaryButtonColor).controlSize(.large)
                .modifier(GentleHover(enabled: !model.settings.reduceEffects))
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GentleHover: ViewModifier {
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && hovering ? 1.025 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct AvatarActivityView: View {
    @ObservedObject var cache: AvatarCache
    let onTap: () -> Void

    private var progressText: String {
        guard cache.batchTotal > 0 else { return "…" }
        let percent = min(100, Double(cache.batchCompleted) / Double(cache.batchTotal) * 100)
        return cache.batchTotal >= 1000 && cache.batchCompleted < cache.batchTotal
            ? String(format: "%.1f%%", percent)
            : String(format: "%.0f%%", percent)
    }

    var body: some View {
        if cache.batchTotal > cache.batchCompleted || cache.activeCount + cache.waitingCount > 0 {
            Button(action: onTap) {
                ZStack {
                    Circle().fill(.black.opacity(0.72))
                    Circle().stroke(gold.opacity(0.35), lineWidth: 3)
                    if cache.batchTotal > 0 {
                        Circle()
                            .trim(from: 0, to: Double(cache.batchCompleted) / Double(cache.batchTotal))
                            .stroke(gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.28), value: cache.batchCompleted)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(progressText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .help(cache.batchTotal > 0
                  ? "Аватары: \(cache.batchCompleted) из \(cache.batchTotal), осталось \(max(0, cache.batchTotal - cache.batchCompleted))"
                  : "Загрузка аватаров — нажмите для подробностей")
        }
    }
}

private struct AvatarStatusView: View {
    @ObservedObject var cache: AvatarCache
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Загрузка аватаров").font(.title2.bold())
            Text("Кеш: \(ByteCountFormatter.string(fromByteCount: cache.sizeBytes, countStyle: .file))")
            Text("Обработано: \(cache.batchCompleted) из \(cache.batchTotal)")
            Text("Осталось: \(max(0, cache.batchTotal - cache.batchCompleted))")
            Text("Не удалось загрузить: \(cache.batchFailed)")
            Text("Загружаются сейчас: \(cache.activeCount)")
            Text("Розыгрыш можно открыть во время загрузки.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Очистить кеш") { cache.clear() }
                Button("Загрузить заново") { onRetry() }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct AvatarView: View {
    @ObservedObject var cache: AvatarCache
    let member: Member
    let showRemote: Bool
    let fallback: NSImage?
    let size: CGFloat
    let isPrize: Bool

    var body: some View {
        Group {
            if showRemote, let image = cache.images[member.av] {
                Image(nsImage: image).resizable().scaledToFill()
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(showRemote):\(member.av):\(cache.revision)") {
            if showRemote { cache.request(member.av) }
        }
    }

    private var placeholder: some View {
        Group {
            if isPrize {
                Image(systemName: "gift.fill")
                    .resizable().scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(gold)
                    .background(Color(red: 0.12, green: 0.22, blue: 0.33))
            } else if let image = fallback {
                Image(nsImage: image).resizable().scaledToFill()
            } else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(gold) }
        }
    }
}

private struct BalloonRise: View {
    let start: Date
    @State private var active = true
    private let colors: [Color] = [.orange, gold,
                                   Color(red: 0.57, green: 0.75, blue: 0.86),
                                   .white, Color(red: 0.91, green: 0.67, blue: 0.64)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { context, size in
                let age = timeline.date.timeIntervalSince(start)
                guard age >= 0, age < 3.2 else { return }
                for i in 0..<6 {
                    let delay = Double(i) * 0.12
                    let progress = min(max((age - delay) / (2.3 + Double(i % 3) * 0.14), 0), 1)
                    guard progress > 0, progress < 1 else { continue }
                    let side: Double = i.isMultiple(of: 2) ? -1 : 1
                    let x = size.width / 2 + CGFloat(side) * min(size.width * 0.34, 300)
                        + CGFloat(side * (30 + Double(i % 3) * 22) * progress)
                        + CGFloat(sin(progress * .pi * 2 + Double(i)) * 5)
                    let y = size.height * 0.78 - CGFloat((250 + Double(i % 3) * 30) * progress)
                    let ellipse = CGRect(x: x - 14, y: y - 18, width: 28, height: 36)
                    context.opacity = min(1, progress * 9) * min(1, (1 - progress) * 5)
                    context.fill(Path(ellipseIn: ellipse), with: .color(colors[i % colors.count]))
                    context.fill(Path(ellipseIn: CGRect(x: x - 8, y: y - 11, width: 6, height: 11)),
                                 with: .color(.white.opacity(0.32)))
                    var knot = Path()
                    knot.move(to: CGPoint(x: x - 4, y: y + 17))
                    knot.addLine(to: CGPoint(x: x + 4, y: y + 17))
                    knot.addLine(to: CGPoint(x: x, y: y + 24))
                    knot.closeSubpath()
                    context.fill(knot, with: .color(colors[i % colors.count]))
                    var string = Path()
                    string.move(to: CGPoint(x: x, y: y + 24))
                    string.addCurve(to: CGPoint(x: x, y: y + 59),
                                    control1: CGPoint(x: x - 8, y: y + 34),
                                    control2: CGPoint(x: x + 8, y: y + 49))
                    context.stroke(string, with: .color(.white.opacity(0.72)), lineWidth: 1)
                }
            }
        }
        .task(id: start) {
            active = true
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            active = false
        }
    }
}

private struct WinnerParticles: View {
    let start: Date
    let kind: String
    @State private var active = true
    private let confettiColors: [Color] = [.green, .yellow, .purple, .white,
                                          .pink, .cyan, Color(red: 0.28, green: 0.66, blue: 0.24), .orange]
    private let showerColors: [Color] = [.yellow, .orange, .pink, .cyan, .mint, .purple, .white]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { context, size in
                let age = timeline.date.timeIntervalSince(start)
                guard age >= 0, age < 3.2 else { return }
                let shower = kind == "sparks"
                for i in 0..<(shower ? 72 : 108) {
                    let delay = shower ? Double(i % 12) * 0.075 + Double(i / 12) * 0.045
                                       : Double(i % 12) * 0.035
                    let duration = shower ? 1.9 + Double(i % 7) * 0.13
                                          : 2.0 + Double(i % 7) * 0.12
                    let progress = min(max((age - delay) / duration, 0), 1)
                    guard progress > 0, progress < 1 else { continue }
                    let x: CGFloat
                    let y: CGFloat
                    if shower {
                        let cardHalf = min(size.width * 0.28, 210)
                        let position = CGFloat((i * 47) % 101) / 100
                        x = size.width / 2 - cardHalf + 14 + position * (cardHalf * 2 - 28)
                            + CGFloat(sin(Double(i) * 2.37) * 17 * progress)
                        y = size.height * 0.12 - 26 - CGFloat(i % 5) * 10
                            + (size.height * 0.82 + 40) * CGFloat(progress)
                    } else {
                        let scale = min(size.width / 760, size.height / 430)
                        let side: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                        let angle = Double(i * 137 % 360) * .pi / 180
                        let distance = CGFloat(115 + (i % 8) * 24) * scale
                        let cardHalf = min(size.width * 0.28, 210)
                        x = size.width / 2 + side * (cardHalf + 38 * scale)
                            + CGFloat(cos(angle)) * distance * CGFloat(progress)
                        y = size.height * 0.48 + CGFloat((i % 5) - 2) * 5 * scale
                            + (CGFloat(sin(angle)) * distance + 16 * scale) * CGFloat(progress)
                    }
                    context.opacity = min(1, progress * 12) * pow(1 - progress, 1.2)
                    if shower {
                        let radius = CGFloat(2.6 + Double(i % 4))
                        var star = Path()
                        for point in 0..<10 {
                            let a = Double(point) * .pi / 5 - .pi / 2
                            let r = point.isMultiple(of: 2) ? radius : radius * 0.43
                            let p = CGPoint(x: x + CGFloat(cos(a)) * r, y: y + CGFloat(sin(a)) * r)
                            if point == 0 { star.move(to: p) } else { star.addLine(to: p) }
                        }
                        star.closeSubpath()
                        context.fill(star, with: .color(showerColors[i % showerColors.count]))
                    } else {
                        let stripScale = max(0.55, min(size.width / 760, size.height / 430))
                        let halfWidth = CGFloat(2 + i % 3) * stripScale
                        let halfLength = CGFloat(7 + i % 5) * stripScale
                        let angle = Double(i * 53 % 360) * .pi / 180
                            + progress * (i.isMultiple(of: 2) ? Double.pi * 3 : -Double.pi * 3)
                        let cosine = CGFloat(cos(angle))
                        let sine = CGFloat(sin(angle))
                        let corners: [(CGFloat, CGFloat)] = [(-halfWidth, -halfLength),
                                                            (halfWidth, -halfLength),
                                                            (halfWidth, halfLength),
                                                            (-halfWidth, halfLength)]
                        var strip = Path()
                        for (index, corner) in corners.enumerated() {
                            let point = CGPoint(x: x + corner.0 * cosine - corner.1 * sine,
                                                y: y + corner.0 * sine + corner.1 * cosine)
                            if index == 0 { strip.move(to: point) } else { strip.addLine(to: point) }
                        }
                        strip.closeSubpath()
                        context.fill(strip, with: .color(confettiColors[i % confettiColors.count]))
                    }
                }
            }
        }
        .task(id: start) {
            active = true
            do {
                try await Task.sleep(nanoseconds: 3_200_000_000)
                if !Task.isCancelled { active = false }
            } catch { }
        }
    }
}

private struct WinnerEffectPreview: View {
    let kind: String
    @State private var started = Date.distantPast
    @State private var randomKind = "stars"

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35))
                if kind == "balloons" || (kind == "random" && randomKind == "balloons") {
                    BalloonRise(start: started)
                } else {
                    WinnerParticles(start: started, kind: kind == "random" ? randomKind : kind)
                }
            }
            .frame(width: 260, height: 110)
            .clipped()
            Button("Показать пример") {
                if kind == "random" { randomKind = ["balloons", "stars", "sparks"].randomElement()! }
                started = Date()
            }
        }
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Справка · Bon Raffle")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            .padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("О приложении",
                            "Bon Raffle проводит розыгрыши среди участников и разыгрывает призы на мероприятиях, в сообществах и каналах MAX. Можно загрузить готовый файл или создать свои списки с картинками прямо в приложении.")
                    section("Быстрый старт",
                            "Выберите на главной «Участники» или «Призы». Откройте один из четырёх примеров либо загрузите CSV или создайте свой список. Нажмите «Открыть розыгрыш», затем «Выбрать победителя»; после результата можно провести следующий розыгрыш. Клавиша Enter запускает основное действие текущего экрана.")
                    section("Как загрузить участников",
                            "На главной странице нажмите «Загрузить участников» и выберите CSV. Обязательный столбец — user_id. Имя берётся из name, аватар — из avatar_url, если он указан. Новый файл заменяет предыдущий список.")
                    section("Свой список",
                            "На главной нажмите «Создать свой список». Назовите его, добавьте имена или названия и при желании картинки. Можно создать несколько списков, переключаться между ними, переименовывать и удалять. «Сохранить и использовать» сразу выбирает список для барабана. Списки хранятся в папке данных Bon Raffle; CSV в «Загрузках» для них не создаётся. На карточке победителя своего списка ID не показывается.")
                    section("Примеры для первого запуска",
                            "С приложением идут четыре небольших примера: «Пример · участники», «Пример · столики», «Пример · подарки» и «Пример · для дома». Можно сразу открыть барабан и посмотреть розыгрыш. Столики № 12 и № 15 показывают, что записью может быть не только пользователь. Все имена и картинки вымышлены и созданы для Bon Raffle. Примеры можно изменить или удалить как обычные списки; после удаления они не появятся снова.")
                    section("Розыгрыш призов",
                            "На главной выберите режим «Призы», создайте именованный набор и добавьте призы с названиями, картинками, количеством и весом шанса. Сохранение выбирает набор для основного барабана. Вес задаёт относительный шанс среди доступных призов: если веса 1 и 3, шансы 25% и 75%. После выигрыша количество приза уменьшается, а шансы пересчитываются. Наборы можно переключать, переименовывать и удалять; список участников сохраняется отдельно.")
                    section("Выгрузка из MAX",
                            "В «Настройках» → «Данные» введите chat_id канала и токен бота, который назначен администратором. Токен сохраняется в Связке ключей только на этом Mac. На главной нажмите «Выгрузить участников из MAX»: CSV с user_id, именем и ссылкой на аватар появится в «Загрузках». Затем загрузите этот CSV обычной кнопкой. Подключение можно удалить в настройках.")
                    section("Если выгрузка MAX не началась",
                            "Проверьте chat_id, токен и права бота в канале. Адрес API можно посмотреть и изменить в «Настройках» → «Данные». MAX рекомендует добавить сертификат Минцифры в доверенные. Если выгрузка завершилась, но участников нет, проверьте состав канала и повторите запрос. Пошаговый поиск победителя описан во вкладке «Инструкция MAX».")
                    section("Как найти победителя в MAX",
                            "На карточке победителя из MAX показана его позиция в загруженном списке. Откройте участников канала и используйте номер строки как ориентир; сверяйте имя, аватар и соседние записи, особенно если аватара нет. Порядок участников в MAX может измениться, поэтому номер не гарантирует точного совпадения. Внутренний ID полезен для истории розыгрыша, но не служит поиском пользователя в мессенджере.")
                    section("Как провести розыгрыш",
                            "Откройте розыгрыш и нажмите «Выбрать победителя». Победитель случайно выбирается из всех участников загруженного списка, которые ещё не выигрывали. Барабан показывает анимацию выбора и перед объявлением останавливается на выбранном участнике.")
                    section("Повторные победы",
                            "После победы участник исключается из следующих розыгрышей по этому списку. История сохраняется после закрытия приложения. Загрузка нового файла, в том числе того же самого, начинает розыгрыш заново.")
                    section("Внешний вид",
                            "В «Настройках» можно поставить свой фон, логотип и картинку для участников без аватара, вернуть стандартные изображения, настроить цвет и прозрачность карточки на главной, барабана, выбранной строки, карточки победителя и основных кнопок, затемнение, скорость, длительность и частоту анимации. На macOS 26 с подходящим SDK стеклянные панели Liquid Glass можно выключить в разделе «Основное». Там же можно включить полный экран, скрыть аватары или число участников над барабаном. Команда полного экрана есть в меню «Вид».")
                    section("Данные и интернет",
                            "Последний список, свои списки, призы, картинки, история победителей, фон, логотип и настройки хранятся на этом Mac в папке Settings. Её можно открыть через «Настройки» → «Данные». Там же можно удалить все свои списки с картинками после подтверждения. Выгруженные CSV MAX в «Загрузках» останутся. Кеш аватаров очищается отдельно. После импорта аватары скачиваются в фоне; круглый индикатор справа внизу показывает процент и исчезает после завершения.")
                    section("Исходный код и распространение",
                            "Bon Raffle распространяется по лицензии MIT. Приложение можно использовать и передавать дальше при сохранении уведомления об авторских правах и текста лицензии. Автор: bonappetit.abc.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Text("Версия \(version)")
                Spacer()
                Text("© 2026 bonappetit.abc · MIT")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 820, height: 680)
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ details: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline).foregroundStyle(gold)
            Text(details).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ManualListView: View {
    @ObservedObject var model: RaffleModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ManualListCatalog
    @State private var selectedID: String
    @State private var listName: String
    @State private var entries: [Member]
    @State private var name = ""
    @State private var photo = ""
    @State private var editingID: String?
    @State private var message = ""

    init(model: RaffleModel) {
        self.model = model
        var loaded = ManualListLibrary.load()
        if loaded.lists.isEmpty {
            loaded.lists.append(ManualListProfile(id: "list-" + UUID().uuidString,
                                                  name: "Мой список", members: [], winnerIds: []))
        }
        let selected = loaded.lists.first(where: { $0.id == loaded.activeId }) ?? loaded.lists[0]
        _catalog = State(initialValue: loaded)
        _selectedID = State(initialValue: selected.id)
        _listName = State(initialValue: selected.name)
        _entries = State(initialValue: selected.members)
    }

    private func stash(_ id: String) {
        guard let index = catalog.lists.firstIndex(where: { $0.id == id }) else { return }
        catalog.lists[index].name = listName
        catalog.lists[index].members = entries
        let ids = Set(entries.map(\.id))
        catalog.lists[index].winnerIds = catalog.lists[index].winnerIds.filter { ids.contains($0) }
    }

    private func loadSelected(_ id: String) {
        guard let profile = catalog.lists.first(where: { $0.id == id }) else { return }
        listName = profile.name
        entries = profile.members
        name = ""; photo = ""; editingID = nil
        message = ""
    }

    private func createList() {
        stash(selectedID)
        var number = 1
        while catalog.lists.contains(where: { $0.name.localizedCaseInsensitiveCompare("Мой список \(number)") == .orderedSame }) {
            number += 1
        }
        let profile = ManualListProfile(id: "list-" + UUID().uuidString, name: "Мой список \(number)",
                                        members: [], winnerIds: [])
        catalog.lists.append(profile)
        selectedID = profile.id
        loadSelected(profile.id)
    }

    private func deleteSelected() {
        guard catalog.lists.count > 1 else {
            do {
                let removed = catalog.lists[0]
                let wasActive = catalog.activeId == removed.id
                _ = try ManualListLibrary.save(.empty)
                for entry in removed.members {
                    if let image = ManualRosterStore.localPhoto(entry.av) {
                        try FileManager.default.removeItem(at: image)
                    }
                }
                try model.clearManualListIfCurrent(removed, wasActive: wasActive)
                dismiss()
            } catch { message = "Не удалось удалить список: \(error.localizedDescription)" }
            return
        }
        catalog.lists.removeAll { $0.id == selectedID }
        selectedID = catalog.lists[0].id
        loadSelected(selectedID)
    }

    private func restartSelected() {
        stash(selectedID)
        guard let index = catalog.lists.firstIndex(where: { $0.id == selectedID }) else { return }
        catalog.lists[index].winnerIds = []
        message = "Результаты этого списка сброшены. Нажмите «Сохранить и использовать», чтобы начать заново."
    }

    private var previewImage: NSImage? {
        if photo.isEmpty { return model.avatarPlaceholder }
        let path = ManualRosterStore.localPhoto(photo)?.path ?? photo
        return NSImage(contentsOfFile: path) ?? model.avatarPlaceholder
    }

    private func rowImage(_ source: String) -> NSImage? {
        guard !source.isEmpty else { return model.avatarPlaceholder }
        let path = ManualRosterStore.localPhoto(source)?.path ?? source
        return NSImage(contentsOfFile: path) ?? model.avatarPlaceholder
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp"].contains(ext),
                  ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 5 * 1024 * 1024,
                  NSImage(contentsOfFile: url.path) != nil else {
                message = "Выберите PNG, JPG или WebP размером до 5 МБ."
                return
            }
            photo = url.path
            message = ""
        }
    }

    private func addOrUpdate() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { message = "Введите имя или название."; return }
        if let editingID, let index = entries.firstIndex(where: { $0.id == editingID }) {
            entries[index] = Member(id: editingID, name: clean, un: "", av: photo)
        } else {
            entries.append(Member(id: "manual-" + UUID().uuidString, name: clean, un: "", av: photo))
        }
        name = ""
        photo = ""
        editingID = nil
        message = "Записей: \(entries.count.formatted())"
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingID == nil ? "Новая запись" : "Изменить запись")
                .font(.headline)
            Text("Имя человека, название товара или другой вариант.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Имя или название", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                if let image = previewImage {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 54)).foregroundStyle(gold)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(photo.isEmpty ? "Аватар по умолчанию" :
                         (ManualRosterStore.localPhoto(photo)?.lastPathComponent
                          ?? URL(fileURLWithPath: photo).lastPathComponent))
                        .font(.caption).lineLimit(1)
                    Button("Выбрать картинку…") { choosePhoto() }
                    Button("Без картинки") { photo = "" }
                        .disabled(photo.isEmpty)
                }
            }
            Button(editingID == nil ? "Добавить запись" : "Сохранить изменения") { addOrUpdate() }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(model.appearance.primaryButtonColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text("Без картинки используется стандартный аватар Bon Raffle.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 310)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
    }

    private var rosterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Записи").font(.headline)
                Spacer()
                Text(entries.count.formatted())
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.appearance.selectionColor.opacity(0.25), in: Capsule())
            }
            if entries.isEmpty {
                ContentUnavailableView("Список пуст", systemImage: "person.2",
                                       description: Text("Добавьте первую запись слева."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        if let image = rowImage(entry.av) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 38, height: 38).clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 34))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.av.isEmpty ? "Аватар по умолчанию" : "Своя картинка")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button("Изменить") {
                            editingID = entry.id
                            name = entry.name
                            photo = entry.av
                        }
                        Button("Удалить", role: .destructive) {
                            entries.removeAll { $0.id == entry.id }
                            if editingID == entry.id { editingID = nil; name = ""; photo = "" }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Мои списки участников").font(.title2.bold())
            Text("Назовите мероприятие и переключайтесь между своими списками. Каждый список хранится в папке данных Bon Raffle.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Выберите список", selection: Binding(
                    get: { selectedID },
                    set: { newID in
                        stash(selectedID)
                        selectedID = newID
                        loadSelected(newID)
                    }
                )) {
                    ForEach(catalog.lists) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                TextField("Название списка", text: $listName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Новый список") { createList() }
                    Button("Удалить список", role: .destructive) { deleteSelected() }
                    Button("Начать этот список заново") { restartSelected() }
                        .disabled(!(catalog.lists.first(where: { $0.id == selectedID })?.winnerIds.isEmpty == false))
                }
            }
            .padding(16)
            .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
            HStack(alignment: .top, spacing: 16) {
                editorPanel
                rosterPanel
            }
            .frame(maxHeight: .infinity)
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { dismiss() }
                Spacer()
                Button("Сохранить и использовать") {
                    do {
                        var finalEntries = entries
                        let pendingName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pendingName.isEmpty {
                            if let editingID, let index = finalEntries.firstIndex(where: { $0.id == editingID }) {
                                finalEntries[index] = Member(id: editingID, name: pendingName, un: "", av: photo)
                            } else {
                                finalEntries.append(Member(id: "manual-" + UUID().uuidString,
                                                           name: pendingName, un: "", av: photo))
                            }
                        }
                        entries = finalEntries
                        stash(selectedID)
                        try model.activateManualRoster(catalog, id: selectedID)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
                .disabled(entries.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(model.appearance.primaryButtonColor)
            }
        }
        .padding(22)
        .frame(width: 850, height: 720)
    }
}

private struct PrizeRaffleView: View {
    @ObservedObject var model: RaffleModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: PrizeListCatalog
    @State private var selectedID: String
    @State private var listName: String
    @State private var entries: [Prize]
    @State private var name = ""
    @State private var image = ""
    @State private var quantity = 1
    @State private var weight = 1
    @State private var editingID: String?
    @State private var message = ""

    init(model: RaffleModel) {
        self.model = model
        var loaded = PrizeListLibrary.load()
        if loaded.lists.isEmpty {
            loaded.lists.append(PrizeListProfile(id: "prizelist-" + UUID().uuidString,
                                                 name: "Мои призы", prizes: []))
        }
        let selected = loaded.lists.first(where: { $0.id == loaded.activeId }) ?? loaded.lists[0]
        _catalog = State(initialValue: loaded)
        _selectedID = State(initialValue: selected.id)
        _listName = State(initialValue: selected.name)
        _entries = State(initialValue: selected.prizes)
    }

    private func stash(_ id: String) {
        guard let index = catalog.lists.firstIndex(where: { $0.id == id }) else { return }
        catalog.lists[index].name = listName
        catalog.lists[index].prizes = entries
    }

    private func loadSelected(_ id: String) {
        guard let profile = catalog.lists.first(where: { $0.id == id }) else { return }
        listName = profile.name
        entries = profile.prizes
        clearEditor()
        message = ""
    }

    private func createList() {
        stash(selectedID)
        var number = 1
        while catalog.lists.contains(where: { $0.name.localizedCaseInsensitiveCompare("Мои призы \(number)") == .orderedSame }) {
            number += 1
        }
        let profile = PrizeListProfile(id: "prizelist-" + UUID().uuidString,
                                       name: "Мои призы \(number)", prizes: [])
        catalog.lists.append(profile)
        selectedID = profile.id
        loadSelected(profile.id)
    }

    private func deleteSelected() {
        guard catalog.lists.count > 1 else {
            do {
                let removed = catalog.lists[0]
                let wasActive = catalog.activeId == removed.id
                _ = try PrizeListLibrary.save(.empty)
                for prize in removed.prizes {
                    if let image = PrizeStore.localImage(prize.image) {
                        try FileManager.default.removeItem(at: image)
                    }
                }
                model.clearPrizeListIfCurrent(removed, wasActive: wasActive)
                dismiss()
            } catch { message = "Не удалось удалить список: \(error.localizedDescription)" }
            return
        }
        catalog.lists.removeAll { $0.id == selectedID }
        selectedID = catalog.lists[0].id
        loadSelected(selectedID)
    }

    private var totalWeight: Int { entries.filter { $0.quantity > 0 }.reduce(0) { $0 + $1.weight } }

    private func chance(_ prize: Prize) -> String {
        guard prize.quantity > 0, totalWeight > 0 else { return "0%" }
        return (Double(prize.weight) / Double(totalWeight))
            .formatted(.percent.precision(.fractionLength(1)))
    }

    private func prizeImage(_ source: String) -> NSImage? {
        let path = PrizeStore.localImage(source)?.path ?? source
        return NSImage(contentsOfFile: path)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp"].contains(ext),
                  ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 5 * 1024 * 1024,
                  NSImage(contentsOfFile: url.path) != nil else {
                message = "Выберите PNG, JPG или WebP размером до 5 МБ."
                return
            }
            image = url.path
            message = ""
        }
    }

    private func clearEditor() {
        editingID = nil; name = ""; image = ""; quantity = 1; weight = 1
    }

    private func addOrUpdate() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(clean.count) else { message = "Введите название приза до 120 символов."; return }
        if let editingID, let index = entries.firstIndex(where: { $0.id == editingID }) {
            entries[index].name = clean
            entries[index].image = image
            entries[index].quantity = quantity
            entries[index].weight = weight
        } else {
            entries.append(Prize(id: "prize-" + UUID().uuidString, name: clean,
                                 image: image, quantity: quantity, weight: weight))
        }
        clearEditor()
        message = "Призов в списке: \(entries.count.formatted()). Сохраните список или начните розыгрыш."
    }

    private func save() throws {
        let pending = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            guard pending.count <= 120 else { throw ImportError.invalid("Название приза должно быть не длиннее 120 символов.") }
            addOrUpdate()
        }
        stash(selectedID)
        try model.activatePrizeList(catalog, id: selectedID)
        let saved = PrizeListLibrary.load()
        catalog = saved
        entries = saved.lists.first(where: { $0.id == selectedID })?.prizes ?? []
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingID == nil ? "Новый приз" : "Изменить приз").font(.headline)
            Text("Название, картинка и шанс. Количество уменьшается после каждого выигрыша.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Название приза", text: $name).textFieldStyle(.roundedBorder)
            Stepper("Количество: \(quantity)", value: $quantity, in: 0...10_000)
            Stepper("Вес шанса: \(weight)", value: $weight, in: 1...1_000)
            HStack(spacing: 12) {
                if let photo = prizeImage(image) {
                    Image(nsImage: photo).resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 38)).foregroundStyle(gold)
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(image.isEmpty ? "Без картинки" :
                         (PrizeStore.localImage(image)?.lastPathComponent ?? URL(fileURLWithPath: image).lastPathComponent))
                        .font(.caption).lineLimit(1)
                    Button("Выбрать картинку…") { chooseImage() }
                    Button("Без картинки") { image = "" }.disabled(image.isEmpty)
                }
            }
            Button(editingID == nil ? "Добавить приз" : "Сохранить изменения") { addOrUpdate() }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent).tint(model.appearance.primaryButtonColor)
            Button("Новый приз") { clearEditor() }
            Spacer(minLength: 0)
            Text("Вес задаёт относительный шанс, пока приз доступен. Процент справа пересчитывается автоматически.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 310)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
    }

    private var rosterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Что может выпасть").font(.headline)
                Spacer()
                Text(entries.count.formatted()).font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(model.appearance.selectionColor.opacity(0.25), in: Capsule())
            }
            if entries.isEmpty {
                ContentUnavailableView("Пока нет призов", systemImage: "gift",
                                       description: Text("Добавьте первый приз слева."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { prize in
                            HStack(spacing: 10) {
                                if let photo = prizeImage(prize.image) {
                                    Image(nsImage: photo).resizable().scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: 25)).foregroundStyle(gold)
                                        .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(prize.name).lineLimit(1)
                                    Text("Осталось: \(prize.quantity) · Шанс: \(chance(prize)) · Вес: \(prize.weight)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button("Изменить") {
                                    editingID = prize.id; name = prize.name; image = prize.image
                                    quantity = prize.quantity; weight = prize.weight
                                }
                                Button("Удалить", role: .destructive) {
                                    entries.removeAll { $0.id == prize.id }
                                    if editingID == prize.id { clearEditor() }
                                }
                            }
                            .padding(9)
                            .background(model.appearance.selectionColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Мои списки призов").font(.title2.bold())
            Text("Назовите список и переключайтесь между наборами призов. После сохранения выбранный список откроется в барабане.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Выберите список", selection: Binding(
                    get: { selectedID },
                    set: { newID in
                        stash(selectedID)
                        selectedID = newID
                        loadSelected(newID)
                    }
                )) {
                    ForEach(catalog.lists) { profile in Text(profile.name).tag(profile.id) }
                }
                TextField("Название списка", text: $listName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Новый список") { createList() }
                    Button("Удалить список", role: .destructive) { deleteSelected() }
                }
            }
            .padding(16)
            .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
            HStack(alignment: .top, spacing: 16) { editorPanel; rosterPanel }
                .frame(maxHeight: .infinity)
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Закрыть") { dismiss() }
                Spacer()
                Button("Сохранить и использовать") {
                    do { try save(); dismiss() }
                    catch { message = error.localizedDescription }
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(model.appearance.primaryButtonColor)
            }
        }
        .padding(22)
        .frame(width: 900, height: 750)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: RaffleModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedSection = 0
    @State private var maxChatIDInput = ""
    @State private var maxTokenInput = ""
    @State private var maxAPIHostInput = "platform-api.max.ru"
    @State private var maxConnectionMessage = ""
    @State private var showingDeleteListsConfirmation = false

    private func percentSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $selectedSection) {
                Text("Основное").tag(0)
                Text("Розыгрыш").tag(1)
                Text("Внешний вид").tag(2)
                Text("Данные").tag(3)
                Text("Инструкция MAX").tag(4)
                Text("О программе").tag(5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(20)
            .modifier(SettingsGlassChrome(enabled: model.settings.useLiquidGlass ?? true))
            Form {
            if selectedSection == 0 {
            Section("Окно") {
                Toggle("Во весь экран при запуске", isOn: $model.settings.fullScreen)
                Button("Переключить полный экран сейчас") { model.toggleFullScreen() }
            }
            Section("Оформление") {
                Toggle("Стеклянные панели Liquid Glass", isOn: Binding(
                    get: { model.settings.useLiquidGlass ?? true },
                    set: { model.settings.useLiquidGlass = $0 }
                ))
                Text(liquidGlassAvailable
                     ? "Включает системный Liquid Glass на панелях Bon Raffle. Системные кнопки и поля оформляет macOS."
                     : "На этом Mac используется совместимое полупрозрачное оформление. Системный Liquid Glass требует macOS 26 и SDK macOS 26.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            } else if selectedSection == 1 {
            Section("Розыгрыш") {
                Picker("Длительность", selection: $model.settings.spinSeconds) {
                    Text("8 секунд").tag(8)
                    Text("12 секунд").tag(12)
                    Text("20 секунд").tag(20)
                }
                percentSlider("Скорость ожидания", value: Binding(
                    get: { Double(model.settings.idleSpeed) },
                    set: { model.settings.idleSpeed = Int($0) }
                ), in: 0...200)
                percentSlider("Скорость розыгрыша", value: Binding(
                    get: { Double(model.settings.spinSpeed) },
                    set: { model.settings.spinSpeed = Int($0) }
                ), in: 50...200)
                Picker("Частота кадров", selection: $model.settings.frameLimit) {
                    Text("Авто (частота экрана)").tag(0)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                    Text("144 FPS").tag(144)
                }
                Text("Частота ограничивается возможностями экрана.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Показывать аватары", isOn: $model.settings.showAvatars)
                Toggle("Уменьшить эффекты", isOn: $model.settings.reduceEffects)
            }
            Section("Таймер над барабаном") {
                Toggle("Показывать таймер", isOn: Binding(
                    get: { model.settings.showCountdown ?? false },
                    set: { model.settings.showCountdown = $0 }
                ))
                Stepper(value: Binding(
                    get: { min(max((model.settings.countdownSeconds ?? 300) / 60, 1), 1440) },
                    set: { model.settings.countdownSeconds = $0 * 60 }
                ), in: 1...1440) {
                    Text("Длительность: \((model.settings.countdownSeconds ?? 300) / 60) мин")
                }
                TextField("Текст над таймером", text: Binding(
                    get: { model.settings.countdownCaption ?? "Конкурс начнётся через" },
                    set: { model.settings.countdownCaption = String($0.prefix(200)) }
                ))
                ColorPicker("Цвет кольца таймера", selection: Binding(
                    get: { model.appearance.countdownRingColor },
                    set: { model.appearance.countdownRingHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                Text("Подпись — до 200 символов. Нажмите на круг над барабаном, чтобы запустить или приостановить отсчёт. При нуле таймер сразу скроется и выключится.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Анимация победы") {
                Picker("Эффект", selection: Binding(
                    get: { model.settings.winnerEffect ?? "balloons" },
                    set: { model.settings.winnerEffect = $0 }
                )) {
                    Text("Шарики").tag("balloons")
                    Text("Конфетти-салют").tag("stars")
                    Text("Звёздный дождь").tag("sparks")
                    Text("Случайный при каждой победе").tag("random")
                }
                WinnerEffectPreview(kind: model.settings.winnerEffect ?? "balloons")
                Text("В случайном режиме при каждой победе показывается один из трёх эффектов.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            } else if selectedSection == 2 {
            Section("Фон") {
                Toggle("Показывать фото", isOn: $model.settings.useBackgroundPhoto)
                percentSlider("Затемнение", value: Binding(
                    get: { Double(model.settings.backgroundDim) },
                    set: { model.settings.backgroundDim = Int($0) }
                ), in: 30...85)
                HStack {
                    Button("Выбрать фото…") { model.chooseBackground() }
                    Button("Вернуть стандартный фон") { model.restoreBackground() }
                }
            }
            Section("Логотип") {
                Text("Свой логотип показывается в верхней части окна.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Выбрать логотип…") { model.chooseLogo() }
                    Button("Вернуть стандартный логотип") { model.restoreLogo() }
                }
            }
            Section("Аватар без фото") {
                HStack(spacing: 12) {
                    if let image = model.avatarPlaceholder {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(Circle())
                    }
                    Text("Эта картинка показывается, если у участника нет аватара.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Выбрать картинку…") { model.chooseAvatarPlaceholder() }
                    Button("Вернуть стандартную") { model.restoreAvatarPlaceholder() }
                }
            }
            Section("Главная страница") {
                ColorPicker("Цвет карточки", selection: Binding(
                    get: { model.appearance.homeCardColor },
                    set: { model.appearance.homeCardHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                percentSlider("Прозрачность карточки", value: Binding(
                    get: { (1 - model.appearance.homeCardOpacity) * 100 },
                    set: { model.appearance.homeCardOpacity = 1 - $0 / 100 }
                ), in: 0...100)
                Button("Вернуть стандартный вид карточки") {
                    model.appearance.homeCardHex = "#000000"
                    model.appearance.homeCardOpacity = 0.60
                }
            }
            Section("Барабан") {
                Toggle("Показывать число участников над барабаном", isOn: $model.appearance.showRemainingHeader)
                TextField("Подпись над барабаном · участники", text: Binding(
                    get: { model.appearance.participantsCaption },
                    set: { model.appearance.participantsCaption = String($0.prefix(200)) }
                ))
                TextField("Подпись над барабаном · призы", text: Binding(
                    get: { model.appearance.prizesCaption },
                    set: { model.appearance.prizesCaption = String($0.prefix(200)) }
                ))
                Text("До 200 символов. Пустое поле показывает стандартную подпись.")
                    .font(.caption).foregroundStyle(.secondary)
                ColorPicker("Цвет фона барабана", selection: Binding(
                    get: { model.appearance.drumColor },
                    set: { model.appearance.drumHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                ColorPicker("Цвет выбранной строки", selection: Binding(
                    get: { model.appearance.selectionColor },
                    set: { model.appearance.selectionHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                ColorPicker("Цвет карточки победителя", selection: Binding(
                    get: { model.appearance.winnerCardColor },
                    set: { model.appearance.winnerCardHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                ColorPicker("Цвет рамки карточки победителя", selection: Binding(
                    get: { model.appearance.winnerCardBorderColor },
                    set: { model.appearance.winnerCardBorderHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                percentSlider("Прозрачность барабана", value: Binding(
                    get: { (1 - model.appearance.drumOpacity) * 100 },
                    set: { model.appearance.drumOpacity = 1 - $0 / 100 }
                ), in: 0...100)
                Button("Вернуть все стандартные цвета") { model.appearance = RaffleAppearance() }
            }
            Section("Кнопки") {
                ColorPicker("Цвет основных кнопок", selection: Binding(
                    get: { model.appearance.primaryButtonColor },
                    set: { model.appearance.primaryButtonHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                Button("Вернуть оранжевый цвет") { model.appearance.primaryButtonHex = "#D2691E" }
            }
            } else if selectedSection == 3 {
            Section("Выгрузка участников из MAX") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Как подключить MAX").font(.headline)
                    Text("1. Создайте бота в MAX для бизнеса и скопируйте его токен.")
                    Text("2. Добавьте бота администратором канала или группы.")
                    Text("3. Получите chat_id канала или группы через события MAX.")
                    Text("4. Введите chat_id и токен ниже, затем сохраните подключение.")
                    Text("5. На главной нажмите «Выгрузить участников из MAX». CSV появится в «Загрузках» — загрузите его в розыгрыш обычной кнопкой.")
                    Link("Инструкция MAX: как получить chat_id", destination: URL(string: "https://dev.max.ru/docs-api/use-cases/getting-chat-id")!)
                }
                .font(.callout)
                .padding(.vertical, 6)
                TextField("Пример: -123456789 (не настоящий chat_id)", text: $maxChatIDInput)
                SecureField("Пример: сюда вставьте токен бота MAX", text: $maxTokenInput)
                TextField("Адрес API MAX", text: $maxAPIHostInput)
                Text("По умолчанию — platform-api.max.ru. При необходимости измените адрес здесь. MAX рекомендует добавить сертификат Минцифры в доверенные. Токен отправляется выбранному серверу max.ru.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Рекомендация MAX по адресу и сертификату",
                     destination: URL(string: "https://dev.max.ru/docs-api")!)
                Link("Официальный метод API: получение участников",
                     destination: URL(string: "https://dev.max.ru/docs-api/methods/GET/chats/-chatId-/members")!)
                Text("Пустое поле токена оставит ранее сохранённый токен.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Сохранить подключение") {
                        do {
                            try model.saveMaxConnection(chatID: maxChatIDInput, token: maxTokenInput,
                                apiHost: maxAPIHostInput)
                            maxTokenInput = ""
                            maxConnectionMessage = "Подключение сохранено на этом Mac."
                        } catch { maxConnectionMessage = error.localizedDescription }
                    }
                    Button("Удалить подключение MAX") {
                        do {
                            try MaxConnection.deleteToken()
                            maxTokenInput = ""
                            maxChatIDInput = ""
                            maxAPIHostInput = "platform-api.max.ru"
                            model.settings.maxChatID = nil
                            model.settings.maxAPIHost = nil
                            maxConnectionMessage = "Токен и chat_id удалены."
                        } catch { maxConnectionMessage = error.localizedDescription }
                    }
                }
                Button("Открыть Связку ключей") {
                    let paths = ["/System/Applications/Utilities/Keychain Access.app",
                                 "/Applications/Utilities/Keychain Access.app"]
                    let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess")
                        ?? paths.first(where: { FileManager.default.fileExists(atPath: $0) })
                            .map { URL(fileURLWithPath: $0) }
                    if let app, NSWorkspace.shared.open(app) {
                        maxConnectionMessage = "Связка ключей открыта. Ищите com.bonraffle.app.max."
                    } else {
                        maxConnectionMessage = "Не удалось открыть Связку ключей автоматически. Найдите её через поиск macOS. Токен хранится в системной Связке ключей."
                    }
                }
                Text("chat_id лежит в папке данных Bon Raffle; токен — в Связке ключей macOS под именем com.bonraffle.app.max. Удалить его можно кнопкой выше или вручную в Связке ключей.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(maxConnectionMessage.isEmpty
                     ? (MaxConnection.loadToken() == nil ? "Токен ещё не сохранён" : "Токен сохранён в Связке ключей")
                     : maxConnectionMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Данные") {
                Text("Последний загруженный список и настройки хранятся только на этом Mac.")
                AvatarCacheSettingsView(cache: model.avatarCache)
                Button("Удалить все свои списки и картинки", role: .destructive) {
                    showingDeleteListsConfirmation = true
                }
                Button(action: model.openDataFolder) {
                    Label("Открыть папку данных", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            } else if selectedSection == 4 {
                Section("Как провести розыгрыш с участниками MAX") {
                    Text("1. В разделе «Данные» сохраните chat_id канала и токен бота-администратора.")
                    Text("2. На главной нажмите «Выгрузить участников из MAX». CSV сохранится в папке «Загрузки».")
                    Text("3. Загрузите этот CSV кнопкой «Загрузить участников» и проведите розыгрыш.")
                }
                Section("Как найти победителя в MAX") {
                    Text("4. На карточке победителя запомните его позицию в списке. Откройте участников канала MAX и найдите примерно эту строку.")
                    Text("5. Сверьте имя, аватар и соседние записи. Если порядок участников изменился после выгрузки, номер строки может отличаться.")
                    Text("Внутренний ID из CSV нужен приложению для истории розыгрыша; поиск пользователя по нему в MAX не предусмотрен.")
                }
                Link("Официальная инструкция MAX: как получить chat_id",
                     destination: URL(string: "https://dev.max.ru/docs-api/use-cases/getting-chat-id")!)
            } else {
                Section("Bon Raffle") {
                    Text("Bon Raffle проводит розыгрыши среди людей и разыгрывает призы на мероприятиях, в сообществах и каналах MAX.")
                    Text("Участники: загрузите CSV либо создайте свои списки с именами, номерами столиков и картинками. Списки можно переключать, переименовывать и удалять; история победителей сохраняется отдельно.")
                    Text("MAX: подключите бота в разделе «Данные», выгрузите участников в CSV в «Загрузках» и загрузите файл обычной кнопкой. Позиция победителя помогает найти его в канале; сверяйте имя, аватар и соседние записи.")
                    Text("Призы: создавайте наборы с картинками, количеством и весом шанса. После выигрыша количество уменьшается, а шансы пересчитываются.")
                    Text("Для знакомства включены четыре примера: участники, столики и два набора призов. Их можно изменить или удалить.")
                    Text("Свои списки и картинки хранятся на этом Mac в папке данных Bon Raffle. Токен MAX хранится в Связке ключей. Исходный код распространяется по лицензии MIT.")
                    Text("Версия: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    Text("© 2026 bonappetit.abc")
                }
                Section("Обновления") { AppUpdateView(updater: model.updates) }
            }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Готово") { dismissWindow(id: "settings") }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismissWindow(id: "settings") }
        .onAppear {
            maxChatIDInput = model.settings.maxChatID ?? ""
            maxAPIHostInput = model.settings.maxAPIHost ?? "platform-api.max.ru"
        }
        .alert("Удалить созданные списки?", isPresented: $showingDeleteListsConfirmation) {
            Button("Удалить", role: .destructive) {
                do { try model.clearCreatedLists() }
                catch { model.errorMessage = "Не удалось удалить свои списки: \(error.localizedDescription)" }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Будут удалены все свои списки участников и призов, их картинки и история победителей своих списков. Файлы MAX в «Загрузках» и кеш аватаров останутся.")
        }
    }
}

private struct AvatarCacheSettingsView: View {
    @ObservedObject var cache: AvatarCache

    var body: some View {
        Text("Кеш аватаров: \(ByteCountFormatter.string(fromByteCount: cache.sizeBytes, countStyle: .file))")
        Button("Очистить кеш аватаров") { cache.clear() }
    }
}

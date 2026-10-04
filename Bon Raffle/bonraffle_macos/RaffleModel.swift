import AppKit
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RaffleModel: ObservableObject {
    let updates = AppUpdater()
    let avatarCache = AvatarCache()
    weak var mainWindow: NSWindow?
    weak var settingsWindow: NSWindow?
    enum Screen: Equatable { case home, timer, raffle, winner }
    enum Modal: String, Identifiable, Equatable {
        case settings, help, avatarStatus, manualList, prizes
        var id: String { rawValue }
    }
    struct DrumFrame {
        var index = 0
        var offset: CGFloat = 0
    }
    @MainActor
    final class DrumAnimation: ObservableObject {
        @Published var frame = DrumFrame()
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
    // Animation frames only invalidate the drum, not settings or the background.
    let drumAnimation = DrumAnimation()
    private var drumFrame: DrumFrame {
        get { drumAnimation.frame }
        set { drumAnimation.frame = newValue }
    }
    @Published var backgroundRevision = 0
    @Published var burstStarted = Date.distantPast
    @Published var selectedWinnerEffect = "balloons"
    @Published var errorMessage: String?

    var visualPool: [Member] = []

    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
        if let settingsWindow, settingsWindow.parent !== window {
            settingsWindow.parent?.removeChildWindow(settingsWindow)
            window.addChildWindow(settingsWindow, ordered: .above)
        }
    }

    func attachSettingsWindow(_ window: NSWindow) {
        settingsWindow = window
        guard let mainWindow, window !== mainWindow else { return }
        if window.parent !== mainWindow {
            window.parent?.removeChildWindow(window)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            mainWindow.addChildWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
    }
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
        guard !prizeMode else { return }
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
                status = "Загружено из \(url.lastPathComponent): \(imported.count.formatted()) участников"
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
        let remaining = RaffleEngine.remaining(members, excluding: winnerIDs)
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
        let remaining = RaffleEngine.remaining(members, excluding: winnerIDs)
        let selected = prizeMode
            ? (try? RaffleEngine.drawPrize(prizes)).flatMap { prize in remaining.first(where: { $0.id == prize.id }) }
            : RaffleEngine.drawParticipant(remaining)
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
        let eligibleCount = RaffleEngine.remaining(members, excluding: winnerIDs).count
        let prize = prizeMode ? prizes.first(where: { $0.id == winner.id }) : nil
        let record = DrawRecord(timestampUtc: ISO8601DateFormatter().string(from: now),
                                mode: prizeMode ? "prizes" : "participants",
                                listName: prizeMode ? activePrizeName : status,
                                listFingerprint: WinnerHistory.fingerprint(for: members),
                                eligibleCount: eligibleCount,
                                winnerId: winner.id, winnerName: winner.name,
                                chance: prize.map { RaffleEngine.prizeChance(prizes, prize: $0) }
                                    ?? 1.0 / Double(eligibleCount),
                                listPosition: prizeMode || winner.id.hasPrefix("manual-")
                                    ? nil : members.firstIndex(where: { $0.id == winner.id }).map { $0 + 1 })
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
        do { try DrawLog.append(record) }
        catch { errorMessage = "Победитель сохранён, но протокол не обновлён: \(error.localizedDescription)" }
        let effect = settings.winnerEffect ?? "balloons"
        selectedWinnerEffect = effect == "random" ? ["balloons", "stars", "sparks"].randomElement()! : effect
        screen = .winner
        burstStarted = now
    }

    func exportDrawPdf() {
        do {
            guard !(try DrawLog.load()).isEmpty else {
                errorMessage = "Протокол пока пуст. Проведите хотя бы один розыгрыш."
                return
            }
        } catch {
            errorMessage = "Не удалось прочитать протокол: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bon-Raffle-results.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try DrawPdf.save(DrawLog.load(), to: url) }
            catch { self?.errorMessage = "Не удалось экспортировать протокол: \(error.localizedDescription)" }
        }
    }

    func clearDrawLog() {
        do { try DrawLog.clear() }
        catch { errorMessage = "Не удалось очистить историю: \(error.localizedDescription)" }
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

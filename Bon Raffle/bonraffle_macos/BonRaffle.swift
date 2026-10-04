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
            content.background {
                Color.clear
                    .glassEffect(.regular.tint(color.opacity(opacity)), in: shape)
                    .allowsHitTesting(false)
            }
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

private struct CountdownCircleSurface: ViewModifier {
    let glassEnabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
#if HAS_LIQUID_GLASS
        if #available(macOS 26.0, *), glassEnabled {
            content.background {
                Color.clear.glassEffect(.regular, in: Circle()).allowsHitTesting(false)
            }
        } else {
            content.background(Color.black.opacity(0.16), in: Circle())
        }
#else
        content.background(Color.black.opacity(0.16), in: Circle())
#endif
    }
}

private struct DefaultActionWhen: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.defaultAction) }
        else { content }
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
        guard let value else { return fallback }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
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

@main
struct BonRaffleApp: App {
    @NSApplicationDelegateAdaptor(BonRaffleAppDelegate.self) private var appDelegate
    @StateObject private var model = RaffleModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        #if !BON_RAFFLE_UPDATE_TEST && !BON_RAFFLE_PREVIEW
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
        Window("Bon Raffle", id: "main") {
            MainView(model: model, lifecycle: appDelegate)
                .frame(minWidth: 720, minHeight: 620)
                .onAppear {
                    let openMain = openWindow
                    appDelegate.openMainWindow = { openMain(id: "main") }
                }
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
                Button("Главная") { model.screen = .home; appDelegate.showMainWindow() }
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
                .background(MainWindowReader { model.attachSettingsWindow($0) })
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

private struct RaffleDrumView: View {
    @ObservedObject var model: RaffleModel
    @ObservedObject private var animation: RaffleModel.DrumAnimation

    init(model: RaffleModel) {
        self.model = model
        _animation = ObservedObject(wrappedValue: model.drumAnimation)
    }

    var body: some View {
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
            .offset(y: -animation.frame.offset)
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
    }
}

private struct MainView: View {
    @ObservedObject var model: RaffleModel
    let lifecycle: BonRaffleAppDelegate
    @Environment(\.openWindow) private var openWindow
    private let timer = Timer.publish(every: 1.0 / 144.0, on: .main, in: .common).autoconnect()
    @State private var countdownRemaining: TimeInterval = 300
    @State private var countdownDeadline: Date?
    @State private var homeTimerMinutes = 5
    @State private var homeTimerSeconds = 0
    @State private var homeTimerLoaded = false
    @State private var countdownHovered = false
    @State private var modeHovered = false
    @State private var drumHovered = false
    @State private var showingClearResultsConfirmation = false
    @State private var winnerPositionRevealed = false
    @State private var clickerMonitor: Any?

    private var configuredCountdown: Int { min(max(model.settings.countdownSeconds ?? 300, 10), 86_400) }

    private var countdownText: String {
        guard let label = model.settings.countdownCaption else { return "Конкурс начнётся через" }
        return String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    private var countdownClock: String {
        let seconds = Int(ceil(max(countdownRemaining, 0)))
        return seconds >= 3600
            ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var homeTimerDuration: Int? {
        guard (0...1440).contains(homeTimerMinutes), (0...59).contains(homeTimerSeconds) else { return nil }
        let duration = homeTimerMinutes * 60 + homeTimerSeconds
        return (10...86_400).contains(duration) ? duration : nil
    }

    private func saveHomeTimerDuration() {
        guard homeTimerLoaded, let duration = homeTimerDuration,
              model.settings.countdownSeconds != duration else { return }
        model.settings.countdownSeconds = duration
    }

    private func startHomeTimer() {
        guard let duration = homeTimerDuration, model.remainingCount > 0, !model.importing else { return }
        model.settings.countdownSeconds = duration
        countdownRemaining = Double(duration)
        countdownDeadline = Date().addingTimeInterval(Double(duration))
        countdownHovered = false
        model.screen = .timer
    }

    private func toggleCountdown() {
        if let deadline = countdownDeadline {
            countdownRemaining = max(0, deadline.timeIntervalSinceNow)
            countdownDeadline = nil
        } else if countdownRemaining > 0 {
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
                        case .timer: introCountdown(in: geometry.size)
                        case .raffle: raffle()
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
        .onAppear {
            let duration = configuredCountdown
            homeTimerMinutes = duration / 60
            homeTimerSeconds = duration % 60
            countdownRemaining = Double(duration)
            homeTimerLoaded = true
            model.updates.automaticCheck()
            if clickerMonitor == nil {
                clickerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let mainWindow = model.mainWindow, NSApp.keyWindow === mainWindow,
                          model.screen == .raffle, model.modal == nil, !model.spinning,
                          !event.isARepeat,
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                        return event
                    }
                    let editing = NSApp.keyWindow?.firstResponder is NSTextView
                    let forward = event.specialKey == .pageDown ||
                        (!editing && (event.specialKey == .rightArrow ||
                                      event.charactersIgnoringModifiers == " "))
                    guard forward else { return event }
                    model.startSpin()
                    return nil
                }
            }
        }
        .onDisappear {
            if let clickerMonitor { NSEvent.removeMonitor(clickerMonitor) }
            clickerMonitor = nil
        }
        .onChange(of: homeTimerMinutes) { _, _ in saveHomeTimerDuration() }
        .onChange(of: homeTimerSeconds) { _, _ in saveHomeTimerDuration() }
        .onChange(of: model.screen) { oldScreen, newScreen in
            if oldScreen == .timer && newScreen != .timer {
                countdownDeadline = nil
                countdownRemaining = Double(configuredCountdown)
                countdownHovered = false
            }
        }
        .onReceive(timer) { now in
            model.tick(now)
            guard model.screen == .timer, let deadline = countdownDeadline else { return }
            let remaining = max(0, deadline.timeIntervalSince(now))
            if remaining <= 0 {
                countdownRemaining = 0
                countdownDeadline = nil
                if model.remainingCount > 0 { model.openRaffle() }
                else { model.screen = .home }
            } else if abs(remaining - countdownRemaining) >= 1.0 / 60.0 {
                countdownRemaining = remaining
            }
        }
        .background(MainWindowReader { window in
            model.attachMainWindow(window)
            lifecycle.attachMainWindow(window, startFullScreen: model.settings.fullScreen)
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
        .alert("Очистить историю результатов?", isPresented: $showingClearResultsConfirmation) {
            Button("Очистить", role: .destructive) { model.clearDrawLog() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Записи о прошлых победителях будут удалены. Уже выигравшие в текущем списке останутся исключёнными из новых розыгрышей.")
        }
        .onChange(of: model.screen) { _, newScreen in
            if newScreen == .winner { winnerPositionRevealed = false }
        }
        .onChange(of: model.settings.showWinnerPosition ?? false) { _, _ in
            winnerPositionRevealed = false
        }
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
                    .frame(height: 44)
                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        Text("Режим")
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 62, alignment: .leading)
                        HStack(spacing: 3) {
                            modeButton("Участники", selected: !model.prizeMode) {
                                model.switchToParticipants()
                            }
                            modeButton("Призы", selected: model.prizeMode) {
                                model.switchToPrizes()
                            }
                        }
                        .padding(3)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                    }
                    .frame(width: 304)
                    .onHover { modeHovered = $0 }
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
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button("Загрузить участников") { model.chooseMembers() }
                            .disabled(model.importing || model.maxExporting)
                            .controlSize(.small).frame(maxWidth: .infinity)
                        Button("Создать свой список") { model.modal = .manualList }
                            .disabled(model.importing)
                            .controlSize(.small).frame(maxWidth: .infinity)
                        Button("Выгрузить участников из MAX") { Task { await model.exportMaxRoster() } }
                            .disabled(model.maxExporting || model.importing)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        if model.maxExporting { ProgressView("Получение списка MAX…") }
                    }
                    Button("Экспортировать результаты (PDF)") { model.exportDrawPdf() }
                        .controlSize(.small).frame(maxWidth: .infinity)
                    Button("Очистить историю результатов") { showingClearResultsConfirmation = true }
                        .controlSize(.small).frame(maxWidth: .infinity)
                    Toggle("Таймер перед розыгрышем", isOn: Binding(
                        get: { model.settings.showIntroCountdown ?? false },
                        set: { model.settings.showIntroCountdown = $0 }
                    ))
                    .toggleStyle(.switch)
                    .frame(maxWidth: 350)
                    if model.settings.showIntroCountdown == true {
                        VStack(spacing: 12) {
                            HStack(spacing: 18) {
                                homeTimerField("Минуты", value: $homeTimerMinutes, in: 0...1440)
                                homeTimerField("Секунды", value: $homeTimerSeconds, in: 0...59)
                            }
                            Button("Запустить таймер") { startHomeTimer() }
                                .disabled(homeTimerDuration == nil || model.remainingCount == 0 || model.importing)
                                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor,
                                                                     minWidth: 190, minHeight: 38))
                                .modifier(DefaultActionWhen(enabled: true))
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.15)))
                    }
                    Button(model.prizeMode ? "Открыть розыгрыш призов" : "Открыть розыгрыш") { model.openRaffle() }
                        .disabled(model.remainingCount == 0 || model.importing)
                        .modifier(DefaultActionWhen(enabled: model.settings.showIntroCountdown != true))
                        .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor,
                                                             minWidth: 190, minHeight: 38))
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
        .scrollDisabled(modeHovered)
    }

    private func homeTimerField(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                Stepper(title, value: value, in: range).labelsHidden()
            }
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 112, height: 28)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? model.appearance.primaryButtonColor : Color.white.opacity(0.001)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func introCountdown(in size: CGSize) -> some View {
        let diameter = min(440, max(240, min(size.width * 0.6, size.height * 0.59)))
        let progress = max(0, min(1, countdownRemaining / Double(configuredCountdown)))
        return VStack(spacing: 20) {
            if !countdownText.isEmpty {
                Text(countdownText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
            Button(action: toggleCountdown) {
                ZStack {
                    Circle().stroke(.white.opacity(0.24), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(model.appearance.countdownRingColor,
                                style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(countdownClock)
                        .font(.system(size: diameter * 0.18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if countdownHovered {
                        Label(countdownDeadline == nil ? "Продолжить" : "Пауза",
                              systemImage: countdownDeadline == nil ? "play.fill" : "pause.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(model.appearance.primaryButtonColor, in: Capsule())
                            .offset(y: diameter * 0.23)
                    }
                }
                .frame(width: diameter, height: diameter)
                .modifier(CountdownCircleSurface(glassEnabled: liquidGlassAvailable && (model.settings.useLiquidGlass ?? true)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { countdownHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: countdownHovered)
            .accessibilityLabel(countdownDeadline == nil ? "Продолжить таймер" : "Поставить таймер на паузу")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func raffle() -> some View {
        return GeometryReader { viewport in
        ScrollView {
        VStack(spacing: 10) {
            if model.appearance.showRemainingHeader {
                VStack(spacing: 4) {
                Text(model.remainingCount.formatted())
                    .font(.system(size: 42, weight: .bold, design: .rounded)).foregroundStyle(gold)
                let caption = model.prizeMode ? model.appearance.prizesDisplayCaption : model.appearance.participantsDisplayCaption
                if !caption.isEmpty {
                    Text(caption)
                        .font(.caption).tracking(1.2).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                }
            }
            RaffleDrumView(model: model)
                .onHover { drumHovered = $0 }
            Button(model.spinning ? "Идёт розыгрыш…" : (model.prizeMode ? "Разыграть приз" : "Выбрать победителя")) { model.startSpin() }
                .disabled(model.spinning)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor,
                                                     minWidth: 200, minHeight: 38))
                .padding(.top, 102)
        }
        .padding(.top, 110)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .frame(minHeight: viewport.size.height, alignment: .center)
        }
        .scrollDisabled(drumHovered)
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
                            if model.settings.showWinnerPosition == true,
                               let position = model.members.firstIndex(where: { $0.id == member.id }) {
                                Button { winnerPositionRevealed = true } label: {
                                    Text("Позиция в списке: \((position + 1).formatted())")
                                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                                        .blur(radius: winnerPositionRevealed ? 0 : 5)
                                        .overlay {
                                            if !winnerPositionRevealed {
                                                Text("Показать позицию")
                                                    .font(.caption2).foregroundStyle(.white)
                                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                                    .background(.black.opacity(0.65), in: Capsule())
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
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
                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor,
                                                     minWidth: 250, minHeight: 38))
                .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    let color: Color
    var minWidth: CGFloat = 0
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionButtonFace(configuration: configuration, color: color,
                                minWidth: minWidth, minHeight: minHeight)
    }
}

private struct PrimaryActionButtonFace: View {
    let configuration: ButtonStyle.Configuration
    let color: Color
    let minWidth: CGFloat
    let minHeight: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .background(shape.fill(color)
                .brightness(configuration.isPressed ? -0.10 : (hovering ? 0.05 : 0)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
            .focusable(false)
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

private struct CircularAvatarImage: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.14, green: 0.25, blue: 0.38))
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(1.08)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
        ZStack {
            Circle().fill(Color(red: 0.14, green: 0.25, blue: 0.38))
            if showRemote, let image = cache.images[member.av] {
                CircularAvatarImage(image: image, size: size)
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
                CircularAvatarImage(image: image, size: size)
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
                            "Позицию победителя из MAX можно включить в настройках оформления. Откройте участников канала и используйте номер строки как ориентир; сверяйте имя, аватар и соседние записи, особенно если аватара нет. Порядок участников в MAX может измениться, поэтому номер не гарантирует точного совпадения. Внутренний ID полезен для истории розыгрыша, но не служит поиском пользователя в мессенджере.")
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
                Text("© 2026 Bon Raffle · MIT")
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
                    CircularAvatarImage(image: image, size: 64)
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
                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor))
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
                            CircularAvatarImage(image: image, size: 38)
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
                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor))
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

    private func chance(_ prize: Prize) -> String {
        RaffleEngine.prizeChance(entries, prize: prize)
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
                    CircularAvatarImage(image: photo, size: 64)
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
                .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor))
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
                                    CircularAvatarImage(image: photo, size: 44)
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
                    .buttonStyle(PrimaryActionButtonStyle(color: model.appearance.primaryButtonColor))
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
                    get: { liquidGlassAvailable && (model.settings.useLiquidGlass ?? true) },
                    set: { if liquidGlassAvailable { model.settings.useLiquidGlass = $0 } }
                ))
                .disabled(!liquidGlassAvailable)
                Text("Liquid Glass доступен в macOS 26 и новее.")
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
            Section("Таймер перед розыгрышем") {
                TextField("Текст над таймером", text: Binding(
                    get: { model.settings.countdownCaption ?? "Конкурс начнётся через" },
                    set: { model.settings.countdownCaption = String($0.prefix(200)) }
                ))
                ColorPicker("Цвет кольца таймера", selection: Binding(
                    get: { model.appearance.countdownRingColor },
                    set: { model.appearance.countdownRingHex = RaffleAppearance.hex(for: $0) }
                ), supportsOpacity: false)
                Text("Таймер запускается с главной. Пустая подпись скрывается. Нажмите на большой круг, чтобы приостановить или продолжить отсчёт.")
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
                        CircularAvatarImage(image: image, size: 44)
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
                Text("До 200 символов. Пустое поле скрывает подпись.")
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
                Toggle("Показывать позицию на карточке победителя", isOn: Binding(
                    get: { model.settings.showWinnerPosition ?? false },
                    set: { model.settings.showWinnerPosition = $0 }
                ))
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
                    Text("MAX: подключите бота в разделе «Данные», выгрузите участников в CSV в «Загрузках» и загрузите файл обычной кнопкой. Если нужна позиция победителя на карточке, включите её в настройках оформления; сверяйте имя, аватар и соседние записи.")
                    Text("Призы: создавайте наборы с картинками, количеством и весом шанса. После выигрыша количество уменьшается, а шансы пересчитываются.")
                    Text("Для знакомства включены четыре примера: участники, столики и два набора призов. Их можно изменить или удалить.")
                    Text("Свои списки и картинки хранятся на этом Mac в папке данных Bon Raffle. Токен MAX хранится в Связке ключей. Исходный код распространяется по лицензии MIT.")
                    Text("Версия: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    Text("Автор: bonappetit.abc")
                    Text("© 2026 Bon Raffle")
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

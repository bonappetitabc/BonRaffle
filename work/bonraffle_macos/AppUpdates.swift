import Foundation
import CryptoKit

struct UpdateVersion: Comparable, Equatable, Sendable {
    let parts: [Int]
    init?(_ text: String) {
        let values = text.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              values.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = values.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Sendable {
    let version: String
    let notes: String
    let page: URL
    let fileName: String
    let download: URL
    let size: Int64
    let sha256: String
}

enum AppUpdateError: LocalizedError {
    case unavailable, invalidFile, missingDigest
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Не удалось проверить обновления. Проверьте подключение и повторите попытку."
        case .invalidFile: return "Проверка файла не прошла. Скачайте обновление заново."
        case .missingDigest: return "Для файла нет контрольной суммы. Откройте выпуск на GitHub."
        }
    }
}

enum AppUpdateClient {
    static let repository = "https://github.com/bonappetitabc/BonRaffle"
    struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64
        let digest: String?
    }
    struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]
    }

    static func candidate(_ release: GitHubRelease, platform: String = "macos") -> AppRelease? {
        let prefix = platform + "-v"
        guard ["macos", "windows"].contains(platform), !release.draft, !release.prerelease,
              release.tag_name.hasPrefix(prefix) else { return nil }
        let version = String(release.tag_name.dropFirst(prefix.count))
        guard UpdateVersion(version) != nil else { return nil }
        let name = platform == "macos" ? "BonRaffle-macOS15-plus-\(version).dmg" : "Bon-Raffle-Setup-\(version).exe"
        let address = "\(repository)/releases/download/\(release.tag_name)/\(name)"
        guard let asset = release.assets.first(where: {
            $0.name == name && $0.browser_download_url == address && $0.size > 0 && $0.size <= 1_073_741_824
        }) else { return nil }
        let digest = asset.digest ?? ""
        let hash = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)).lowercased() : ""
        let validHash = hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
        return AppRelease(version: version, notes: String((release.body ?? "").prefix(12_000)),
                          page: URL(string: "\(repository)/releases/tag/\(release.tag_name)")!,
                          fileName: name, download: URL(string: address)!, size: asset.size,
                          sha256: validHash ? hash : "")
    }

    static func find(current: String) async throws -> AppRelease? {
        guard let currentVersion = UpdateVersion(current) else { throw AppUpdateError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var latest: AppRelease?
        for page in 1...10 {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/bonappetitabc/BonRaffle/releases?per_page=100&page=\(page)")!)
            request.setValue("BonRaffle/\(current)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw AppUpdateError.unavailable }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            for item in releases {
                guard let candidate = candidate(item), let version = UpdateVersion(candidate.version), version > currentVersion else { continue }
                if latest == nil || version > UpdateVersion(latest!.version)! { latest = candidate }
            }
            if releases.count < 100 { return latest }
        }
        throw AppUpdateError.unavailable
    }

    static func verify(_ file: URL, release: AppRelease) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(size) == release.size, release.sha256.count == 64 else { throw AppUpdateError.invalidFile }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == release.sha256 else { throw AppUpdateError.invalidFile }
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expectedSize: Int64
        let progress: @Sendable (Double) -> Void
        init(size: Int64, progress: @escaping @Sendable (Double) -> Void) { expectedSize = size; self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > expectedSize { downloadTask.cancel(); return }
            progress(min(1, Double(totalBytesWritten) / Double(expectedSize)))
        }
    }

    static func download(_ release: AppRelease, directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard release.sha256.count == 64 else { throw AppUpdateError.missingDigest }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: release.download)
        request.setValue("BonRaffle-Updater", forHTTPHeaderField: "User-Agent")
        let delegate = DownloadProgress(size: release.size, progress: progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.url?.scheme == "https" else { throw AppUpdateError.invalidFile }
        try Task.checkCancellation()
        try await Task.detached { try verify(temporary, release: release) }.value
        try Task.checkCancellation()
        let folder = directory.appendingPathComponent("BonRaffle-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(release.fileName)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }
}

#if BON_RAFFLE_NATIVE
import AppKit
import Combine
import SwiftUI
import UserNotifications

extension Notification.Name { static let bonRaffleUpdateRequested = Notification.Name("BonRaffle.UpdateRequested") }

private final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .bonRaffleUpdateRequested, object: nil)
        }
        completion()
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    private struct Preferences: Codable {
        var automatic = true
        var lastAttempt: Date? = nil
        var systemNotifications: Bool? = nil
        var notifiedVersion: String? = nil
    }
    private var preferences = RaffleStore.load("update-preferences.json", as: Preferences.self, fallback: .init())
    @Published var automatic = true
    @Published var systemNotifications = false
    @Published var requestingNotificationPermission = false
    @Published var release: AppRelease?
    @Published var busy = false
    @Published var downloading = false
    @Published var progress = 0.0
    @Published var status = "Нажмите «Проверить обновления»."
    @Published var downloadedFile: URL?
    private var downloadTask: Task<Void, Never>?
    private let notificationDelegate = UpdateNotificationDelegate()
    var canNotify: () -> Bool = { true }
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.3.1"

    init() {
        automatic = preferences.automatic
        systemNotifications = preferences.systemNotifications ?? false
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }
    func setSystemNotifications(_ value: Bool) {
        guard !busy, !requestingNotificationPermission else { return }
        systemNotifications = value
        requestingNotificationPermission = true
        Task {
            defer { requestingNotificationPermission = false }
            do {
                if value {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                    systemNotifications = granted
                    if !granted { status = "Уведомления запрещены в настройках macOS. Обновления будут показаны в приложении." }
                }
                preferences.systemNotifications = systemNotifications
                try RaffleStore.save(preferences, as: "update-preferences.json")
                await notifyIfNeeded()
            } catch { status = "Не удалось включить системные уведомления. Обновления будут показаны в приложении." }
        }
    }
    func notifyIfNeeded() async {
        guard systemNotifications, canNotify(), let release, preferences.notifiedVersion != release.version else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized, systemNotifications, canNotify(),
              self.release?.version == release.version else { return }
        let content = UNMutableNotificationContent()
        content.title = "Доступна Bon Raffle \(release.version)"
        content.body = "Откройте приложение, чтобы посмотреть изменения и скачать обновление."
        do {
            try await center.add(UNNotificationRequest(identifier: "BonRaffle.Update", content: content, trigger: nil))
            preferences.notifiedVersion = release.version
            try RaffleStore.save(preferences, as: "update-preferences.json")
        } catch { /* The in-app notice remains available. */ }
    }
    func setAutomatic(_ value: Bool) {
        automatic = value
        preferences.automatic = value
        do { try RaffleStore.save(preferences, as: "update-preferences.json") }
        catch { status = "Не удалось сохранить настройку проверки обновлений." }
    }
    func automaticCheck() {
        guard automatic else { return }
        if let last = preferences.lastAttempt, Date().timeIntervalSince(last) >= 0, Date().timeIntervalSince(last) < 86_400 { return }
        check()
    }
    func check() {
        guard !busy else { return }
        busy = true
        status = "Проверяем выпуски GitHub…"
        preferences.lastAttempt = Date()
        Task {
            defer { busy = false }
            do {
                try RaffleStore.save(preferences, as: "update-preferences.json")
                let result = try await AppUpdateClient.find(current: current)
                if result?.version != release?.version { downloadedFile = nil }
                release = result
                status = result.map { "Доступна версия \($0.version)." } ?? "У вас последняя версия для macOS."
                await notifyIfNeeded()
            } catch { status = "Не удалось проверить обновления. Проверьте подключение и повторите попытку." }
        }
    }
    func download() {
        guard !busy, let release else { return }
        busy = true
        downloading = true
        progress = 0
        status = "Скачиваем обновление…"
        downloadTask = Task {
            defer { busy = false; downloading = false; downloadTask = nil }
            do {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                downloadedFile = try await AppUpdateClient.download(release, directory: downloads) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloading else { return }
                        self.progress = value
                        self.status = "Скачивание: \(Int(value * 100))%"
                    }
                }
                status = "DMG скачан и проверен. Откройте образ, закройте Bon Raffle и замените приложение в «Программах»."
            } catch {
                status = Task.isCancelled ? "Загрузка отменена. Можно скачать заново." : "Не удалось скачать или проверить файл. Повторите загрузку либо откройте выпуск на GitHub."
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func openImage() {
        guard !busy, let downloadedFile, let release else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try AppUpdateClient.verify(downloadedFile, release: release) }.value
                if !NSWorkspace.shared.open(downloadedFile) { status = "Не удалось открыть образ. Откройте скачанный DMG через Finder." }
            } catch { self.downloadedFile = nil; status = "Скачанный файл изменился. Скачайте его заново." }
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Обновления · версия \(updater.current)").font(.headline)
            Toggle("Проверять автоматически при запуске", isOn: Binding(get: { updater.automatic }, set: { updater.setAutomatic($0) }))
                .disabled(updater.busy)
            Toggle("Системные уведомления о новой версии", isOn: Binding(get: { updater.systemNotifications }, set: { updater.setSystemNotifications($0) }))
                .disabled(updater.busy || updater.requestingNotificationPermission)
            Text(updater.status)
            if let release = updater.release, !release.notes.isEmpty {
                ScrollView { Text(release.notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 180)
            }
            if updater.downloading { ProgressView(value: updater.progress) }
            HStack {
                Button("Проверить обновления") { updater.check() }.disabled(updater.busy)
                if let release = updater.release, updater.downloadedFile == nil {
                    Button("Скачать обновление") { updater.download() }.disabled(updater.busy || release.sha256.isEmpty)
                }
                if updater.downloading { Button("Отменить загрузку") { updater.cancelDownload() } }
            }
            if updater.downloadedFile != nil {
                Button("Открыть DMG") { updater.openImage() }.disabled(updater.busy)
            }
            Link("Открыть выпуск на GitHub", destination: updater.release?.page ?? URL(string: AppUpdateClient.repository + "/releases")!)
            Text("Проверка при запуске — не чаще раза в сутки. После загрузки откройте DMG, закройте Bon Raffle и перетащите новую версию в «Программы», подтвердив замену. Списки и настройки хранятся отдельно.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppUpdateNotice: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let release = updater.release {
            HStack {
                Text("Доступна Bon Raffle \(release.version)")
                Spacer()
                Button("Посмотреть") { openWindow(id: "updates") }
            }
            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
#endif

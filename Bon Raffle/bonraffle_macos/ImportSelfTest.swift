import Foundation

@main
struct ImportSelfTest {
    static func main() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonraffle-import-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: path) }
        let csv = "user_id,name,username,avatar_url\r\n1,Анна,anna,\r\n2,\"Борис, Петров\",boris,\r\n"
        try Data(csv.utf8).write(to: path)
        let members = try MemberImporter.load(path)
        guard members.count == 2, members[0].id == "1", members[1].name == "Борис, Петров" else {
            throw ImportError.invalid("Проверка CSV с переносами CRLF не прошла.")
        }
        let unsupported = path.deletingPathExtension().appendingPathExtension("xlsx")
        try Data(csv.utf8).write(to: unsupported)
        defer { try? FileManager.default.removeItem(at: unsupported) }
        var rejected = false
        do { _ = try MemberImporter.load(unsupported) }
        catch ImportError.invalid(let message) { rejected = message == "Выберите CSV." }
        catch { throw error }
        guard rejected else { throw ImportError.invalid("Формат XLSX не был отклонён.") }
        let history = WinnerHistory(listFingerprint: WinnerHistory.fingerprint(for: members), ids: ["1"])
        guard WinnerHistory.remaining(members, excluding: Set(history.ids)).map(\.id) == ["2"],
              WinnerHistory.remaining(members, excluding: Set(members.map(\.id))).isEmpty,
              history.listFingerprint != WinnerHistory.fingerprint(for: Array(members.reversed())) else {
            throw ImportError.invalid("Проверка исключения победителей не прошла.")
        }
        var timerSettings = RaffleSettings()
        timerSettings.showIntroCountdown = true
        timerSettings.countdownSeconds = 91
        timerSettings.countdownCaption = ""
        let restoredTimer = try JSONDecoder().decode(RaffleSettings.self, from: JSONEncoder().encode(timerSettings))
        guard restoredTimer.showIntroCountdown == true, restoredTimer.countdownSeconds == 91,
              restoredTimer.countdownCaption == "" else {
            throw ImportError.invalid("Настройки большого таймера не сохранились.")
        }
        #if BON_RAFFLE_PREVIEW
        guard RaffleStore.folder.lastPathComponent == "Bon Raffle Preview" else {
            throw ImportError.invalid("Превью использует общую папку данных.")
        }
        #endif
        let testFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonraffle-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testFolder) }
        let legacy = testFolder.appendingPathComponent("legacy", isDirectory: true)
        let current = testFolder.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let assets = ["background.custom", "logo.custom", "avatar-placeholder.custom"]
        for name in assets { try Data("old asset".utf8).write(to: legacy.appendingPathComponent(name)) }
        RaffleStore.importLegacyIfNeeded(from: legacy, into: current)
        for name in assets {
            let asset = current.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: asset.path) else {
                throw ImportError.invalid("Не удалось перенести \(name).")
            }
            try FileManager.default.removeItem(at: asset)
        }
        RaffleStore.importLegacyIfNeeded(from: legacy, into: current)
        guard assets.allSatisfy({ !FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) else {
            throw ImportError.invalid("Сброшенные изображения восстановились после запуска.")
        }
        print("Проверка импорта CSV (CRLF): 2 участника — OK")
        print("Проверка ограничения импорта форматом CSV: OK")
        print("Проверка исключения победителей: OK")
        print("Проверка сохранения сброса фона, логотипа и аватара: OK")
        print("Проверка сохранения таймера и пустой подписи: OK")
        let releaseJSON = """
        [{"tag_name":"windows-v9.0.0","draft":false,"prerelease":false,"assets":[]},
         {"tag_name":"macos-v2.3.0","draft":false,"prerelease":false,"body":"Changes","assets":[
           {"name":"BonRaffle-macOS15-plus-2.3.0.dmg","size":3,"digest":"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "browser_download_url":"https://github.com/bonappetitabc/BonRaffle/releases/download/macos-v2.3.0/BonRaffle-macOS15-plus-2.3.0.dmg"}]},
         {"tag_name":"v2.3.3","draft":false,"prerelease":false,"body":"Changes","assets":[
           {"name":"Bon-Raffle-Setup-2.3.3.exe","size":3,"digest":"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "browser_download_url":"https://github.com/bonappetitabc/BonRaffle/releases/download/v2.3.3/Bon-Raffle-Setup-2.3.3.exe"},
           {"name":"BonRaffle-macOS15-plus-2.3.3.dmg","size":3,"digest":"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "browser_download_url":"https://github.com/bonappetitabc/BonRaffle/releases/download/v2.3.3/BonRaffle-macOS15-plus-2.3.3.dmg"}]}]
        """
        let releases = try JSONDecoder().decode([AppUpdateClient.GitHubRelease].self, from: Data(releaseJSON.utf8))
        guard AppUpdateClient.candidate(releases[0]) == nil,
              let update = AppUpdateClient.candidate(releases[1]), update.version == "2.3.0",
              let sharedMac = AppUpdateClient.candidate(releases[2]),
              sharedMac.fileName == "BonRaffle-macOS15-plus-2.3.3.dmg",
              let sharedWindows = AppUpdateClient.candidate(releases[2], platform: "windows"),
              sharedWindows.fileName == "Bon-Raffle-Setup-2.3.3.exe",
              sharedMac.sha256 == sharedWindows.sha256,
              UpdateVersion("2.10.0")! > UpdateVersion("2.9.0")!, UpdateVersion("2.3.0-beta") == nil else {
            throw AppUpdateError.unavailable
        }
        let updateFile = testFolder.appendingPathComponent("update.dmg")
        try Data("abc".utf8).write(to: updateFile)
        try AppUpdateClient.verify(updateFile, release: update)
        try Data("abd".utf8).write(to: updateFile)
        rejected = false
        do { try AppUpdateClient.verify(updateFile, release: update) }
        catch { rejected = true }
        guard rejected else { throw AppUpdateError.invalidFile }
        print("Проверка платформы, версии и SHA-256 обновления: OK")
    }
}

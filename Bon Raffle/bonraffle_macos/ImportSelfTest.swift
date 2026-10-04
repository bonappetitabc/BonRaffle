import Foundation
import CoreGraphics

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
        let eligible = RaffleEngine.remaining(members, excluding: ["1"])
        guard eligible.map(\.id) == ["2"],
              RaffleEngine.drawParticipant(eligible, nextIndex: { _ in 0 })?.id == "2",
              RaffleEngine.drawParticipant([members[0]])?.id == "1",
              RaffleEngine.drawParticipant([]) == nil else {
            throw ImportError.invalid("Проверка выбора участника не прошла.")
        }
        var prizes = [
            Prize(id: "empty", name: "Empty", image: "", quantity: 0, weight: 100),
            Prize(id: "first", name: "First", image: "", quantity: 1, weight: 1),
            Prize(id: "second", name: "Second", image: "", quantity: 3, weight: 3)
        ]
        guard try RaffleEngine.drawPrize(prizes, nextTicket: { _ in 0 }).id == "first",
              try RaffleEngine.drawPrize(prizes, nextTicket: { _ in 1 }).id == "second",
              try RaffleEngine.drawPrize(prizes, nextTicket: { _ in 3 }).id == "second",
              RaffleEngine.prizeChance(prizes, prize: prizes[0]) == 0,
              RaffleEngine.prizeChance(prizes, prize: prizes[1]) == 0.25,
              RaffleEngine.prizeChance(prizes, prize: prizes[2]) == 0.75 else {
            throw ImportError.invalid("Проверка весов и вероятностей призов не прошла.")
        }
        prizes[1].quantity -= 1
        guard prizes[1].quantity == 0,
              try RaffleEngine.drawPrize(prizes, nextTicket: { _ in 0 }).id == "second" else {
            throw ImportError.invalid("Исчерпанный приз не был исключён.")
        }
        guard RaffleSettings().showWinnerPosition != true else {
            throw ImportError.invalid("Позиция победителя должна быть скрыта по умолчанию.")
        }
        var timerSettings = RaffleSettings()
        timerSettings.showIntroCountdown = true
        timerSettings.verifiableDraw = true
        timerSettings.showWinnerPosition = true
        timerSettings.countdownSeconds = 91
        timerSettings.countdownCaption = ""
        let restoredTimer = try JSONDecoder().decode(RaffleSettings.self, from: JSONEncoder().encode(timerSettings))
        guard restoredTimer.showIntroCountdown == true, restoredTimer.verifiableDraw == true,
              restoredTimer.showWinnerPosition == true,
              restoredTimer.countdownSeconds == 91,
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
        let record = DrawRecord(timestampUtc: "2026-01-01T00:00:00Z", mode: "participants",
                                listName: "Тест", listFingerprint: "abc", eligibleCount: 2,
                                winnerId: "1", winnerName: "Анна", chance: 0.5,
                                listPosition: 2)
        try DrawLog.append(record, to: testFolder)
        guard try DrawLog.load(from: testFolder).first?.winnerId == "1",
              String(data: try DrawLog.exportData(from: testFolder), encoding: .utf8)?
                .contains("bon-raffle-draw-log-v1") == true else {
            throw ImportError.invalid("Проверка протокола розыгрыша не прошла.")
        }
        let pdfURL = testFolder.appendingPathComponent("test-results.pdf")
        try DrawPdf.save([record], to: pdfURL)
        guard let pdf = CGPDFDocument(pdfURL as CFURL), pdf.numberOfPages == 1 else {
            throw ImportError.invalid("Проверка PDF с результатами не прошла.")
        }
        try DrawLog.clear(from: testFolder)
        guard try DrawLog.load(from: testFolder).isEmpty else {
            throw ImportError.invalid("История результатов не очистилась.")
        }
        let fixedSeed = Data((0..<32).map { UInt8($0) })
        let fixedProof = RaffleProof.participants(members, seed: fixedSeed)
        guard fixedProof.snapshotHash == "5ccd673f754831f18568c00912211cee3288daf6d313cde81764404db9903eb6",
              fixedProof.commitment == "bd0b446e0af7c7bf0492bf36322782f8a3742b4e7ae1b09c07c9384786e6b72d",
              fixedProof.ticket(code: "viewer-42", upperBound: 2) == 0 else {
            throw ImportError.invalid("Проверка одинакового результата на двух платформах не прошла.")
        }
        let verifiedRecord = DrawRecord(timestampUtc: "2026-01-01T00:00:00Z", mode: "participants",
                                        listName: "Тест", listFingerprint: "abc", eligibleCount: 2,
                                        winnerId: "1", winnerName: "Анна", chance: 0.5,
                                        proof: fixedProof.reveal(code: "viewer-42", ticket: 0))
        guard RaffleProof.verify(verifiedRecord) else {
            throw ImportError.invalid("Проверяемый результат не воспроизводится.")
        }
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

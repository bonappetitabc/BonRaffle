import AppKit
import CoreGraphics

enum DrawPdf {
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 46
    private static let ink = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.18, alpha: 1)
    private static let orange = NSColor(calibratedRed: 0.82, green: 0.41, blue: 0.12, alpha: 1)

    static func save(_ records: [DrawRecord], to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ImportError.invalid("Не удалось создать PDF.")
        }
        let titleFont = NSFont.systemFont(ofSize: 21, weight: .bold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let smallFont = NSFont.systemFont(ofSize: 9)
        var page = 0
        var top: CGFloat = 0

        func beginPage() {
            pdf.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
            page += 1
            _ = draw("Bon Raffle", top: 38, font: titleFont, color: ink)
            _ = draw("Результаты розыгрышей", top: 76, font: bodyFont, color: orange)
            pdf.setStrokeColor(orange.cgColor)
            pdf.setLineWidth(1)
            pdf.move(to: CGPoint(x: margin, y: pageSize.height - 106))
            pdf.addLine(to: CGPoint(x: pageSize.width - margin, y: pageSize.height - 106))
            pdf.strokePath()
            _ = draw("Страница \(page)", top: pageSize.height - 32, font: smallFont, color: ink)
            top = 122
        }

        func endPage() {
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }

        func textHeight(_ text: String, font: NSFont) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let bounds = attributed.boundingRect(with: CGSize(width: pageSize.width - margin * 2 - 28,
                                                               height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return ceil(bounds.height) + 3
        }

        @discardableResult
        func draw(_ text: String, top: CGFloat, font: NSFont, color: NSColor, inset: CGFloat = 0) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let width = pageSize.width - margin * 2 - inset * 2
            let height = ceil(attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height) + 3
            attributed.draw(with: CGRect(x: margin + inset, y: pageSize.height - top - height,
                                         width: width, height: height),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return height
        }

        beginPage()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ru_RU")
        dateFormatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let simpleIso = ISO8601DateFormatter()
        for (index, record) in records.enumerated() {
            let date = iso.date(from: record.timestampUtc) ?? simpleIso.date(from: record.timestampUtc)
            let when = date.map { dateFormatter.string(from: $0) } ?? record.timestampUtc
            let mode = record.mode == "prizes" ? "Приз" : "Участник"
            var fields: [(String, NSFont)] = [
                ("\(index + 1). \(mode) - \(when)", boldFont),
                ("Победитель: \(record.winnerName)", bodyFont),
                ("Список: \(record.listName)", bodyFont)
            ]
            if let position = record.listPosition, position > 0 {
                fields.append(("Позиция в списке: \(position)", smallFont))
            }
            let countLabel = record.mode == "prizes" ? "Доступных видов призов" : "Участников в розыгрыше"
            fields.append(("\(countLabel): \(record.eligibleCount)", smallFont))
            let heights = fields.map { textHeight($0.0, font: $0.1) }
            let cardHeight = heights.reduce(26, +)
            if top + cardHeight > pageSize.height - 52 {
                endPage()
                beginPage()
            }
            let card = CGRect(x: margin, y: pageSize.height - top - cardHeight,
                              width: pageSize.width - margin * 2, height: cardHeight)
            pdf.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
            pdf.fill(card)
            pdf.setStrokeColor(NSColor(calibratedWhite: 0.88, alpha: 1).cgColor)
            pdf.stroke(card)
            var lineTop = top + 12
            for (text, font) in fields {
                lineTop += draw(text, top: lineTop, font: font, color: ink, inset: 14)
            }
            top += cardHeight + 12
        }
        endPage()
        pdf.closePDF()
    }
}

import Foundation

final class XMLTVParser: NSObject, XMLParserDelegate {
    private let now: Date
    private var currentChannel = ""
    private var currentStart: Date?
    private var currentEnd: Date?
    private var title = ""
    private var detail = ""
    private var currentIsNew = false
    private var text = ""
    private let endOfWindow: Date
    private(set) var programs: [String: [CurrentProgram]] = [:]
    private lazy var dateFormatters: [DateFormatter] = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmm Z"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    init(now: Date = Date()) {
        self.now = now
        endOfWindow = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    func parse(_ data: Data) -> [String: [CurrentProgram]] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return programs.mapValues { $0.normalizedEPG() }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        guard elementName == "programme" else { return }
        currentChannel = attributeDict["channel"] ?? ""
        currentStart = date(attributeDict["start"])
        currentEnd = date(attributeDict["stop"])
        title = ""
        detail = ""
        currentIsNew = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "title" { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "desc" { detail = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "new" { currentIsNew = true }
        if elementName == "programme", let start = currentStart, let end = currentEnd,
           end > now, start < endOfWindow, !currentChannel.isEmpty {
            programs[currentChannel, default: []].append(CurrentProgram(channelID: currentChannel, title: title, detail: detail, start: start, end: end, isNew: currentIsNew))
        }
        text = ""
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

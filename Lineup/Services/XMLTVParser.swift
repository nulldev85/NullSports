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
        return Self.timestamp(value)
    }

    /// An XMLTV timestamp, read as the fixed shape it is.
    ///
    /// This was three DateFormatters tried in turn. A programme carries two
    /// timestamps and a provider publishes hundreds of thousands of them, so a
    /// guide load meant a million locale-aware parses to read fields that are
    /// already plain digits — and DateFormatter is among the most expensive
    /// ways to read a digit in the framework. Reading the bytes directly is
    /// the single largest saving available in loading a guide.
    ///
    /// It accepts exactly what those formatters accepted, and nothing more:
    /// `yyyyMMddHHmmss Z`, `yyyyMMddHHmmssZ` and `yyyyMMddHHmm Z`. Widening
    /// that would change which programmes a guide contains, which is a
    /// different decision from making it fast.
    static func timestamp(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var accumulated = 0
            for _ in 0..<count {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                accumulated = accumulated * 10 + Int(byte - 48)
                index += 1
            }
            return accumulated
        }

        guard let year = digits(4), let month = digits(2), let day = digits(2),
              let hour = digits(2), let minute = digits(2) else { return nil }
        // The fourteen-digit form carries seconds; the twelve-digit one does not.
        var second = 0
        if index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            guard let parsed = digits(2) else { return nil }
            second = parsed
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        // An offset was required by every one of the formats this replaces.
        guard index < bytes.count else { return nil }
        let sign: Int
        switch bytes[index] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return nil
        }
        index += 1
        guard let offsetHours = digits(2), let offsetMinutes = digits(2),
              index == bytes.count else { return nil }
        guard (1...12).contains(month), hour < 24, minute < 60, second < 60,
              offsetHours < 24, offsetMinutes < 60 else { return nil }
        // The day is checked against its own month, not merely against 31. The
        // arithmetic below is happy to roll the thirtieth of February into
        // March, and a listing quietly moved to the wrong day is worse than one
        // that is dropped: it looks like real data. The formatters this
        // replaced refused such a date, so this refuses it too.
        let daysInMonth: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: daysInMonth = 31
        case 4, 6, 9, 11: daysInMonth = 30
        default:
            let isLeapYear = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            daysInMonth = isLeapYear ? 29 : 28
        }
        guard day >= 1, day <= daysInMonth else { return nil }

        // Days from civil: exact, and it needs no calendar to be built or
        // consulted. Proleptic Gregorian, which is what XMLTV dates are.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let offset = sign * (offsetHours * 3600 + offsetMinutes * 60)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

import Foundation
import zlib

final class XMLTVParser: NSObject, XMLParserDelegate {
    private(set) var isValid = false
    private var hasTVRoot = false
    private var hasSeenRoot = false
    /// How much of the past a guide can show, and therefore how much of it has
    /// to survive parsing. The Guide draws the hour before the current
    /// half-hour so a programme already in progress has its elapsed shading
    /// measured from where it actually started. Any listing that ends inside
    /// that hour is on screen, so it must be kept — dropping everything that
    /// had already finished is what left the first column reading "No listing"
    /// for every channel.
    static let lookback: TimeInterval = 3600
    private let startOfWindow: Date
    private var currentChannel = ""
    private var currentStart: Date?
    private var currentEnd: Date?
    private var title = ""
    private var detail = ""
    private var currentIsNew = false
    private var text = ""
    private let endOfWindow: Date
    private(set) var programs: [String: [CurrentProgram]] = [:]

    /// Listings read by the parse in progress, kept only once it is known
    /// whether a batch read whole (`read`).
    private var pending: [CurrentProgram] = []

    init(now: Date = Date()) {
        startOfWindow = Self.retentionStart(now: now)
        endOfWindow = Self.retentionEnd(now: now)
    }

    /// The earliest instant a parsed guide keeps. Anchored to the half-hour the
    /// Guide anchors to, so the two cannot drift apart.
    static func retentionStart(now: Date) -> Date {
        let anchor = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
        return anchor.addingTimeInterval(-lookback)
    }

    /// Where a parsed guide stops: the end of tomorrow.
    static func retentionEnd(now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    func parse(_ data: Data) -> [String: [CurrentProgram]] {
        hasTVRoot = false
        hasSeenRoot = false
        programs = [:]
        isValid = run(data) && hasTVRoot
        commit()
        return normalizedPrograms
    }

    /// One batch of a guide read piece by piece (`programs(fromGuide:)`). Its
    /// listings join the guide only if the whole batch reads.
    func read(_ document: Data) -> Bool {
        hasTVRoot = false
        hasSeenRoot = false
        let whole = run(document) && hasTVRoot
        if whole { commit() } else { pending.removeAll(keepingCapacity: true) }
        return whole
    }

    var normalizedPrograms: [String: [CurrentProgram]] { programs.mapValues { $0.normalizedEPG() } }

    private func run(_ data: Data) -> Bool {
        pending.removeAll(keepingCapacity: true)
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    private func commit() {
        for program in pending { programs[program.channelID, default: []].append(program) }
        pending.removeAll(keepingCapacity: true)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        if !hasSeenRoot { hasSeenRoot = true; hasTVRoot = elementName == "tv" }
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
           end > startOfWindow, start < endOfWindow, !currentChannel.isEmpty {
            pending.append(CurrentProgram(channelID: currentChannel, title: title, detail: detail, start: start, end: end, isNew: currentIsNew))
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

// MARK: - A whole guide, a programme at a time

extension XMLTVParser {
    /// Every listing in a downloaded guide that falls inside the window the
    /// app keeps.
    ///
    /// A guide used to be unpacked whole and handed to one XMLParser. That set
    /// two limits a provider's guide could outgrow (64 MB packed, 256 MB
    /// unpacked), and one malformed listing anywhere in it, such as a bare "&"
    /// in a title, an HTML entity such as `&nbsp;` or a stray control
    /// character, failed the entire guide: a feed other players read without
    /// trouble showed no guide here, and Sports matched nothing. Now the guide
    /// is unpacked as it is read, listings outside the window are passed over
    /// before any XML is parsed, and the rest are parsed in batches. A batch
    /// that will not parse is repaired, and failing that read one listing at
    /// a time, so a broken listing costs only itself.
    ///
    /// Throws when the bytes are not an XMLTV guide at all (a sign-in page, a
    /// cut-off or corrupt download), as before.
    static func programs(fromGuide data: Data, now: Date = Date()) throws -> [String: [CurrentProgram]] {
        let reader = XMLTVGuideReader(now: now)
        try XMLTVChunks.forEach(in: data) { try reader.consume($0) }
        return try reader.finish()
    }
}

/// A guide's bytes, unpacked when they are gzip, handed on a piece at a time.
enum XMLTVChunks {
    static let chunkSize = 1 << 20
    /// Far past any real guide; only a runaway stream gets here.
    static let unpackedLimit: Int64 = 4 << 30

    static func forEach(in data: Data, _ body: ([UInt8]) throws -> Void) throws {
        // XMLTV links commonly end in .gz without a Content-Encoding header.
        guard data.starts(with: [0x1f, 0x8b]) else {
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                try body([UInt8](data[offset..<end]))
                offset = end
            }
            return
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PlaylistError.guide
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: chunkSize)
        var unpacked: Int64 = 0
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.bindMemory(to: Bytef.self).baseAddress else { throw PlaylistError.guide }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            // zlib counts its input in 32 bits, so it is handed over in pieces.
            var remaining = input.count
            var status = Z_OK
            repeat {
                if stream.avail_in == 0, remaining > 0 {
                    let piece = min(remaining, 1 << 30)
                    stream.avail_in = uInt(piece)
                    remaining -= piece
                }
                let produced: Int = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return buffer.count - Int(stream.avail_out)
                }
                // Z_BUF_ERROR here means the stream ran out before its end.
                guard status == Z_OK || status == Z_STREAM_END else { throw PlaylistError.guide }
                unpacked += Int64(produced)
                guard unpacked <= unpackedLimit else { throw PlaylistError.guide }
                if produced > 0 { try body(Array(output[0..<produced])) }
            } while status != Z_STREAM_END
        }
    }
}

/// Finds each `<programme>` in a guide as its bytes arrive, keeps the ones
/// inside the window, and parses those in batches.
final class XMLTVGuideReader {
    private static let programmeOpen = Array("<programme".utf8)
    private static let programmeClose = Array("</programme".utf8)
    /// A listing that runs longer than this without closing is broken; it is
    /// stepped over rather than held until the end of the guide.
    private static let longestListing = 4 << 20
    private static let batchListings = 500
    private static let batchBytes = 1 << 20

    private let collector: XMLTVParser
    private let startOfWindow: Date
    private let endOfWindow: Date
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var rootSeen = false
    private var encoding = "UTF-8"
    private var batch: [[UInt8]] = []
    private var batchSize = 0
    /// Listings that could not be read even on their own.
    private(set) var skipped = 0

    init(now: Date = Date()) {
        collector = XMLTVParser(now: now)
        startOfWindow = XMLTVParser.retentionStart(now: now)
        endOfWindow = XMLTVParser.retentionEnd(now: now)
    }

    func consume(_ chunk: [UInt8]) throws {
        buffer.append(contentsOf: chunk)
        try scan()
        // What has been read through no longer needs keeping.
        if cursor > 0, cursor >= buffer.count / 2 {
            buffer.removeSubrange(0..<cursor)
            cursor = 0
        }
    }

    func finish() throws -> [String: [CurrentProgram]] {
        guard rootSeen else { throw PlaylistError.guide }
        flush()
        return collector.normalizedPrograms
    }

    // MARK: Finding listings

    private func scan() throws {
        if !rootSeen, try !findRoot() {
            // A guide opens with its root; this many bytes without one is not a guide.
            if buffer.count > Self.longestListing { throw PlaylistError.guide }
            return
        }
        while true {
            guard let open = find(Self.programmeOpen, from: cursor) else {
                // Keep only a tail that "<programme" could still be split across.
                cursor = max(cursor, buffer.count - (Self.programmeOpen.count - 1))
                return
            }
            let afterName = open + Self.programmeOpen.count
            guard afterName < buffer.count else { cursor = open; return }
            // "<programmes" or the like is another element.
            guard Self.endsName(buffer[afterName]) else { cursor = afterName; continue }
            guard let tagEnd = endOfTag(from: afterName) else {
                if buffer.count - open > Self.longestListing { skipped += 1; cursor = afterName; continue }
                cursor = open
                return
            }
            let end: Int
            if buffer[tagEnd - 1] == UInt8(ascii: "/") {
                end = tagEnd + 1
            } else {
                guard let close = find(Self.programmeClose, from: tagEnd + 1),
                      let closeEnd = find([UInt8(ascii: ">")], from: close + Self.programmeClose.count) else {
                    if buffer.count - open > Self.longestListing { skipped += 1; cursor = afterName; continue }
                    cursor = open
                    return
                }
                end = closeEnd + 1
            }
            take(start: open, tagEnd: tagEnd, end: end)
            cursor = end
        }
    }

    /// Passes the declaration, comments and doctype, and checks the first
    /// element is `<tv>`. False while more bytes are needed to tell.
    private func findRoot() throws -> Bool {
        var position = cursor
        while true {
            guard let open = find([UInt8(ascii: "<")], from: position) else { return false }
            guard open + 4 <= buffer.count else { return false }
            if buffer[open + 1] == UInt8(ascii: "?") {
                guard let end = find(Array("?>".utf8), from: open + 2) else { return false }
                if Array(buffer[(open + 2)..<min(open + 5, end)]) == Array("xml".utf8) {
                    readEncoding(from: open + 5, to: end)
                }
                position = end + 2
            } else if Array(buffer[(open + 1)..<(open + 4)]) == Array("!--".utf8) {
                guard let end = find(Array("-->".utf8), from: open + 4) else { return false }
                position = end + 3
            } else if buffer[open + 1] == UInt8(ascii: "!") {
                // A doctype, perhaps with an internal subset in brackets.
                let bracket = find([UInt8(ascii: "[")], from: open)
                let close = find([UInt8(ascii: ">")], from: open)
                guard let close else { return false }
                if let bracket, bracket < close {
                    guard let subsetEnd = find(Array("]>".utf8), from: bracket) else { return false }
                    position = subsetEnd + 2
                } else {
                    position = close + 1
                }
            } else {
                guard buffer[open + 1] == UInt8(ascii: "t"), buffer[open + 2] == UInt8(ascii: "v"),
                      Self.endsName(buffer[open + 3]) else { throw PlaylistError.guide }
                rootSeen = true
                cursor = open + 3
                return true
            }
        }
    }

    /// The declared encoding, which every batch is parsed under.
    private func readEncoding(from start: Int, to end: Int) {
        let declaration = String(decoding: buffer[start..<end], as: UTF8.self)
        guard let name = declaration.range(of: "encoding") else { return }
        let rest = declaration[name.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\t" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return }
        let value = rest.dropFirst().prefix { $0 != quote }
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:".contains($0) }) else { return }
        encoding = String(value)
    }

    private var isUTF8: Bool {
        let name = encoding.lowercased()
        return name == "utf-8" || name == "utf8"
    }

    /// The `>` that ends a start tag, outside any quoted attribute value.
    private func endOfTag(from start: Int) -> Int? {
        var quote: UInt8 = 0
        var position = start
        while position < buffer.count {
            let byte = buffer[position]
            if quote != 0 {
                if byte == quote { quote = 0 }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return position
            }
            position += 1
        }
        return nil
    }

    private func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard start >= 0, start + needle.count <= buffer.count else { return nil }
        return buffer.withUnsafeBufferPointer { haystack -> Int? in
            guard let base = haystack.baseAddress else { return nil }
            let raw = UnsafeRawPointer(base)
            let last = haystack.count - needle.count
            var position = start
            while position <= last {
                guard let hit = memchr(raw + position, Int32(needle[0]), haystack.count - position) else { return nil }
                let index = raw.distance(to: UnsafeRawPointer(hit))
                guard index <= last else { return nil }
                if needle.count == 1 || memcmp(raw + index, needle, needle.count) == 0 { return index }
                position = index + 1
            }
            return nil
        }
    }

    private static func endsName(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
    }

    // MARK: Keeping and reading listings

    /// A listing is kept for parsing only when it falls inside the window,
    /// by the same rule the parser applies, read straight off its start tag.
    private func take(start: Int, tagEnd: Int, end: Int) {
        let attributes = Self.attributes(buffer[(start + Self.programmeOpen.count)..<tagEnd])
        guard let channel = attributes["channel"], !channel.isEmpty,
              let from = attributes["start"].flatMap(XMLTVParser.timestamp),
              let to = attributes["stop"].flatMap(XMLTVParser.timestamp),
              to > startOfWindow, from < endOfWindow else { return }
        batch.append(Array(buffer[start..<end]))
        batchSize += end - start
        if batch.count >= Self.batchListings || batchSize >= Self.batchBytes { flush() }
    }

    /// `channel`, `start` and `stop`, as written. Timestamps never carry
    /// entities; the channel is only checked for being there.
    private static func attributes(_ tag: ArraySlice<UInt8>) -> [String: String] {
        var found: [String: String] = [:]
        var position = tag.startIndex
        func skipSpace() { while position < tag.endIndex, endsName(tag[position]), tag[position] != UInt8(ascii: ">") { position += 1 } }
        while position < tag.endIndex {
            skipSpace()
            let nameStart = position
            while position < tag.endIndex, tag[position] != UInt8(ascii: "="), !endsName(tag[position]) { position += 1 }
            let name = String(decoding: tag[nameStart..<position], as: UTF8.self)
            skipSpace()
            guard position < tag.endIndex, tag[position] == UInt8(ascii: "=") else {
                if position == nameStart { position += 1 }
                continue
            }
            position += 1
            skipSpace()
            guard position < tag.endIndex else { break }
            let quote = tag[position]
            guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
                // An unquoted value: step over it.
                while position < tag.endIndex, !endsName(tag[position]) { position += 1 }
                continue
            }
            position += 1
            let valueStart = position
            while position < tag.endIndex, tag[position] != quote { position += 1 }
            if name == "channel" || name == "start" || name == "stop" {
                found[name] = String(decoding: tag[valueStart..<position], as: UTF8.self)
            }
            position += 1
        }
        return found
    }

    private func flush() {
        guard !batch.isEmpty else { return }
        defer {
            batch.removeAll(keepingCapacity: true)
            batchSize = 0
        }
        if collector.read(document(batch)) { return }
        // Something in this batch broke the XML. Repaired, it most likely reads.
        let repaired = batch.map { XMLTVRepair.repaired($0, utf8: isUTF8) }
        if collector.read(document(repaired)) { return }
        // Failing that, each listing on its own, so only broken ones are lost.
        for listing in repaired where !collector.read(document([listing])) { skipped += 1 }
    }

    private func document(_ listings: [[UInt8]]) -> Data {
        var data = Data(capacity: batchSize + 64)
        data.append(contentsOf: Array("<?xml version=\"1.0\" encoding=\"\(encoding)\"?><tv>".utf8))
        for listing in listings { data.append(contentsOf: listing) }
        data.append(contentsOf: Array("</tv>".utf8))
        return data
    }
}

/// The repairs that let a malformed listing read: what other players forgive.
enum XMLTVRepair {
    static func repaired(_ listing: [UInt8], utf8: Bool) -> [UInt8] {
        // Invalid UTF-8 becomes U+FFFD; another declared encoding is left alone.
        let source = utf8 ? Array(String(decoding: listing, as: UTF8.self).utf8) : listing
        var output: [UInt8] = []
        output.reserveCapacity(source.count + 16)
        var position = 0
        while position < source.count {
            let byte = source[position]
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D {
                // A control character XML does not allow.
                output.append(0x20)
                position += 1
            } else if byte == UInt8(ascii: "&") {
                if let found = reference(in: source, at: position) {
                    output.append(contentsOf: found.replacement)
                    position += found.length
                } else {
                    // A bare ampersand, as in "Law & Order".
                    output.append(contentsOf: Array("&amp;".utf8))
                    position += 1
                }
            } else {
                output.append(byte)
                position += 1
            }
        }
        return output
    }

    /// A reference at `index`: one XML knows, kept; an HTML name, written as
    /// its number; a number XML forbids, a space. Nil for a bare ampersand.
    private static func reference(in bytes: [UInt8], at index: Int) -> (length: Int, replacement: [UInt8])? {
        var end = index + 1
        while end < bytes.count, end - index <= 12, bytes[end] != UInt8(ascii: ";") {
            let byte = bytes[end]
            let letterOrDigit = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            guard letterOrDigit || byte == UInt8(ascii: "#") else { return nil }
            end += 1
        }
        guard end < bytes.count, bytes[end] == UInt8(ascii: ";"), end > index + 1 else { return nil }
        let whole = Array(bytes[index...end])
        let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
        if ["amp", "lt", "gt", "quot", "apos"].contains(name) { return (whole.count, whole) }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, isXMLCharacter(value) else { return (whole.count, [0x20]) }
            return (whole.count, whole)
        }
        if let code = htmlEntities[name] { return (whole.count, Array("&#\(code);".utf8)) }
        return nil
    }

    private static func isXMLCharacter(_ value: UInt32) -> Bool {
        value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
    }

    /// The HTML entities guide data carries, which XML does not define.
    private static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "yen": 165, "sect": 167, "copy": 169,
        "laquo": 171, "reg": 174, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180,
        "micro": 181, "para": 182, "middot": 183, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195,
        "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201,
        "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207,
        "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214,
        "times": 215, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220,
        "szlig": 223, "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228,
        "aring": 229, "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234,
        "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239, "ntilde": 241,
        "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247,
        "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yuml": 255,
        "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220,
        "rdquo": 8221, "bdquo": 8222, "bull": 8226, "hellip": 8230, "euro": 8364, "trade": 8482,
    ]
}

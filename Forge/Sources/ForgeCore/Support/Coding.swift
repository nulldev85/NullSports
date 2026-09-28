import Foundation

// Stored JSON must keep decoding across app versions. Every model decodes
// with defaults for missing or malformed fields instead of failing, so a
// document written by an older (or newer) build never becomes unreadable.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue()
    }

    func optionalValue<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Enums stored as strings fall back to a known case when a raw value isn't
/// recognized, rather than failing the whole document.
public protocol ResilientStringEnum: RawRepresentable, Codable, CaseIterable where RawValue == String {
    static var fallback: Self { get }
}

extension ResilientStringEnum {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self(rawValue: raw) ?? Self.fallback
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? Self.fallback
    }
}

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let text = try container.decode(String.self)
            if let date = ISO8601.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(text)")
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return decoder
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try decoder().decode(type, from: Data(string.utf8))
    }
}

/// ISO-8601 with milliseconds. Formatters are not thread-safe, so each call
/// builds its own; this is only used for export/import and stored JSON.
public enum ISO8601 {
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    public static func string(from date: Date) -> String {
        makeFormatter(fractional: true).string(from: date)
    }

    public static func date(from string: String) -> Date? {
        makeFormatter(fractional: true).date(from: string) ?? makeFormatter(fractional: false).date(from: string)
    }
}

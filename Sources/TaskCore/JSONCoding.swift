import Foundation

/// Centralized JSON coders for Pond.
///
/// Three call sites need three *distinct* shapes; collapsing them would silently
/// change output. These named factories keep the shapes from drifting:
/// - ``persistedEncoder`` / ``persistedDecoder`` — on-disk store, CLI install record, test fixtures.
/// - ``cliEncoder`` — the CLI's stdout JSON (its output structs carry no `Date` fields, so no date strategy).
/// - ``exportEncoder(pretty:)`` — GUI collection export (`.json` pretty, `.jsonl` compact).
public enum PondJSON {
    /// Pretty, key-sorted, ISO-8601 dates.
    public static var persistedEncoder: JSONEncoder { encoder(pretty: true, dates: true) }

    /// ISO-8601 decoder matching ``persistedEncoder``.
    public static var persistedDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Pretty, key-sorted, no date strategy.
    public static var cliEncoder: JSONEncoder { encoder(pretty: true, dates: false) }

    /// Key-sorted, ISO-8601 dates, pretty-printed only when requested.
    public static func exportEncoder(pretty: Bool) -> JSONEncoder { encoder(pretty: pretty, dates: true) }

    private static func encoder(pretty: Bool, dates: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        if dates { encoder.dateEncodingStrategy = .iso8601 }
        return encoder
    }
}

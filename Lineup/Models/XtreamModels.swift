import Foundation
import SwiftUI

struct XtreamProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var username: String

    init(id: UUID = UUID(), name: String, serverURL: String, username: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
    }
}

struct XtreamCategory: Codable, Identifiable, Hashable, Sendable {
    let categoryID: String
    let categoryName: String

    var id: String { categoryID }

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
    }
}

struct XtreamStream: Codable, Identifiable, Hashable, Sendable {
    let num: Int?
    let name: String
    let streamType: String?
    let streamID: Int
    let streamIcon: String?
    let epgChannelID: String?
    let categoryID: String?

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamType = "stream_type"
        case streamID = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
    }
}

struct CurrentProgram: Codable, Hashable, Sendable {
    let channelID: String
    let title: String
    let detail: String
    let start: Date
    let end: Date
    let isNew: Bool?

    init(channelID: String, title: String, detail: String, start: Date, end: Date, isNew: Bool? = nil) {
        self.channelID = channelID
        self.title = title
        self.detail = detail
        self.start = start
        self.end = end
        self.isNew = isNew
    }

    var isLive: Bool {
        let now = Date()
        return start <= now && now < end
    }
}

extension Array where Element == CurrentProgram {
    /// Produces a stable, non-overlapping XMLTV timeline. Providers sometimes
    /// repeat the same listing or publish a corrected listing over an older one.
    func normalizedEPG() -> [CurrentProgram] {
        let sorted = self.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [CurrentProgram] = []
        // The tail's trimmed title, carried rather than recomputed. This ran
        // once per programme over every programme a provider publishes, and it
        // was trimming the same previous title again on each pass.
        var previousTitleKey = ""

        for program in sorted where program.end > program.start {
            let titleKey = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let previous = result.last else {
                result.append(program)
                previousTitleKey = titleKey
                continue
            }

            // Not localized. These are two titles out of the same feed, so a
            // locale-aware collation decides nothing here that a plain
            // case-insensitive comparison does not, and it costs a great deal
            // more over a guide's worth of programmes.
            let sameTitle = previousTitleKey.caseInsensitiveCompare(titleKey) == .orderedSame

            if sameTitle && program.start <= previous.end {
                result[result.count - 1] = CurrentProgram(
                    channelID: previous.channelID,
                    title: previous.title.isEmpty ? program.title : previous.title,
                    detail: previous.detail.isEmpty ? program.detail : previous.detail,
                    start: Swift.min(previous.start, program.start),
                    end: Swift.max(previous.end, program.end),
                    isNew: previous.isNew == true || program.isNew == true
                )
                if previous.title.isEmpty { previousTitleKey = titleKey }
                continue
            }

            if program.start < previous.end {
                if program.start > previous.start {
                    result[result.count - 1] = CurrentProgram(
                        channelID: previous.channelID,
                        title: previous.title,
                        detail: previous.detail,
                        start: previous.start,
                        end: program.start,
                        isNew: previous.isNew
                    )
                } else {
                    result.removeLast()
                }
            }
            result.append(program)
            previousTitleKey = titleKey
        }
        return result
    }
}

struct SportsGame: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let league: SportsLeague
    let start: Date
    let awayTeam: String
    let homeTeam: String
    let awayAbbreviation: String
    let homeAbbreviation: String
    let awayLogo: String
    let homeLogo: String
    let awayScore: String
    let homeScore: String
    let awayColor: String?
    let homeColor: String?
    let awayRecord: String?
    let homeRecord: String?
    let venue: String?
    let location: String?
    let status: String
    let state: String
    let broadcast: String
    /// Event-level title for cards that contain multiple contests, such as UFC.
    let eventName: String?

    // How long a game can run before an unchanged status is stale rather than late.
    static let longestPlausibleGame: TimeInterval = 6 * 60 * 60

    // The schedule feed's own status can lag the first pitch by minutes, and
    // while it does the game is neither live nor upcoming to anything that asks:
    // no red dot, nothing in On Air, and -- worse -- the retry that rematches
    // live games never runs for it, so it can sit unmatched until something
    // reloads the whole library by hand.
    //
    // The clock settles what the feed has not. Once the start time has passed
    // the game is live, until either the feed says it finished or enough time
    // has gone by that a status still reading "pre" is broken rather than slow.
    var isLive: Bool {
        if state == "in" { return true }
        guard state == "pre" else { return false }
        let now = Date()
        let duration = league == .ufc ? 9 * 60 * 60 : Self.longestPlausibleGame
        return start <= now && now < start.addingTimeInterval(duration)
    }

    var isUpcoming: Bool { state == "pre" && start > Date() }

    /// A card for an event rather than a single contest. UFC puts a night of
    /// bouts behind one broadcast, so naming one of them is both arbitrary and
    /// wrong: nobody tunes in for the fight the feed happens to list first.
    var isEvent: Bool { !(eventName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Where it is being held, in one short line or not at all.
    ///
    /// The venue is the line worth having. A home side's name already implies
    /// its city -- nobody needs telling the Mariners are in Seattle -- but it
    /// does not name the ballpark, so that is the part that adds something.
    /// The city stands in only when the schedule knows no venue, which still
    /// beats a card that says nothing about where the game is.
    ///
    /// An event gets both, because its name implies neither.
    var placeLine: String? {
        let venue = Self.cleaned(self.venue)
        let city = Self.cleaned(self.location)
        let parts = isEvent ? [venue, city].compactMap { $0 } : [venue ?? city].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func cleaned(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

struct XtreamEnvelope: Codable {
    struct UserInfo: Codable {
        let auth: Int?
        let status: String?
        let expDate: String?
        let maxConnections: String?

        enum CodingKeys: String, CodingKey {
            case auth, status
            case expDate = "exp_date"
            case maxConnections = "max_connections"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? values.decode(Int.self, forKey: .auth) {
                auth = number
            } else if let text = try? values.decode(String.self, forKey: .auth) {
                auth = Int(text)
            } else {
                auth = nil
            }
            status = try? values.decode(String.self, forKey: .status)
            expDate = try? values.decode(String.self, forKey: .expDate)
            maxConnections = try? values.decode(String.self, forKey: .maxConnections)
        }
    }

    let userInfo: UserInfo?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
    }
}

enum SportsLeague: String, Codable, CaseIterable, Identifiable, Sendable {
    case nfl, nba, nhl, mlb, ncaaf, ufc

    var id: String { rawValue }
    var shortName: String { rawValue.uppercased() }
    var fullName: String {
        switch self {
        case .nfl: "Football"
        case .ncaaf: "College Football"
        case .nba: "Basketball"
        case .nhl: "Hockey"
        case .mlb: "Baseball"
        case .ufc: "Mixed Martial Arts"
        }
    }
    /// The theme owns the set. These were five literals mixed against one
    /// background, which is why a second theme could not have its own.
    var color: Color { LineupStyle.leagueColor(self) }

    /// Kept for callers holding a plain string. Anything asking more than one
    /// league about the same text should prepare it once instead.
    func matches(_ text: String) -> Bool { matches(SportsMatchText(text)) }

    /// One word is looked up; only a phrase is searched for.
    ///
    /// A day of a channel's listings is thousands of characters, and asking
    /// "does this contain 'bears'" scanned all of them. Thirty team names, six
    /// leagues, five thousand channels: thirty-five seconds of a launch spent
    /// scanning the same text for words already sitting in a set beside it.
    ///
    /// Single words are now a set lookup, which is stricter than the scan it
    /// replaces: "bears" no longer matches inside "bearsville". For a team
    /// name that is the answer anyone wanted -- a listing says Bears, it does
    /// not say Bearsville -- and phrases like "blue jays" still search the
    /// text, because a set of words cannot hold them.
    func matches(_ text: SportsMatchText) -> Bool {
        switch self {
        case .ncaaf:
            // Include shared broadcasters as candidates; game matching still
            // requires team evidence before offering playback.
            return text.words.contains(rawValue)
                || !text.words.isDisjoint(with: Self.ncaafBroadcasters)
                || text.has(Self.ncaafWords, Self.ncaafPhrases)
        case .ufc:
            return text.has(Self.ufcWords, Self.ufcPhrases)
        default:
            return text.words.contains(rawValue)
                || text.has(Self.teamWords[self] ?? [], Self.teamPhrases[self] ?? [])
        }
    }

    /// A term can be looked up only if it survives tokenizing as one piece.
    /// "pay-per-view" has no space in it but splits into three words, so it
    /// has to keep searching the text; "76ers" does not.
    private static func isOneWord(_ term: String) -> Bool {
        !term.isEmpty && term.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }

    private static func words(_ terms: [String]) -> Set<String> {
        Set(terms.filter(isOneWord))
    }

    private static func phrases(_ terms: [String]) -> [SportsPhrase] {
        terms.filter { !isOneWord($0) }.map(SportsPhrase.init)
    }

    private static let ncaafWords = words(ncaafTerms)
    private static let ncaafPhrases = phrases(ncaafTerms)
    private static let ufcWords = words(ufcTerms)
    private static let ufcPhrases = phrases(ufcTerms)
    private static let teamWords: [SportsLeague: Set<String>] = teamTerms.mapValues { words($0) }
    private static let teamPhrases: [SportsLeague: [SportsPhrase]] = teamTerms.mapValues { phrases($0) }

    private static let ncaafTerms = ["college football", "ncaa football", "cfb", "sec network", "acc network", "big ten", "big 12", "pac-12"]
    private static let ncaafBroadcasters: Set<String> = ["espn", "espn2", "espnu", "abc", "fox", "fs1", "fs2", "cbs", "cbssn", "nbc", "btn", "cw"]
    private static let ufcTerms = ["ufc", "ultimate fighting", "fight night", "mma", "pay per view", "pay-per-view", "ppv", "prelims", "early prelims", "contender series", "road to ufc", "fight pass"]

    // Stored, not computed. As a computed property every one of these arrays
    // was built again on every call, and the call happens once per league per
    // channel.
    private static let teamTerms: [SportsLeague: [String]] = [
        // NCAAF is left out on purpose: ambiguous shared mascots such as
        // Tigers and Bulldogs.
        .nfl: ["49ers", "bears", "bengals", "bills", "broncos", "browns", "buccaneers", "cardinals", "chargers", "chiefs", "colts", "commanders", "cowboys", "dolphins", "eagles", "falcons", "giants", "jaguars", "jets", "lions", "packers", "panthers", "patriots", "raiders", "rams", "ravens", "saints", "seahawks", "steelers", "texans", "titans", "vikings"],
        .nba: ["76ers", "bucks", "bulls", "cavaliers", "celtics", "clippers", "grizzlies", "hawks", "heat", "hornets", "jazz", "kings", "knicks", "lakers", "magic", "mavericks", "nets", "nuggets", "pacers", "pelicans", "pistons", "raptors", "rockets", "spurs", "suns", "thunder", "timberwolves", "trail blazers", "warriors", "wizards"],
        .nhl: ["avalanche", "blackhawks", "blue jackets", "blues", "bruins", "canadiens", "canucks", "capitals", "devils", "ducks", "flames", "flyers", "golden knights", "hurricanes", "islanders", "jets", "kings", "kraken", "lightning", "maple leafs", "mammoth", "oilers", "panthers", "penguins", "predators", "rangers", "red wings", "sabres", "senators", "sharks", "stars"],
        .mlb: ["angels", "astros", "athletics", "blue jays", "braves", "brewers", "cardinals", "cubs", "diamondbacks", "dodgers", "giants", "guardians", "mariners", "marlins", "mets", "nationals", "orioles", "padres", "phillies", "pirates", "rangers", "rays", "red sox", "reds", "rockies", "royals", "tigers", "twins", "white sox", "yankees"]
    ]
}

/// A channel's searchable text, prepared once.
///
/// League matching asks the same text the same six questions, and each
/// question used to lowercase the whole string again and split it into words
/// again. That text is not short: it carries the channel's entire day of
/// listings, and the caller had already lowercased it. Six redundant lowercase
/// passes and seven tokenizations per channel, across twenty-six thousand
/// channels, is where a launch spent most of a minute.
/// A term of more than one word, and the words it is made of.
///
/// Checking the words first is what stops a several-thousand-character scan
/// happening for every team name of every league on every channel.
struct SportsPhrase: Sendable {
    let text: String
    let words: [String]

    init(_ text: String) {
        self.text = text
        words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

struct SportsMatchText {
    let value: String
    let words: Set<String>

    /// Whether scanning the whole string for a term is affordable here.
    ///
    /// A channel's name is a few dozen characters and a day of its listings is
    /// several thousand. Scanning the short one is free, and it is also where
    /// terms turn up glued to their neighbours -- a channel called "PPV01" is
    /// a pay-per-view channel, and no amount of tokenizing will say so. The
    /// long one is where the same scan cost thirty-five seconds of a launch,
    /// and where a term glued inside a word is noise rather than a match.
    let scannable: Bool

    /// Hoisted: `inverted` builds a new character set every time it is read,
    /// and this was read once per league per channel.
    private static let wordSeparators = CharacterSet.alphanumerics.inverted

    /// For text the caller has already lowercased, which is the hot path.
    init(alreadyLowercased value: String, scannable: Bool = true) {
        self.value = value
        self.words = Set(value.components(separatedBy: Self.wordSeparators))
        self.scannable = scannable
    }

    init(_ text: String) { self.init(alreadyLowercased: text.lowercased()) }

    /// Whether any of these terms is here: the words by lookup, the phrases by
    /// search, and -- only where searching is cheap -- the words by search too.
    func has(_ words: Set<String>, _ phrases: [SportsPhrase]) -> Bool {
        if !self.words.isDisjoint(with: words) { return true }
        // A phrase cannot be here unless every word of it is here, and that is
        // two hash lookups against a scan of several thousand characters. For
        // the phrases that are absent -- which is nearly all of them, nearly
        // always -- the scan never happens. The scan still decides the ones
        // that pass, so adjacency and punctuation are judged exactly as before.
        if phrases.contains(where: { phrase in
            phrase.words.allSatisfy(self.words.contains) && value.contains(phrase.text)
        }) { return true }
        // Acronyms are searched for even in the long text. A provider writes
        // "UFC299" and "PPV01", and tokenizing cannot find a term glued to its
        // neighbour -- which is how five hundred channels fell out of the
        // index. There are four of these against thirty team names, so the
        // scan they cost is not the one that mattered.
        if words.contains(where: { $0.count <= 3 && value.contains($0) }) { return true }
        guard scannable else { return false }
        return words.contains { value.contains($0) }
    }
}

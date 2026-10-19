import Foundation

@main
struct MobilePlaybackSegmentChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let tv = MobileSegmentIdentity(imdb: "tt0944947", season: 1, episode: 2)!
        let movie = MobileSegmentIdentity(imdb: "tt0371746", isMovie: true)!
        func decode(_ body: String, as identity: MobileSegmentIdentity? = nil) -> MobilePlaybackSegments? {
            MobilePlaybackSegments.decode(Data(body.utf8), identity: identity ?? tv)
        }
        let body = #"{"imdb_id":"tt0944947","is_movie":false,"season":1,"episode":2,"intro":{"start_sec":120,"end_sec":210,"confidence":0.96,"submission_count":3},"recap":{"start_ms":10000,"end_ms":100000,"confidence":0.9,"submission_count":2},"outro":{"start_sec":2370,"end_sec":2490,"confidence":0.99,"submission_count":4}}"#
        let segments = decode(body)!
        check(segments.recap?.destination(at: 9.9, duration: 2500) == nil, "Recap is absent before its real start")
        check(segments.recap?.destination(at: 10, duration: 2500) == 100, "Manual recap skip lands on the verified end")
        check(segments.recap?.destination(at: 100, duration: 2500) == nil, "Recap disappears when it ends")
        check(segments.intro?.destination(at: 125, duration: 2500) == 210, "Existing intro still works independently")
        check(!segments.offersNext(at: 2369, duration: 2500, creditsEnabled: true), "Do not interrupt the episode")
        check(segments.offersNext(at: 2370, duration: 2500, creditsEnabled: true), "Existing offer can appear as credits begin")
        check(!segments.offersNext(at: 2370, duration: 2500, creditsEnabled: false), "Credit setting restores the original timing")
        let empty = MobilePlaybackSegments()
        check(!empty.offersNext(at: 2469, duration: 2500, creditsEnabled: true), "Missing timings do not invent credits")
        check(empty.offersNext(at: 2470, duration: 2500, creditsEnabled: true), "Missing timings keep final thirty seconds")
        check(segments.offersNext(at: 2470, duration: 2500, creditsEnabled: false), "Original offer survives disabling integration")
        check(!segments.offersNext(at: 50, duration: 60, creditsEnabled: true), "Short clips never offer another episode")
        check(!segments.offersNext(at: .nan, duration: 2500, creditsEnabled: true), "Invalid clock cannot offer playback")
        check(!segments.offersNext(at: 2501, duration: 2500, creditsEnabled: true), "Stale clock outside runtime is ignored")
        let wrongCut = MobilePlaybackSegments(outro: MobileIntroSegment(start: 1700, end: 1800))
        check(!wrongCut.offersNext(at: 1710, duration: 3000, creditsEnabled: true), "Credits far from the end cannot interrupt a longer cut")
        check(segments.offersNext(at: 2380, duration: 2400, creditsEnabled: true),
              "Final thirty seconds still work even if an outro does not fit")
        check(!segments.offersNext(at: 2380, duration: 2460, creditsEnabled: true), "Outro extending past runtime is rejected before fallback")
        check(decode(body.replacingOccurrences(of: "\"episode\":2", with: "\"episode\":3")) == nil, "Never use another episode")
        check(decode(body.replacingOccurrences(of: "tt0944947", with: "tt0903747")) == nil, "Never use another show")
        let malformed = body.replacingOccurrences(of: "\"start_ms\":10000", with: "\"start_ms\":\"bad\"")
        check(decode(malformed)?.intro == segments.intro && decode(malformed)?.recap == nil,
              "Malformed new data cannot break a working intro")
        let lowConfidence = body.replacingOccurrences(of: "\"confidence\":0.9,", with: "\"confidence\":0.2,")
        check(decode(lowConfidence)?.recap == nil, "Unreliable recap is omitted")
        let noRecap = body.replacingOccurrences(of: "\"recap\":", with: "\"no_recap\":true,\"recap\":")
        check(decode(noRecap)?.recap == nil, "Community no-recap flag takes precedence")
        let overlap = body.replacingOccurrences(of: "\"end_ms\":100000", with: "\"end_ms\":160000")
        check(decode(overlap)?.recap == nil && decode(overlap)?.intro == segments.intro, "Overlapping recap cannot skip into an intro")
        let film = #"{"imdb_id":"tt0371746","is_movie":true,"season":null,"episode":null,"outro":{"start_sec":7140,"end_sec":7515,"confidence":1,"submission_count":2},"post_credits":{"start_sec":7515,"end_sec":7555,"confidence":0.95,"submission_count":2}}"#
        let filmSegments = decode(film, as: movie)!
        let liveMovieShape = film.replacingOccurrences(of: "\"season\":null,\"episode\":null", with: "\"season\":0,\"episode\":0")
        check(decode(liveMovieShape, as: movie) == filmSegments, "Live movie replies use zero coordinates")
        check(decode(film.replacingOccurrences(of: "\"season\":null", with: "\"season\":1"), as: movie) == nil,
              "Nonzero episode coordinates cannot be accepted as a movie")
        check(!filmSegments.hasPostCreditsAhead(at: 7139, duration: 7560), "Movie notice waits for credits")
        check(filmSegments.hasPostCreditsAhead(at: 7140, duration: 7560), "Notice protects a real post-credit scene")
        check(!filmSegments.hasPostCreditsAhead(at: 7515, duration: 7560), "Notice disappears when scene starts")
        check(!filmSegments.hasPostCreditsAhead(at: 7200, duration: 7400), "Mismatching movie runtime does not advertise an invalid scene")
        check(!MobilePlaybackSegments(outro: filmSegments.outro).hasPostCreditsAhead(at: 7200, duration: 7560),
              "No scene data means no promise that a scene exists")
        let query = URLComponents(url: movie.url, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.count == 2 && query.contains(URLQueryItem(name: "is_movie", value: "true")), "Movies use the official movie route")
        check(MobileSegmentIdentity(imdb: "tt0371746", season: 1, episode: 1, isMovie: true) == nil, "Movie identity cannot contain episode coordinates")
        check(MobileSegmentIdentity(imdb: "movie title", isMovie: true) == nil, "Title guesses are never timing identities")
        print("Playback segments: exact identity, recap, credits fallback and post-credit safety passed")
    }
}

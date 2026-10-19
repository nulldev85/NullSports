import Foundation

struct MobileSegmentIdentity: Hashable, Sendable {
    let imdb: String
    let season: Int?
    let episode: Int?
    let isMovie: Bool

    init?(imdb: String, season: Int? = nil, episode: Int? = nil, isMovie: Bool = false) {
        guard imdb.range(of: "^tt[0-9]{7,}$", options: .regularExpression) != nil else { return nil }
        if isMovie {
            guard season == nil, episode == nil else { return nil }
        } else {
            guard let season, season >= 0, let episode, episode > 0 else { return nil }
        }
        self.imdb = imdb; self.season = season; self.episode = episode; self.isMovie = isMovie
    }

    var url: URL {
        var parts = URLComponents(string: "https://api.introdb.app/segments")!
        var query = [URLQueryItem(name: "imdb_id", value: imdb)]
        if isMovie { query.append(.init(name: "is_movie", value: "true")) }
        else if let season, let episode {
            query += [.init(name: "season", value: String(season)),
                      .init(name: "episode", value: String(episode))]
        }
        parts.queryItems = query
        return parts.url!
    }
}

struct MobileIntroSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    func destination(at position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, duration > end + 1,
              position >= start, position < end else { return nil }
        return end
    }

    func fits(duration: Double) -> Bool {
        duration.isFinite && duration > 0 && start.isFinite && end.isFinite
            && start >= 0 && end > start && end <= duration
    }
}

struct MobilePlaybackSegments: Equatable, Sendable {
    var intro: MobileIntroSegment? = nil
    var recap: MobileIntroSegment? = nil
    var outro: MobileIntroSegment? = nil
    var postCredits: MobileIntroSegment? = nil
    var isEmpty: Bool { intro == nil && recap == nil && outro == nil && postCredits == nil }

    /// This only decides when Lineup's existing offer can appear. Episode
    /// selection, Play Now, decline and end-of-playback remain with the caller.
    func offersNext(at position: Double, duration: Double, creditsEnabled: Bool) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 90, position >= 0, position <= duration else { return false }
        if creditsEnabled, let outro, outro.fits(duration: duration),
           duration - outro.start <= 900, position >= outro.start { return true }
        return duration - position <= 30
    }

    func hasPostCreditsAhead(at position: Double, duration: Double) -> Bool {
        guard position.isFinite, let outro, let postCredits,
              outro.fits(duration: duration), postCredits.fits(duration: duration),
              duration - outro.start <= 900, postCredits.start >= outro.start else { return false }
        return position >= outro.start && position < postCredits.start
    }

    static func decode(_ data: Data, identity: MobileSegmentIdentity) -> Self? {
        struct Segment: Decodable {
            let start_sec: Double?, end_sec: Double?, start_ms: Double?, end_ms: Double?
            let confidence: Double?
            let submission_count: Int?
            func validated(maximum: Double) -> MobileIntroSegment? {
                guard let start = start_ms.map({ $0 / 1000 }) ?? start_sec,
                      let end = end_ms.map({ $0 / 1000 }) ?? end_sec,
                      start.isFinite, end.isFinite, start >= 0, end - start >= 5, end - start <= maximum,
                      let confidence, confidence >= 0.8, confidence <= 1,
                      (submission_count ?? 0) >= 1 else { return nil }
                return MobileIntroSegment(start: start, end: end)
            }
        }
        struct Response: Decodable {
            let imdb: String, isMovie: Bool, season: Int?, episode: Int?
            let intro: Segment?, recap: Segment?, outro: Segment?, postCredits: Segment?
            enum CodingKeys: String, CodingKey {
                case imdb_id, is_movie, season, episode, intro, recap, outro, post_credits, no_intro, no_recap, no_outro
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                imdb = try c.decode(String.self, forKey: .imdb_id)
                isMovie = try c.decode(Bool.self, forKey: .is_movie)
                season = try c.decodeIfPresent(Int.self, forKey: .season)
                episode = try c.decodeIfPresent(Int.self, forKey: .episode)
                // An invalid new field cannot discard the existing valid intro.
                intro = (try? c.decode(Bool.self, forKey: .no_intro)) == true ? nil : (try? c.decode(Segment.self, forKey: .intro))
                recap = (try? c.decode(Bool.self, forKey: .no_recap)) == true ? nil : (try? c.decode(Segment.self, forKey: .recap))
                outro = (try? c.decode(Bool.self, forKey: .no_outro)) == true ? nil : (try? c.decode(Segment.self, forKey: .outro))
                postCredits = try? c.decode(Segment.self, forKey: .post_credits)
            }
        }
        guard data.count <= 128_000, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.imdb == identity.imdb, response.isMovie == identity.isMovie else { return nil }
        // The live movie endpoint returns zero coordinates; older examples omit
        // them or use null. None of these is an episode identity.
        if identity.isMovie {
            guard (response.season ?? 0) == 0, (response.episode ?? 0) == 0 else { return nil }
        } else {
            guard response.season == identity.season, response.episode == identity.episode else { return nil }
        }
        let intro = identity.isMovie ? nil : response.intro?.validated(maximum: 180)
        var recap = identity.isMovie ? nil : response.recap?.validated(maximum: 480)
        if let intro, let candidate = recap, candidate.start < intro.end, intro.start < candidate.end {
            recap = nil
        }
        return Self(intro: intro, recap: recap, outro: response.outro?.validated(maximum: 900),
                    postCredits: identity.isMovie ? response.postCredits?.validated(maximum: 600) : nil)
    }
}

import Foundation

@main
struct MobileFanartPolicyChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let movie = MobileFanartIdentity(kind: .movie, id: "603")!
        let tv = MobileFanartIdentity(kind: .series, id: "121361")!
        let base = "https://assets.fanart.tv/fanart/movies/603/hdmovielogo/"
        func response(_ rows: [[String: Any]], id: Any = "603", field: String = "hdmovielogo") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tmdb_id": id, "imdb_id": "tt0133093", field: rows])
        }
        let english = ["url": base + "english.png", "lang": "en", "likes": "3", "width": "800", "height": "310"]
        let other = ["url": base + "spanish.png", "lang": "es", "likes": "500"]
        let popular = ["url": base + "popular.png", "lang": "en", "likes": "4"]
        let rows = try response([other, english, popular])
        check(MobileFanartPolicy.logo(rows, identity: movie)?.lastPathComponent == "popular.png", "English logos rank by likes")
        check(MobileFanartPolicy.logo(rows, identity: movie, language: "es")?.lastPathComponent == "spanish.png", "Requested language wins")
        check(MobileFanartPolicy.logo(try response([english], id: "604"), identity: movie) == nil, "Another movie's art is rejected")
        check(MobileFanartPolicy.logo(rows, identity: tv) == nil, "Movie IDs cannot substitute for TVDB IDs")
        let imdb = MobileFanartIdentity(kind: .movie, id: "tt0133093")!
        check(MobileFanartPolicy.logo(rows, identity: imdb) != nil, "Official movie IMDb lookup remains supported")
        check(MobileFanartPolicy.logo(try response([english], id: 603), identity: movie) != nil, "Numeric JSON IDs are accepted")
        let unsafe = ["url": "https://assets.fanart.tv.evil.invalid/fanart/a.png", "lang": "en", "likes": "999"]
        check(MobileFanartPolicy.logo(try response([unsafe, english]), identity: movie)?.lastPathComponent == "english.png",
              "Untrusted high-ranked assets cannot win selection")
        for url in ["http://assets.fanart.tv/fanart/a.png", "https://user:password@assets.fanart.tv/fanart/a.png",
                    "https://assets.fanart.tv/fanart/a.png?api_key=secret", "https://assets.fanart.tv/fanart/../a.png",
                    "https://assets.fanart.tv:444/fanart/a.png", "https://assets.fanart.tv/fanart/a.svg"] {
            check(MobileFanartPolicy.imageURL(url) == nil, "Only public, bounded bitmap asset URLs are eligible")
        }
        let tooLarge = ["url": base + "huge.png", "lang": "en", "width": "100000", "height": "50000"]
        check(MobileFanartPolicy.logo(try response([tooLarge]), identity: movie) == nil, "Implausible image dimensions fall back to text")
        let television = try JSONSerialization.data(withJSONObject: ["thetvdb_id": "121361",
            "hdtvlogo": [["url": "https://assets.fanart.tv/fanart/tv/121361/hdtvlogo/logo.png", "lang": "00", "likes": "1"]]])
        check(MobileFanartPolicy.logo(television, identity: tv)?.lastPathComponent == "logo.png", "TV logos use exact TVDB identity")
        check(MobileFanartIdentity(kind: .series, id: "tt0944947") == nil, "An IMDb show ID cannot be sent as a TVDB ID")
        check(MobileFanartIdentity(kind: .movie, id: "../603") == nil, "Malformed IDs cannot become API routes")
        check(movie.request(key: " ") == nil, "Missing project configuration makes no request")
        let request = movie.request(key: "fixture-project-key")!
        check(request.url?.host == "webservice.fanart.tv" && request.url?.path == "/v3.2/movies/603", "Use the official movie route")
        check(tv.request(key: "fixture-project-key")?.url?.path == "/v3.2/tv/121361", "Use the official TV route")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "No server or account authorization travels to Fanart")
        check(request.timeoutInterval == 5, "Artwork requests have a bounded timeout")
        print("Fanart policy: exact movie/TV identities, logo selection and safe asset URLs passed")
    }
}

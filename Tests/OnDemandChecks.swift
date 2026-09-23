import Foundation

@main
struct OnDemandChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
            do { return try JSONDecoder().decode(type, from: Data(json.utf8)) }
            catch { preconditionFailure("Could not decode \(type): \(error)") }
        }

        // Names ------------------------------------------------------------
        let heat = OnDemandNaming.clean("EN - Heat (1995)")
        check(heat.name == "Heat" && heat.year == 1995, "Language tag and year come off")
        check(OnDemandNaming.clean("|EN| The Matrix").name == "The Matrix", "A barred tag comes off")
        check(OnDemandNaming.clean("[4K] Dune").name == "Dune", "A bracketed tag comes off")
        check(OnDemandNaming.clean("(500) Days of Summer").name == "(500) Days of Summer",
              "Parentheses at the front belong to the title")
        check(OnDemandNaming.clean("UFC: Fight Night").name == "UFC: Fight Night",
              "A colon after capitals is not a language tag")
        let war = OnDemandNaming.clean("1917 (2019)")
        check(war.name == "1917" && war.year == 2019, "A year-like title keeps its name")
        check(OnDemandNaming.clean("(2019)").name == "(2019)", "Nothing is stripped down to nothing")
        check(OnDemandNaming.clean("EN - ").name == "EN -", "A tag with no title after it stays")
        check(OnDemandNaming.episodeTitle("Show - S01E02 - The Title", number: 2) == "The Title",
              "The show and code come off an episode title")
        check(OnDemandNaming.episodeTitle("Show - S01E02", number: 2) == "Episode 2",
              "An episode named only by its code gets a number")
        check(OnDemandNaming.episodeTitle(nil, number: 5) == "Episode 5", "No title at all gets a number")
        check(OnDemandNaming.episodeTitle("Pilot", number: 1) == "Pilot", "A plain title is kept")
        check(OnDemandNaming.runtime(6300) == "1h 45m", "Runtimes read in hours and minutes")
        check(OnDemandNaming.runtime(2700) == "45m", "Short runtimes read in minutes")
        check(OnDemandNaming.seconds(fromClock: "01:40:00") == 6000, "Clock durations parse")
        check(OnDemandNaming.seconds(fromClock: "garbage") == nil, "Nonsense durations do not")

        // Category and title lists ------------------------------------------
        let categories = decode(OnDemandWire.Lossy<OnDemandWire.Category>.self, """
        [{"category_id":"5","category_name":"Action","parent_id":0},
         {"category_id":7,"category_name":"Drama"},
         {"category_name":"No identifier"},
         null]
        """).values.map(\.category)
        check(categories.map(\.id) == ["5", "7"], "Numeric identifiers read, unreadable rows skipped")
        check(decode(OnDemandWire.Lossy<OnDemandWire.Category>.self,
                     #"{"user_info":{"auth":0}}"#).values.isEmpty,
              "An error object instead of a list is an empty list")

        let movies = decode(OnDemandWire.Lossy<OnDemandWire.Title>.self, """
        [{"num":1,"name":"EN - Heat (1995)","stream_type":"movie","stream_id":"101","stream_icon":"http://x/heat.jpg",
          "rating":"8.3","rating_5based":4.1,"added":"1600000000","category_id":"5","container_extension":"mkv"},
         {"num":2,"name":"Arrival","stream_id":102,"stream_icon":"","rating":"","rating_5based":3.9,
          "category_ids":[5,9],"year":"2016"},
         {"num":3,"stream_id":103},
         {"num":4,"name":"Broken","stream_id":null}]
        """).values.map(\.title)
        check(movies.count == 2, "Rows without a name or an identifier are skipped")
        check(movies[0].id == "movies:101" && movies[0].name == "Heat" && movies[0].year == 1995,
              "A film's name is cleaned and its year kept")
        check(movies[0].rating == 8.3 && movies[0].containerExtension == "mkv", "Rating and file type read")
        check(movies[0].added == Date(timeIntervalSince1970: 1_600_000_000), "Added dates read from text")
        check(movies[1].artwork == nil, "Blank artwork is no artwork")
        check(movies[1].rating == 7.8, "A five-point rating is doubled")
        check(movies[1].categoryIDs == ["5", "9"] && movies[1].year == 2016, "Category lists and years read")

        let series = decode(OnDemandWire.Lossy<OnDemandWire.Title>.self, """
        [{"num":1,"name":"The Bear","series_id":55,"cover":"http://x/bear.jpg","rating":"8",
          "category_id":"12","releaseDate":"2022-06-23","last_modified":"1700000000"}]
        """).values.map(\.title)
        check(series.first?.kind == .series && series.first?.id == "series:55", "Series rows are series")
        check(series.first?.year == 2022 && series.first?.artwork == "http://x/bear.jpg",
              "A series' year and cover read")

        // Details ------------------------------------------------------------
        let movie = decode(OnDemandWire.MovieInfo.self, """
        {"info":{"plot":"A heist.","genre":"Crime","director":"Michael Mann","cast":"Al Pacino",
                 "releasedate":"1995-12-15","duration_secs":10200,"backdrop_path":["http://x/b.jpg"],
                 "movie_image":"http://x/p.jpg","rating":8.3},
         "movie_data":{"stream_id":101,"container_extension":"mp4"}}
        """).detail
        check(movie.facts.plot == "A heist." && movie.facts.year == 1995, "Film facts read")
        check(movie.facts.formattedRuntime == "2h 50m", "Film runtime reads")
        check(movie.facts.backdrops == ["http://x/b.jpg"] && movie.containerExtension == "mp4",
              "Backdrops and file type read")
        let bare = decode(OnDemandWire.MovieInfo.self, #"{"info":[],"movie_data":{"stream_id":1}}"#).detail
        check(bare.facts == .empty && bare.containerExtension == nil, "An empty info array is no facts")
        let clock = decode(OnDemandWire.MovieInfo.self,
                           #"{"info":{"duration":"01:40:00","backdrop_path":"http://x/one.jpg"}}"#).detail
        check(clock.facts.durationSeconds == 6000 && clock.facts.backdrops == ["http://x/one.jpg"],
              "Clock durations and a single backdrop string read")

        let show = decode(OnDemandWire.SeriesInfo.self, """
        {"seasons":[{"season_number":1,"name":"Season One"},{"season_number":0,"name":""}],
         "info":{"name":"The Bear","plot":"A kitchen.","episode_run_time":"30"},
         "episodes":{
           "2":[{"id":"2001","episode_num":1,"title":"The Bear - S02E01 - Beef","container_extension":"mkv","info":[]}],
           "1":[{"id":"1002","episode_num":2,"title":"The Bear - S01E02 - Hands","container_extension":"mkv",
                 "info":{"duration_secs":1800,"plot":"Second."},"season":1},
                {"id":"1001","episode_num":1,"title":"The Bear - S01E01 - System","container_extension":"mkv",
                 "info":{"movie_image":"http://x/s1.jpg"}}],
           "0":[{"id":"9001","episode_num":1,"title":"Special","container_extension":"mp4"}]
         }}
        """).detail(seriesID: "55")
        check(show.seasons.map(\.number) == [1, 2, 0], "Seasons in order, specials last")
        check(show.seasons[0].name == "Season One" && show.seasons[2].name == "Specials",
              "Season names from the provider, or made up when blank")
        check(show.seasons[0].episodes.map(\.id) == ["1001", "1002"], "Episodes in order within a season")
        check(show.seasons[0].episodes[0].title == "System" && show.seasons[1].episodes[0].title == "Beef",
              "Episode titles are cleaned")
        check(show.seasons[0].episodes[1].durationSeconds == 1800
              && show.seasons[0].episodes[0].still == "http://x/s1.jpg", "Episode info reads")
        check(show.facts.durationSeconds == 1800, "A series' run time is in minutes")
        check(show.episodeCount == 4, "Every episode is counted once")

        let listed = decode(OnDemandWire.SeriesInfo.self, """
        {"info":{},"episodes":[[{"id":"1","episode_num":1}],[{"id":"2","episode_num":1}]]}
        """).detail(seriesID: "9")
        check(listed.seasons.map(\.number) == [1, 2], "A list of lists numbers its seasons in order")
        check(listed.seasons[1].episodes[0].containerExtension == "mp4", "A missing file type defaults to mp4")

        // Search -------------------------------------------------------------
        func title(_ id: String, _ name: String) -> OnDemandTitle {
            OnDemandTitle(kind: .movies, providerID: id, rawName: name, name: name, artwork: nil,
                          rating: nil, year: nil, added: nil, categoryIDs: [], containerExtension: nil)
        }
        let catalogue = [title("1", "Heat Wave"), title("2", "The Heat"), title("3", "Heat"),
                         title("4", "Amélie"), title("5", "Heathers"), title("6", "Wheat Field")]
            .map(OnDemandSearchEntry.init)
        let ranked = OnDemandSearch.matches(catalogue, query: "heat").map(\.providerID)
        check(ranked == ["3", "1", "5", "2", "6"], "Exact, then prefix, then word, then anywhere: \(ranked)")
        check(OnDemandSearch.matches(catalogue, query: "amelie").map(\.providerID) == ["4"],
              "Search ignores accents")
        check(OnDemandSearch.matches(catalogue, query: "  ").isEmpty, "A blank query matches nothing")
        check(OnDemandSearch.matches(catalogue, query: "field wheat").map(\.providerID) == ["6"],
              "Every word must appear, in any order")

        // Progress -----------------------------------------------------------
        let start = Date(timeIntervalSince1970: 1_000)
        func playback(_ kind: OnDemandPlayback.Kind, _ id: String, series: String? = nil,
                      position: TimeInterval = 0, duration: TimeInterval = 0,
                      at time: TimeInterval = 0, completed: Bool = false,
                      upNext: Bool = false) -> OnDemandPlayback {
            OnDemandPlayback(kind: kind, streamID: id, containerExtension: "mkv", title: id, artwork: nil,
                             still: nil, seriesID: series, seriesName: series.map { "Series " + $0 },
                             season: series == nil ? nil : 1, episode: series == nil ? nil : 1,
                             position: position, duration: duration,
                             updatedAt: start.addingTimeInterval(time), completed: completed, isUpNext: upNext)
        }
        check(OnDemandProgressPolicy.resumePosition(playback(.movie, "m", position: 900, duration: 6000)) == 900,
              "Real progress resumes")
        check(OnDemandProgressPolicy.resumePosition(playback(.movie, "m", position: 5, duration: 6000)) == nil,
              "A false start does not")
        check(OnDemandProgressPolicy.resumePosition(playback(.movie, "m", position: 5990, duration: 6000)) == nil,
              "The closing seconds do not")

        // Finishing an episode files the next as up next.
        var records: [String: OnDemandPlayback] = [:]
        let episode1 = playback(.episode, "e1", series: "s")
        let episode2 = playback(.episode, "e2", series: "s")
        records = OnDemandProgressPolicy.recording(episode1, position: 600, duration: 1800, completed: false,
                                                   upNext: episode2, now: start, in: records)
        check(OnDemandProgressPolicy.continueWatching(records.values).map(\.id) == ["episode:e1"],
              "A started episode is in Continue Watching")
        records = OnDemandProgressPolicy.recording(episode1, position: 1790, duration: 1800, completed: true,
                                                   upNext: episode2, now: start.addingTimeInterval(60), in: records)
        let afterFinish = OnDemandProgressPolicy.continueWatching(records.values)
        check(afterFinish.map(\.id) == ["episode:e2"] && afterFinish[0].isUpNext,
              "Finishing it puts the next one up, in the same single place")
        check(records["episode:e1"]?.completed == true, "The finished episode is watched")

        // An up-next episode never displaces real progress on it.
        var resumed: [String: OnDemandPlayback] = [:]
        resumed = OnDemandProgressPolicy.recording(episode2, position: 700, duration: 1800, completed: false,
                                                   upNext: nil, now: start, in: resumed)
        resumed = OnDemandProgressPolicy.recording(episode1, position: 1800, duration: 1800, completed: true,
                                                   upNext: episode2, now: start.addingTimeInterval(10), in: resumed)
        check(resumed["episode:e2"]?.position == 700 && resumed["episode:e2"]?.isUpNext == false,
              "Existing progress on the next episode stands")
        check(OnDemandProgressPolicy.continueWatching(resumed.values).first?.id == "episode:e2",
              "and is what Continue Watching shows")

        // A finished film leaves; a finale with nothing after takes its series out.
        var mixed: [String: OnDemandPlayback] = [:]
        mixed = OnDemandProgressPolicy.recording(playback(.movie, "m"), position: 5990, duration: 6000,
                                                 completed: true, upNext: nil, now: start, in: mixed)
        mixed = OnDemandProgressPolicy.recording(playback(.episode, "old", series: "t"), position: 300,
                                                 duration: 1800, completed: false, upNext: nil, now: start, in: mixed)
        mixed = OnDemandProgressPolicy.recording(playback(.episode, "finale", series: "t"), position: 1800,
                                                 duration: 1800, completed: true, upNext: nil,
                                                 now: start.addingTimeInterval(5), in: mixed)
        check(OnDemandProgressPolicy.continueWatching(mixed.values).isEmpty,
              "Finished films and finished series are not in Continue Watching")

        // Newest first, and removing keeps what was watched.
        var two: [String: OnDemandPlayback] = [:]
        two = OnDemandProgressPolicy.recording(playback(.movie, "a"), position: 100, duration: 6000,
                                               completed: false, upNext: nil, now: start, in: two)
        two = OnDemandProgressPolicy.recording(playback(.movie, "b"), position: 100, duration: 6000,
                                               completed: false, upNext: nil, now: start.addingTimeInterval(1), in: two)
        check(OnDemandProgressPolicy.continueWatching(two.values).map(\.id) == ["movie:b", "movie:a"], "Newest first")
        two = OnDemandProgressPolicy.removingFromContinueWatching("movie:b", in: two)
        check(OnDemandProgressPolicy.continueWatching(two.values).map(\.id) == ["movie:a"], "Removal takes one out")

        // Marking.
        var marked = OnDemandProgressPolicy.marking(playback(.movie, "m"), watched: true, upNext: nil,
                                                    now: start, in: [:])
        check(marked["movie:m"]?.completed == true, "Marking watched completes")
        marked = OnDemandProgressPolicy.marking(playback(.movie, "m"), watched: false, upNext: nil,
                                                now: start, in: marked)
        check(marked["movie:m"] == nil, "Marking unwatched forgets")

        // History is bounded.
        var many: [String: OnDemandPlayback] = [:]
        for index in 0..<(OnDemandProgressPolicy.historyLimit + 20) {
            many["movie:\(index)"] = playback(.movie, "\(index)", position: 100, duration: 6000,
                                              at: TimeInterval(index))
        }
        let trimmed = OnDemandProgressPolicy.trimmed(many)
        check(trimmed.count == OnDemandProgressPolicy.historyLimit && trimmed["movie:0"] == nil
              && trimmed["movie:\(OnDemandProgressPolicy.historyLimit + 19)"] != nil,
              "The oldest history goes first")

        // Where a series starts.
        let seasons = show.seasons
        check(OnDemandProgressPolicy.startingEpisode(in: seasons, records: [:])?.episode.id == "1001",
              "A new series starts at the first numbered episode, not a special")
        var watching: [String: OnDemandPlayback] = [:]
        watching = OnDemandProgressPolicy.recording(playback(.episode, "1002", series: "55"), position: 400,
                                                    duration: 1800, completed: false, upNext: nil,
                                                    now: start, in: watching)
        let resumeStart = OnDemandProgressPolicy.startingEpisode(in: seasons, records: watching)
        check(resumeStart?.episode.id == "1002" && resumeStart?.resume == 400, "It resumes what is under way")
        watching = OnDemandProgressPolicy.recording(playback(.episode, "1002", series: "55"), position: 1800,
                                                    duration: 1800, completed: true, upNext: nil,
                                                    now: start.addingTimeInterval(5), in: watching)
        check(OnDemandProgressPolicy.startingEpisode(in: seasons, records: watching)?.episode.id == "2001",
              "After the last finished, the next season")
        check(OnDemandProgressPolicy.nextEpisode(after: "2001", in: seasons, isCompleted: { _ in false }) == nil,
              "The last numbered episode has nothing after it; specials are not next")
        check(OnDemandProgressPolicy.nextEpisode(after: "1001", in: seasons,
                                                 isCompleted: { $0 == "1002" })?.id == "2001",
              "Watched episodes are skipped")

        print("On-demand checks passed.")
    }
}

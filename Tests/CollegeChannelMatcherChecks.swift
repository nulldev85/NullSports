import Foundation

@main
enum CollegeChannelMatcherChecks {
    static func main() {
        let kickoff = Date(timeIntervalSince1970: 1_000_000)
        func verify(_ channel: String, _ title: String, broadcast: String = "NBC", offset: Double = 0) -> Bool {
            CollegeChannelMatcher.verifies(broadcast: broadcast, channel: channel, title: title,
                away: "Washington State Cougars", home: "Washington Huskies", kickoff: kickoff,
                programStart: kickoff.addingTimeInterval(offset), programEnd: kickoff.addingTimeInterval(offset + 10800),
                now: kickoff.addingTimeInterval(3600), isLive: true)
        }
        precondition(verify("US: NBC HD", "Washington State vs Washington"))
        precondition(verify("STIRR: 10 NBC WJAR - (Providence, RI)", "Washington State Cougars at Washington Huskies"))
        precondition(!verify("STIRR: 10 NBC WJAR - (Providence, RI)", "NBC Nightly News"))
        precondition(!verify("NBC", "News from Washington State"))
        precondition(!verify("NBC", "Washington State vs Washington", offset: 86400))
        precondition(!verify("NBC", "Washington State vs Washington", offset: -86400))
        precondition(!verify("NBC", ""))
        precondition(!verify("NBC", "Washington State vs Washington", broadcast: "ESPN"))
        precondition(!verify("FOX News", "Washington State vs Washington", broadcast: "FOX"))
        precondition(!verify("ABC News", "Washington State vs Washington", broadcast: "ABC"))
        precondition(!verify("ESPN2 FHD", "Washington State vs Washington", broadcast: "ESPN"))
        precondition(!verify("ESPN+", "Washington State vs Washington", broadcast: "ESPN"))
        precondition(CollegeChannelMatcher.networks("US: ESPN 2 HD") == ["espn2"])
        precondition(CollegeChannelMatcher.networks("FOX SPORTS 1 UHD") == ["fs1"])
        precondition(!CollegeChannelMatcher.titleMatches("Charity ball army deployment rice prices", away: "Ball State Cardinals", home: "Rice Owls"))
        precondition(!verify("NBC", "Washington State vs Washington", broadcast: ""))
        precondition(!CollegeChannelMatcher.unambiguousChannel([]))
        precondition(!CollegeChannelMatcher.unambiguousChannel(["wjar", "king"]))
        precondition(!CollegeChannelMatcher.unambiguousChannel([""]))
        precondition(CollegeChannelMatcher.unambiguousChannel(["king", "king"]))
        print("20 college channel policy checks passed")
    }
}

import Foundation

@main
enum ProviderRefreshPolicyChecks {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        func needs(_ now: Date, fetchedAt: Date?) -> Bool {
            ProviderRefreshPolicy.needsRefresh(gameStart: start, providerFetchedAt: fetchedAt, now: now)
        }

        // Well before a game, nothing is owed however old the data is.
        precondition(!needs(at(-60), fetchedAt: at(-600)), "A game an hour out asks for nothing")
        precondition(!needs(at(-6), fetchedAt: at(-600)), "Six minutes out is still outside the lead")

        // Through the start, keep asking regardless of the data's age: a
        // provider can add the channel late, and its guide often names the game
        // only once play is under way.
        precondition(needs(at(-5), fetchedAt: at(-1)), "The lead begins five minutes out")
        precondition(needs(at(0), fetchedAt: at(-1)), "Kickoff asks even for data from a minute ago")
        precondition(needs(at(29), fetchedAt: at(-1)), "The window runs half an hour past the start")

        // Past the window, only data that predates the game -- which cannot
        // name it -- justifies another fetch. This is the case a start slept or
        // closed through leaves behind, and the old rule served none of it.
        precondition(needs(at(45), fetchedAt: at(-120)), "Data from before the game cannot describe it")
        precondition(needs(at(180), fetchedAt: at(-120)), "Age is what matters, not how long ago the game began")
        precondition(!needs(at(45), fetchedAt: at(31)), "Data fetched after the start has already had its look")
        precondition(!needs(at(45), fetchedAt: at(0)), "Data fetched at the start has already had its look")

        // Fetching clears the condition, so a provider that genuinely carries no
        // channel for the game is not asked again and again.
        precondition(needs(at(45), fetchedAt: at(-120)), "First look after the window is owed")
        precondition(!needs(at(46), fetchedAt: at(45)), "The look just taken settles it")

        // Nothing fetched yet is the oldest data there is.
        precondition(needs(at(45), fetchedAt: nil), "A profile with no fetch behind it always asks")
        precondition(!needs(at(-60), fetchedAt: nil), "Even then, not before the game is near")

        print("Provider refresh policy checks passed")
    }
}

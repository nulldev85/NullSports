import Foundation

/// When a provider's channel list and guide are worth downloading again on
/// behalf of a game that has not matched a channel.
///
/// Rematching cannot find a channel the app never downloaded, and the channel
/// list and guide otherwise sit for hours. Two separate situations call for a
/// fresh copy, and a single rule covering only the first leaves the second
/// unserved for as long as the game runs.
enum ProviderRefreshPolicy {
    /// How early a provider is expected to have a game's channel in place.
    static let lead: TimeInterval = 5 * 60
    /// How long after the start a provider may still be adding one.
    static let window: TimeInterval = 30 * 60

    /// - Parameter providerFetchedAt: the older of the channel list and guide
    ///   fetch times, or nil when neither has ever been fetched.
    static func needsRefresh(gameStart: Date, providerFetchedAt: Date?, now: Date) -> Bool {
        // Nothing to do for a game that is not close to starting yet.
        guard gameStart.addingTimeInterval(-lead) <= now else { return false }
        // Around the start, keep asking. A provider can add the channel late,
        // and its guide often does not name the game until it is under way.
        if now < gameStart.addingTimeInterval(window) { return true }
        // Past that, only when the data predates the game and therefore cannot
        // describe it -- which is exactly what a start slept or closed through
        // leaves behind. Fetching once clears the condition, so a provider that
        // genuinely has no channel for the game is not asked over and over.
        guard let providerFetchedAt else { return true }
        return providerFetchedAt < gameStart
    }
}

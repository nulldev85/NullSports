import CoreGraphics

enum MobilePlayerLayout {
    /// The compact replay timeline sits below the picture, clear of both
    /// the centered transport and its bottom metadata badges.
    static let inlineTimelineHeight: CGFloat = 64
    /// Height of the full-screen player, measured so it doesn't depend on how
    /// much of the screen chrome currently claims.
    ///
    /// Expanding hides the navigation bar, the tab bar and the status bar, and
    /// each hands its space back to the content area at its own moment. Sizing
    /// the expanded player from the container alone therefore grows it in two or
    /// three visible steps. Container plus its insets is the same number before,
    /// during and after all of that, so the video makes one uninterrupted move.
    static func fullscreenHeight(containerHeight: CGFloat, safeAreaTop: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        containerHeight + safeAreaTop + safeAreaBottom
    }

    /// The skip, play and skip buttons together: 44 + 28 + 64 + 28 + 44. The
    /// cluster is centred, so half of it either side of centre is spoken for.
    static let transportClusterWidth: CGFloat = 208

    /// The gap between the Guide and Live player's skip buttons and its play
    /// button, on a channel the provider records. That player's controls are
    /// a size smaller than the title player's: 36-point skips either side of
    /// a 48-point play button full screen, a 42-point one inline.
    static func channelTransportSpacing(expanded: Bool) -> CGFloat { expanded ? 24 : 16 }

    /// The same cluster's width, either size: 36 + 24 + 48 + 24 + 36 full
    /// screen, 36 + 16 + 42 + 16 + 36 inline. The channel buttons at the
    /// trailing edge sit clear of half of it either side of centre on the
    /// narrowest iPhone, upright or on its side.
    static func channelTransportClusterWidth(expanded: Bool) -> CGFloat {
        36 + channelTransportSpacing(expanded: expanded) * 2 + (expanded ? 48 : 42) + 36
    }

    /// The widest the synopsis panel may be, given the room it has.
    ///
    /// Portrait has height to spare -- the controls sit at the centre of a tall
    /// screen and the panel at the bottom of it, well clear -- so the panel
    /// takes the width it wants. Landscape has no such room: the panel reaches
    /// up beside the controls, which is how a film's summary ended up printed
    /// across the skip-back button. There it stops short of the cluster.
    ///
    /// - Parameter available: the width the panel lays out in, inside the
    ///   player's own horizontal padding. The controls are centred on the same
    ///   space, so half of them sits either side of its midpoint.
    /// There is deliberately no minimum width. A floor under this would be a
    /// floor under the overlap too -- on a screen narrow enough to hit it, the
    /// panel would go back to sitting on the controls, which is the one thing
    /// this exists to prevent. A panel too narrow to read is a panel that
    /// shows nothing, and no real iPhone comes close: the smallest landscape
    /// the app runs at clears about two hundred points.
    static func synopsisWidth(available: CGFloat, compactHeight: Bool,
                              gap: CGFloat = 16, natural: CGFloat = 420) -> CGFloat {
        guard compactHeight else { return natural }
        let clearance = (available - transportClusterWidth) / 2 - gap
        return min(natural, max(0, clearance))
    }
}

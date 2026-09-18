import CoreGraphics

enum MobilePlayerLayout {
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

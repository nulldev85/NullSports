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
}

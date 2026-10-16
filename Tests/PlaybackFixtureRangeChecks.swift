import Foundation

@main
struct PlaybackFixtureRangeChecks {
    static func main() {
        let size = 4_143_213
        precondition(PlaybackFixtureByteRange.resolve(nil, count: size) == 0..<size)
        precondition(PlaybackFixtureByteRange.resolve("bytes=0-187", count: size) == 0..<188)
        precondition(PlaybackFixtureByteRange.resolve("bytes=-65536", count: size) == (size - 65_536)..<size)
        precondition(PlaybackFixtureByteRange.resolve("bytes=188-", count: size) == 188..<size)
        precondition(PlaybackFixtureByteRange.resolve("bytes=4000000-9999999", count: size) == 4_000_000..<size)
        precondition(PlaybackFixtureByteRange.resolve("bytes=-9999999", count: size) == 0..<size)
        for invalid in ["bytes=\(size)-", "bytes=10-2", "bytes=-0", "bytes=-", "bytes=0-1,3-4", "bytes=invalid"] {
            precondition(PlaybackFixtureByteRange.resolve(invalid, count: size) == nil)
        }
        precondition(PlaybackFixtureByteRange.resolve(nil, count: 0) == nil)
        print("Playback fixture byte ranges passed")
    }
}

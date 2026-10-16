import Foundation
import VLCKitSPM
import LineupAetherPlayback

/// VLCKit 3.6's public, pinned track dictionary. Its API does not expose HDR
/// transfer functions or JOC confirmation: codec/channel counts don't prove
/// either, so those labels remain absent on this backend.
@MainActor
enum VLCPlaybackMediaInfo {
    static func read(_ player: VLCMediaPlayer) -> PlaybackMediaInfo {
        guard player.hasVideoOut, let media = player.media else { return PlaybackMediaInfo() }
        let tracks = media.tracksInformation as? [[String: Any]] ?? []
        func selected(_ type: String, id: Int32) -> [String: Any]? {
            guard id >= 0 else { return nil }
            return tracks.first {
                ($0[VLCMediaTracksInformationType] as? String) == type
                    && ($0[VLCMediaTracksInformationId] as? NSNumber)?.int32Value == id
            }
        }
        func codec(_ track: [String: Any]?) -> String? {
            guard let value = (track?[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value else { return nil }
            // libvlc FourCC values use byte order opposite CoreMedia's.
            return String(bytes: [UInt8(value & 255), UInt8((value >> 8) & 255),
                                  UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)], encoding: .ascii)
        }
        let video = selected(VLCMediaTracksInformationTypeVideo, id: player.currentVideoTrackIndex)
        let audio = selected(VLCMediaTracksInformationTypeAudio, id: player.currentAudioTrackIndex)
        let numerator = (video?[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
        let denominator = (video?[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
        return PlaybackMediaInfo(videoCodec: codec(video), frameRate: denominator > 0 ? numerator / denominator : nil,
            audioCodec: codec(audio), audioChannels: (audio?[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue)
    }
}

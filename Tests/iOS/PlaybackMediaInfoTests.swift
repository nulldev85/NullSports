import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import LineupAetherPlayback

@MainActor
final class PlaybackMediaInfoTests: XCTestCase {
    func testUnknownAndOrdinaryStreamsDoNotClaimHDRorAtmos() {
        XCTAssertTrue(PlaybackMediaInfo().badges.isEmpty)
        let surround = PlaybackMediaInfo(videoCodec: "hevc", audioCodec: "eac3", audioChannels: 8)
        XCTAssertEqual(surround.badges, ["Dolby Digital Plus", "8 ch", "HEVC"])
        XCTAssertFalse(surround.badges.contains { $0.contains("HDR") || $0.contains("Atmos") })
        XCTAssertEqual(PlaybackMediaInfo(audioChannels: 6).badges, ["6 ch"])
        XCTAssertEqual(PlaybackMediaInfo(audioChannels: 6, audioLayout: "5.1(side)").badges, ["5.1"])
    }

    func testConfirmedSourceAttributesUseWholeSpecificLabels() {
        let info = PlaybackMediaInfo(dynamicRange: "Dolby Vision", videoCodec: "hevc", frameRate: 23.976,
            audioCodec: "eac3", audioChannels: 6, isDolbyAtmos: true)
        XCTAssertEqual(info.badges, ["Dolby Vision", "Dolby Atmos", "HEVC", "23.976 fps"])
        XCTAssertEqual(PlaybackMediaInfo(frameRate: 60).badges, ["60 fps"])
        XCTAssertTrue(PlaybackMediaInfo(frameRate: .nan, audioChannels: -1).badges.isEmpty)
        XCTAssertTrue(PlaybackMediaInfo(frameRate: .infinity).badges.isEmpty)
        XCTAssertEqual(PlaybackMediaInfo.audioLabel("mpga"), "MPEG Audio")
        XCTAssertEqual(PlaybackMediaInfo.audioLabel("mlp"), "MLP")
        XCTAssertEqual(PlaybackMediaInfo(audioCodec: "truehd", audioProfile: "Dolby TrueHD + Dolby Atmos").badges,
                       ["Dolby Atmos"])
        XCTAssertEqual(PlaybackMediaInfo(audioCodec: "truehd", audioChannels: 8).badges,
                       ["Dolby TrueHD", "8 ch"])
        XCTAssertEqual(PlaybackMediaInfo(audioCodec: "dca", audioProfile: "DTS-HD MA + DTS:X").badges, ["DTS:X"])
        XCTAssertEqual(PlaybackMediaInfo(audioCodec: "dca", audioProfile: "DTS-HD MA").badges, ["DTS-HD MA"])
        XCTAssertEqual(PlaybackMediaInfo(audioCodec: "aac", audioProfile: "Dolby TrueHD + Dolby Atmos").badges, ["AAC"])
    }

    func testAtmosRequiresACompleteJOCDeclaration() {
        // One independent E-AC-3 substream, bsid 16, no dependent streams.
        let plain = Data([0x50, 0, 0x20, 0x0F, 0, 0, 0])
        let joc = Data([0x50, 0, 0x20, 0x0F, 0, 1, 16])
        XCTAssertFalse(PlaybackMediaInfo.carriesDolbyAtmos(dec3: plain))
        XCTAssertTrue(PlaybackMediaInfo.carriesDolbyAtmos(dec3: joc))
        let boxed = Data([0, 0, 0, 15]) + Data("dec3".utf8) + joc
        XCTAssertTrue(PlaybackMediaInfo.carriesDolbyAtmos(dec3: boxed))
        for length in 0..<joc.count {
            XCTAssertFalse(PlaybackMediaInfo.carriesDolbyAtmos(dec3: joc.prefix(length)), "Truncated configuration")
        }
        XCTAssertFalse(PlaybackMediaInfo.carriesDolbyAtmos(dec3: Data([0, 0, 0, 14]) + Data("dec3".utf8) + joc))
        XCTAssertFalse(PlaybackMediaInfo.carriesDolbyAtmos(dec3: Data(repeating: 255, count: 32)))
        XCTAssertFalse(PlaybackMediaInfo.carriesDolbyAtmos(dec3: Data(repeating: 0, count: 4097)))
    }

    func testNativeAudioUsesJOCSignalingRatherThanSurroundChannels() throws {
        let plain = try audio(codec: kAudioFormatEnhancedAC3, cookie: Data([0x50, 0, 0x20, 0x0F, 0, 0, 0]))
        let atmos = try audio(codec: kAudioFormatEnhancedAC3, cookie: Data([0x50, 0, 0x20, 0x0F, 0, 1, 16]))
        XCTAssertFalse(NativePlaybackMediaInfoReader.carriesDolbyAtmos(plain))
        XCTAssertTrue(NativePlaybackMediaInfoReader.carriesDolbyAtmos(atmos))
    }

    func testNativeHDRRequiresTransferOrDolbySignalingRatherThanResolution() throws {
        let sdr = try video(transfer: nil)
        XCTAssertNil(NativePlaybackMediaInfoReader.dynamicRange(sdr), "4K/HEVC alone is not HDR")
        let pq = try video(transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(NativePlaybackMediaInfoReader.dynamicRange(pq), "HDR")
        let hdr10 = try video(transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                              primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(NativePlaybackMediaInfoReader.dynamicRange(hdr10), "HDR10")
        let hlg = try video(transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        XCTAssertEqual(NativePlaybackMediaInfoReader.dynamicRange(hlg), "HLG")
        let dv = try video(transfer: nil, codec: 0x64766831)
        XCTAssertEqual(NativePlaybackMediaInfoReader.dynamicRange(dv), "Dolby Vision")
    }

    private func video(transfer: String?, primaries: String? = nil,
                       codec: CMVideoCodecType = kCMVideoCodecType_HEVC) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        var extensions: [String: Any] = [:]
        if let transfer { extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer }
        if let primaries { extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries }
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
            width: 3840, height: 2160, extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        XCTAssertEqual(status, 0)
        return try XCTUnwrap(format)
    }

    private func audio(codec: AudioFormatID, cookie: Data) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: codec, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1_536, mBytesPerFrame: 0,
            mChannelsPerFrame: 6, mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: bytes.count, magicCookie: bytes.baseAddress,
                extensions: nil, formatDescriptionOut: &format)
        }
        XCTAssertEqual(status, 0)
        return try XCTUnwrap(format)
    }
}

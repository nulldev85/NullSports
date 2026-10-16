import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

/// Reads the enabled tracks already owned by AVPlayer. No extra stream
/// connection, manifest download or synchronous asset load is introduced.
@MainActor
public final class NativePlaybackMediaInfoReader {
    public private(set) var info = PlaybackMediaInfo()
    private weak var item: AVPlayerItem?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var lastRead = -Double.infinity

    public init() {}

    public func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        item = nil
        info = PlaybackMediaInfo()
        lastRead = -Double.infinity
    }

    public func refresh(_ current: AVPlayerItem?) {
        if item !== current { reset(); item = current }
        guard let current, current.status == .readyToPlay else {
            reset(); item = current
            return
        }
        guard task == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRead >= 1 else { return }
        lastRead = now
        let token = generation
        let enabled = current.tracks.filter(\.isEnabled)
        let ids = enabled.compactMap { $0.assetTrack?.trackID }
        task = Task { [weak self, weak current] in
            var next = PlaybackMediaInfo()
            for entry in enabled {
                guard let track = entry.assetTrack else { continue }
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                guard !Task.isCancelled else { return }
                if track.mediaType == .video {
                    // Conflicting variant descriptions do not prove which
                    // HDR format is playing. Publish only an agreed value.
                    next.dynamicRange = Self.consensus(descriptions.map(Self.dynamicRange))
                    next.videoCodec = Self.consensus(descriptions.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) })
                    let rate = Double(entry.currentVideoFrameRate)
                    if rate.isFinite, rate > 0 { next.frameRate = rate }
                    else if let nominal = try? await track.load(.nominalFrameRate), nominal.isFinite, nominal > 0 {
                        next.frameRate = Double(nominal)
                    }
                } else if track.mediaType == .audio {
                    let formats = descriptions.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                    next.audioCodec = Self.consensus(formats.map { Self.fourCC($0.mFormatID) })
                    let counts = Set(formats.map(\.mChannelsPerFrame))
                    if counts.count == 1, let count = counts.first, count > 0 { next.audioChannels = Int(count) }
                    next.isDolbyAtmos = !descriptions.isEmpty && descriptions.allSatisfy(Self.carriesDolbyAtmos)
                }
            }
            guard let self, self.generation == token, let current, self.item === current else { return }
            self.task = nil
            guard current.status == .readyToPlay,
                  current.tracks.filter(\.isEnabled).compactMap({ $0.assetTrack?.trackID }) == ids else {
                // Audio changed during the asynchronous read. Clear its old
                // label now and take a new snapshot on the next monitor tick.
                self.info = PlaybackMediaInfo()
                self.lastRead = -Double.infinity
                return
            }
            self.info = next
        }
    }

    deinit { task?.cancel() }

    public static func carriesDolbyAtmos(_ description: CMFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatEnhancedAC3 || asbd.mFormatID == 0x65632B33 else { return false }
        if asbd.mFormatID == 0x65632B33 { return true }
        // The format list can explicitly identify the JOC enhancement over
        // its ec-3 core. This describes the source, not output eligibility.
        var listSize = 0
        if let formats = CMAudioFormatDescriptionGetFormatList(description, sizeOut: &listSize),
           listSize > 0, listSize <= 4096 {
            let count = listSize / MemoryLayout<AudioFormatListItem>.stride
            if (0..<count).contains(where: { formats[$0].mASBD.mFormatID == 0x65632B33 }) { return true }
        }
        var size = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size),
              size > 0, size <= 4096 else { return false }
        return PlaybackMediaInfo.carriesDolbyAtmos(dec3: Data(bytes: cookie, count: size))
    }

    public static func dynamicRange(_ format: CMFormatDescription) -> String? {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        if ["dvh1", "dvhe", "dvav", "dva1", "dav1"].contains(codec)
            || ["dvcC", "dvvC"].contains(where: { (atoms[$0] as? Data).map { $0.count >= 4 } == true }) {
            return "Dolby Vision"
        }
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            return primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String ? "HDR10" : "HDR"
        }
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return "HLG" }
        return nil
    }

    public static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                       UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? ""
    }

    private static func consensus(_ values: [String?]) -> String? {
        guard let first = values.first ?? nil, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

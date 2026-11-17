import Foundation
import UIKit
import VideoToolbox

struct SiloPlaybackAsset: Sendable {
    let url: URL
    let decision: SiloPlaybackDecision
    let lease: SiloPlaybackLease
    let duration: Double?
    var requiresServerSeek: Bool { decision.playback_plan?.timeline.can_seek_anywhere != true }
}

private struct SiloPlaybackAcknowledgement: Decodable {
    let outcome: String
    let accepted: Accepted?
    struct Accepted: Decodable { let sequence: Int }
}

/// Engine-independent playback planning. The negotiated source clock remains
/// separate from a remux's player clock, including after a remote seek.
@MainActor
final class SiloPlaybackSession {
    struct Sidecar: Sendable { let data: Data; let title: String; let language: String }
    private(set) var sidecars: [Sidecar] = []
    var sourceProfileID: UUID?
    private(set) var asset: SiloPlaybackAsset?
    private(set) var isReplanning = false
    var assetChanged: ((SiloPlaybackAsset) -> Void)?
    var failed: ((String) -> Void)?
    var preparing: (() -> Void)?
    var retryFailed: ((String) -> Void)?
    var retryAllowed: (() -> Bool)?
    private var client: SiloClient?
    private var fileID = ""
    private var retryTask: Task<Void, Never>?
    private var installationID = ""
    private var profileID = ""
    private var attemptID = UUID().uuidString
    private var capabilities: [String: Any] = [:]
    private var context: [String: Any] = [:]
    private var features = ["playback_plan_v3"]
    private var sequence = 0
    private var lastPosition: Double = 0
    private var lastPaused = false
    private var closed = false
    private var heartbeat: Task<Void, Never>?
    private var writes: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var pendingSeek: Double?
    private var lastProgressAt = Date.distantPast
    private var progressWriting = false
    /// The account's access token, added to the media address the way
    /// Silo's own player adds it: a player cannot send the header.
    private var mediaToken: String?

    func open(client: SiloClient, fileID: String, position: Double) async throws -> SiloPlaybackAsset {
        guard !closed, self.client == nil, position.isFinite, position >= 0 else { throw MediaIntegrationError.invalidResponse }
        self.client = client
        self.fileID = fileID
        let capability: SiloPlaybackCapabilities = try await client.transport.get(["playback", "capabilities"])
        guard capability.allowed, capability.state == "available" else {
            throw MediaIntegrationError.unavailable("Silo playback is \(capability.state.replacingOccurrences(of: "_", with: " ")) for this account.")
        }
        guard capability.protocol_versions.contains(3), capability.features.contains("playback_plan_v3"),
              let installation = capability.installation_id, !installation.isEmpty,
              let profile = await client.transport.actingProfile() else {
            throw MediaIntegrationError.unavailable("This Silo server does not offer the supported playback protocol or profile.")
        }
        installationID = installation; profileID = profile
        if capability.features.contains("seek_reanchor_v1") { features.append("seek_reanchor_v1") }
        let evidence = Self.playerCapabilities()
        capabilities = evidence.capabilities; context = evidence.context
        let body: [String: Any] = ["installation_id": installation, "protocol_version": 3,
            "client_features": features, "file_id": fileID, "profile_id": profile,
            "playback_attempt_id": attemptID, "quality_preference": "auto", "subtitle_fidelity_preference": "compatible",
            "start_position": position, "progress_persistence": "server", "allow_alternate_versions": false,
            "client_capabilities": capabilities, "client_playback_context": context]
        let decision: SiloPlaybackDecision = try await client.transport.get(["playback", "start"], method: "POST", body: body)
        mediaToken = await client.transport.currentCredential().accessToken
        let opened: SiloPlaybackAsset
        do { opened = try makeAsset(decision) }
        catch {
            if let session = decision.session_id {
                try? await client.transport.mutate(["playback", session], method: "DELETE",
                    body: ["installation_id": installationID, "stop_id": UUID().uuidString.lowercased(),
                        "sequence": 1, "position": position, "is_paused": true])
            }
            throw error
        }
        // Closing/removing a source while the planner is replying must not
        // leave a new server session running behind a dismissed player.
        guard !closed, !Task.isCancelled else {
            try? await stopAsset(opened, client: client, position: position, paused: true)
            throw CancellationError()
        }
        asset = opened; lastPosition = position
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, !self.closed else { return }
                self.enqueueProgress(force: true)
            }
        }
        return opened
    }

    /// Silo's own reason for not playing a file, in words a viewer can act
    /// on. It said why every time; Lineup used to answer every one of them
    /// with the same line about a compatible plan.
    nonisolated static func explanation(_ terminal: SiloPlaybackDecision.Terminal) -> String {
        let retry = terminal.retryable == true ? " Try again in a moment." : ""
        switch terminal.reason {
        case "source_metadata_incomplete":
            return "Silo hasn’t finished reading this file yet." + retry
        case "source_unreadable":
            return "Silo can’t read this file. It may be damaged or in a format the server doesn’t understand."
        case "stream_limit_reached":
            return "Your Silo account is already playing as many streams as it’s allowed. Stop one, then try again."
        case "transcode_limit_reached":
            return "Your Silo account is already converting as many videos as it’s allowed. Stop one, then try again."
        case "route_capacity_unavailable", "route_capability_unavailable", "route_preparation_failed":
            return "Silo couldn’t get this file ready to stream right now." + retry
        case "routing_policy_unsatisfied", "adaptation_unavailable", "adaptation_exhausted",
             "client_hls_unsupported", "dv_conversion_unsupported", "hdr_transcode_unsupported",
             "audio_conversion_unsupported":
            return "Silo can’t send this version in a form this device plays, and its server settings don’t allow converting it. Try another version, or turn on transcoding on your Silo server."
        case "policy_denied":
            return "Your Silo server doesn’t allow this account to play this file."
        case "session_expired":
            return "That Silo playback session ended. Try again."
        default:
            let detail = terminal.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (detail.isEmpty ? "Silo won’t play this file (\(terminal.reason))." : detail) + retry
        }
    }

    private func makeAsset(_ decision: SiloPlaybackDecision) throws -> SiloPlaybackAsset {
        if decision.outcome != "playable", let terminal = decision.terminal {
            throw MediaIntegrationError.unavailable(Self.explanation(terminal))
        }
        guard decision.protocol_version == 3, decision.outcome == "playable", let plan = decision.playback_plan,
              let session = decision.session_id, !session.isEmpty, let client,
              let url = Self.mediaURL(plan.stream.url, base: client.http.base, token: mediaToken)
                  ?? client.http.resolvedURL(plan.stream.url), plan.stream.headers.isEmpty,
              plan.stream.header_refresh == "none", plan.timeline.player_start_seconds.isFinite,
              plan.timeline.player_start_seconds >= 0, plan.timeline.timeline_offset_seconds.isFinite,
              plan.timeline.timeline_offset_seconds >= 0 else {
            throw MediaIntegrationError.unavailable("Silo could not provide a compatible playback plan for this version. Check playback support on your server.")
        }
        // Copy-remux transport requires server reanchoring; never let its
        // growing playlist masquerade as a full-length locally seekable file.
        guard plan.timeline.can_seek_anywhere || features.contains("seek_reanchor_v1") else {
            throw MediaIntegrationError.unavailable("This Silo remux needs remote seeking support. Update your server before playing this version.")
        }
        let duration = plan.source.duration_seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let lease = SiloPlaybackLease(sessionID: session, installationID: installationID, profileID: profileID,
            playerStart: plan.timeline.player_start_seconds, timelineOffset: plan.timeline.timeline_offset_seconds)
        return SiloPlaybackAsset(url: url, decision: decision, lease: lease, duration: duration)
    }

    /// Where the player fetches a plan's stream, built as Silo's own player
    /// builds it. A path on the server is served under /api/v2 -- a bare
    /// /stream/ or /playback/transcode/ one, or an /api/v1 one, is moved
    /// there -- and carries the account's token, which a session started
    /// with an API key needs on every media request and a player has no
    /// header to send it in. An absolute address names a proxy node, which
    /// authorizes from the signed token already in it and is never handed
    /// the account's. Everything the server put in the address stays as it
    /// was, byte for byte.
    nonisolated static func mediaURL(_ path: String?, base: URL, token: String?) -> URL? {
        guard var path, !path.isEmpty else { return nil }
        let lowered = path.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return URL(string: path) }
        guard path.hasPrefix("/") else { return nil }
        // A path that already carries the server's own prefix, behind a
        // reverse proxy, is taken from after it.
        var prefix = base.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.isEmpty, path.hasPrefix(prefix + "/") { path.removeFirst(prefix.count) }
        if let range = path.range(of: #"^(?:/api/v1)?/(?=stream/|playback/transcode/)"#, options: .regularExpression) {
            path.replaceSubrange(range, with: "/api/v2/")
        }
        guard path.range(of: #"^/api/v[12]/"#, options: .regularExpression) != nil else { return nil }
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var address = root + path
        if let token, !token.isEmpty {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
            address += (address.contains("?") ? "&" : "?") + "token=" + encoded
        }
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    func sourcePosition(playerTime: Double) -> Double? {
        guard let asset, playerTime.isFinite, playerTime >= 0, !isReplanning else { return nil }
        let time = playerTime + asset.lease.timelineOffset
        return asset.duration.map { min($0, max(0, time)) } ?? max(0, time)
    }

    func sample(position: Double, paused: Bool) {
        guard !closed, !isReplanning, position.isFinite, position >= 0 else { return }
        let changed = lastPaused != paused
        lastPosition = position; lastPaused = paused
        enqueueProgress(force: changed)
    }

    func finalPosition(_ position: Double) {
        if position.isFinite, position >= 0 { lastPosition = position }
    }

    func rememberSubtitle(_ data: Data, title: String, language: String) {
        guard !sidecars.contains(where: { $0.data == data && $0.title == title && $0.language == language }) else { return }
        sidecars.append(Sidecar(data: data, title: title, language: language))
    }

    /// An explicit Retry obtains fresh signed media URLs and a new attempt.
    /// It never replays an uncertain start/replan mutation automatically.
    func retry() {
        guard !closed, retryTask == nil, let client, !fileID.isEmpty,
              retryAllowed?() != false else { return }
        isReplanning = true
        preparing?()
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.retryTask = nil; self.isReplanning = false }
            self.heartbeat?.cancel(); self.heartbeat = nil
            self.pendingSeek = nil
            await self.seekTask?.value
            await self.writes?.value
            self.isReplanning = true
            let position = self.lastPosition, paused = self.lastPaused
            do {
                // Retire the old lease before waiting, so a concurrent Close
                // cannot send a second stop for it under a different stop ID.
                let old = self.asset; self.asset = nil
                if let old {
                    do { try await self.stopAsset(old, client: client, position: position, paused: paused) }
                    catch { if !self.closed { self.asset = old }; throw error }
                }
                guard !self.closed, self.retryAllowed?() != false else { return }
                self.client = nil; self.sequence = 0; self.progressWriting = false
                self.features = ["playback_plan_v3"]; self.attemptID = UUID().uuidString
                self.lastProgressAt = .distantPast
                let prepared = try await self.open(client: client, fileID: self.fileID, position: position)
                guard !self.closed, self.retryAllowed?() != false else { await self.stop(); return }
                self.lastPaused = paused
                self.isReplanning = false
                self.assetChanged?(prepared)
            } catch {
                guard !self.closed, !Task.isCancelled else { return }
                self.retryFailed?(error.localizedDescription)
            }
        }
    }

    private func enqueueProgress(force: Bool) {
        guard !closed, !isReplanning, !progressWriting, let asset, let client,
              force || Date().timeIntervalSince(lastProgressAt) >= 10 else { return }
        lastProgressAt = Date(); sequence += 1
        progressWriting = true
        let number = sequence, position = lastPosition, paused = lastPaused, prior = writes
        writes = Task { [weak self] in
            defer { self?.progressWriting = false }
            await prior?.value
            do {
                let reply: SiloPlaybackAcknowledgement = try await client.transport.get(["playback", asset.lease.sessionID, "progress"], method: "POST",
                    body: ["installation_id": asset.lease.installationID, "sequence": number, "position": position, "is_paused": paused])
                guard ["applied", "replayed"].contains(reply.outcome), reply.accepted?.sequence == number else {
                    throw MediaIntegrationError.unavailable("Silo did not accept the current playback progress.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed?("Silo playback progress could not be synced. " + error.localizedDescription)
            }
        }
    }

    /// Debounce skips and drag release; one replan write at a time. A response
    /// lost after submission is surfaced, never blindly retried.
    func seek(to sourcePosition: Double) {
        guard !closed, retryTask == nil, sourcePosition.isFinite, sourcePosition >= 0 else { return }
        pendingSeek = sourcePosition
        isReplanning = true
        guard seekTask == nil else { return }
        seekTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            defer { self.seekTask = nil; self.isReplanning = false }
            while let target = self.pendingSeek, !self.closed {
                self.pendingSeek = nil; self.isReplanning = true
                do {
                    let prepared = try await self.reanchor(target)
                    self.asset = prepared
                    if self.closed { return }
                    if self.pendingSeek == nil {
                        self.lastPosition = target
                        self.isReplanning = false
                        self.assetChanged?(prepared)
                    }
                } catch {
                    self.pendingSeek = nil
                    self.failed?(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func reanchor(_ position: Double) async throws -> SiloPlaybackAsset {
        guard let client, let asset, let plan = asset.decision.playback_plan else { throw MediaIntegrationError.disconnected }
        await writes?.value
        let selected = (plan.selected_tracks ?? [:]).mapValues { track -> [String: Any] in
            var value: [String: Any] = [:]
            if let id = track.id { value["id"] = id }
            if let index = track.index { value["index"] = index }
            return value
        }
        let body: [String: Any] = ["installation_id": installationID, "protocol_version": 3,
            "client_features": features, "operation": "seek_reanchor", "playback_attempt_id": attemptID,
            "replan_request_id": UUID().uuidString, "failed_plan_id": plan.plan_id, "plan_attempt_id": UUID().uuidString,
            "plan_attempt_key": plan.plan_attempt_key, "attempted_plan_keys": [plan.plan_attempt_key], "attempt_count": 1,
            "quality_preference": "auto", "position_seconds": position, "selected_tracks": selected,
            "client_capabilities": capabilities, "client_playback_context": context]
        let decision: SiloPlaybackDecision = try await client.transport.get(["playback", asset.lease.sessionID, "replan"], method: "POST", body: body)
        mediaToken = await client.transport.currentCredential().accessToken
        return try makeAsset(decision)
    }

    func stop() async {
        guard !closed else { return }; closed = true
        defer {
            assetChanged = nil; failed = nil; preparing = nil; retryFailed = nil; retryAllowed = nil
            sidecars = []
        }
        heartbeat?.cancel(); heartbeat = nil; pendingSeek = nil
        await seekTask?.value
        await writes?.value
        guard let asset, let client else { return }
        self.asset = nil
        do { try await stopAsset(asset, client: client, position: lastPosition, paused: lastPaused) }
        catch { failed?("Silo could not confirm the playback stop. " + error.localizedDescription) }
    }

    private func stopAsset(_ asset: SiloPlaybackAsset, client: SiloClient, position: Double, paused: Bool) async throws {
        sequence += 1
        let reply: SiloPlaybackAcknowledgement = try await client.transport.get(["playback", asset.lease.sessionID], method: "DELETE",
            body: ["installation_id": asset.lease.installationID, "stop_id": UUID().uuidString.lowercased(), "sequence": sequence,
                "position": position, "is_paused": paused])
        guard ["stopped", "replayed"].contains(reply.outcome) else { throw MediaIntegrationError.invalidResponse }
    }

    private static func playerCapabilities() -> (capabilities: [String: Any], context: [String: Any]) {
        #if os(tvOS)
        let platform = "tvos", form = "tv"
        #else
        let platform = "ios", form = "phone"
        #endif
        // Every engine Lineup plays Silo with -- VLC, MPV and Aether -- is
        // built on FFmpeg and decodes in software what the chip cannot. The
        // declaration used to be AVPlayer's short list: H.264 and HEVC, four
        // audio formats, no HDR. A film with DTS or TrueHD, an AV1 or VP9
        // encode, or HDR then needed converting, and a Silo server with
        // conversion off had no way to send it at all.
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let hardware = ["h264"] + (hevc ? ["hevc"] : []) + (av1 ? ["av1"] : [])
        let video = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "vc1"]
        let audio = ["aac", "mp3", "ac3", "eac3", "flac", "alac", "opus", "vorbis", "mp2",
                     "dts", "truehd", "pcm_s16le", "pcm_s24le"]
        let containers = ["mp4", "mov", "m4v", "mkv", "matroska", "webm", "mpegts", "ts", "m2ts", "avi"]
        let capabilities: [String: Any] = ["video_evidence": "declared", "audio_evidence": "declared",
            "codecs_video": video, "codecs_video_hardware": hardware, "codecs_audio": audio,
            "containers": containers, "hdr": true, "max_resolution": "2160p"]
        func delivery(_ formats: [String], claims: [String] = []) -> [String: Any] {
            ["enabled": true, "supported_on_device": true, "containers": formats, "video_codecs": video,
                "audio_decode_codecs": audio, "audio_passthrough_codecs": [],
                // The engines draw styled subtitles themselves.
                "subtitles": ["embedded_text": true, "sidecar_text": false, "ass_styling": true,
                    "embedded_bitmap": true, "sidecar_bitmap": false, "font_attachments": false],
                "features": [], "auth_header_refresh": false, "validated_claims": claims, "transformations": []]
        }
        // Keyed by delivery class: the file as it is, a remux sent as one
        // stream, and HLS in either segment container.
        //
        // The file as it is goes to an engine that reads its HDR10, HLG or
        // Dolby Vision itself and shows it on whatever screen is attached,
        // as it does a file from any other server. Saying so lets Silo send
        // a 4K HDR film untouched. Without it, Silo would send HDR only to a
        // player that had named the screen's HDR formats, and Lineup names
        // none: it asked Silo to convert every HDR film, which a server with
        // conversion off -- or 4K conversion off, as most are -- refused,
        // while the same film played at 1080p, in SDR.
        let context: [String: Any] = ["protocol_version": 3, "form_factor": form,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.19.0",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "device": ["platform": platform, "manufacturer": "Apple", "model": UIDevice.current.model, "os_version": UIDevice.current.systemVersion],
            "output": [:], "deliveries": ["original_http": delivery(containers, claims: ["client_managed_dynamic_range_v1"]),
                                          "progressive": delivery(["mp4", "matroska", "mkv", "mpegts"]),
                                          "hls": delivery(["fmp4", "mp4", "mpegts", "ts"])]]
        return (capabilities, context)
    }
}

// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeshLink
import Syphon

/// Syphon の送り手たち。名前を `syphon:<アプリ名>/<サーバー名>` の形の映像として並べる。
///
/// 繋ぐのは、いずれかの領域がその映像を映しているときだけで、映さなくなったら切る。
/// 一覧は Syphon の公示 (distributed notification) で更新されるので、main の run loop が
/// 回っている必要がある (アプリでは回っている)。
@MainActor
final class SyphonSources {
    static let prefix = "syphon:"

    private let device: any MTLDevice
    private var clients: [String: SyphonMetalClient] = [:]

    init(device: any MTLDevice) {
        self.device = device
    }

    /// いま見えている Syphon の送り手の名前。
    var streams: [String] {
        SyphonServerDirectory.shared().servers.compactMap(Self.streamName).sorted()
    }

    static func isSyphon(_ stream: String) -> Bool { stream.hasPrefix(prefix) }

    private static func streamName(_ description: [String: Any]) -> String? {
        let app = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
        let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
        guard !(app.isEmpty && name.isEmpty) else { return nil }
        return "\(prefix)\(app)/\(name)"
    }

    /// 映している Syphon の映像それぞれの、新しい 1 枚を取る。新しいものが無い映像は入れない。
    func pull(_ wanted: Set<String>) -> [String: SourceFrame] {
        let wanted = wanted.filter(Self.isSyphon)
        // 映さなくなった・相手が消えたものを切る
        for (stream, client) in clients where !wanted.contains(stream) || !client.isValid {
            client.stop()
            clients[stream] = nil
        }
        var frames: [String: SourceFrame] = [:]
        for stream in wanted {
            guard let client = client(for: stream), client.hasNewFrame,
                let texture = client.newFrameImage()
            else { continue }
            frames[stream] = SourceFrame(syphon: texture, arrivedHostTime: HostTime.now())
        }
        return frames
    }

    func stopAll() {
        for client in clients.values { client.stop() }
        clients = [:]
    }

    private func client(for stream: String) -> SyphonMetalClient? {
        if let client = clients[stream] { return client }
        guard
            let description = SyphonServerDirectory.shared().servers.first(where: {
                Self.streamName($0) == stream
            })
        else { return nil }
        let client = SyphonMetalClient(
            serverDescription: description, device: device, options: nil, newFrameHandler: nil)
        guard client.isValid else { return nil }
        clients[stream] = client
        return client
    }
}

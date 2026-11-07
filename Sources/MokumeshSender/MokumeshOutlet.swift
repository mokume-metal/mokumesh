// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeshLink
import mokume

/// 出口 — フレーム 1 枚を、受け手の用意した面へ写して知らせる。
///
/// `OutputFrame.texture` は `receive` から戻ると次のフレームで上書きされるので、
/// ここで受け手の面へ 1 回 blit する。CPU は GPU の完了を待たない。blit が終わった
/// 知らせ (`addCompletedHandler`) の中で受け手へ FRAME を送る (ADR-0001 決定 3 の改訂)。
final class MokumeshOutlet: Outlet {
    let link: LinkSender

    private var queue: (any MTLCommandQueue)?
    /// 受け手の面を包んだ texture。面の組が変わったら作り直す。
    private var textures: [UInt32: any MTLTexture] = [:]
    private var texturesGeneration: UInt32?

    /// 発行口を作った回数。フレーム数によらず 1 のままであること。
    private(set) var queuesMade = 0
    /// 面を texture に包んだ回数。面の組が変わらない限り、面の枚数で止まること。
    private(set) var texturesMade = 0

    private(set) var failure: String?

    /// 送り出しの統計。GPU の完了の知らせから書くので錠で守る。
    let statistics = StatisticsBox()

    init(channel: String, stream: String) throws(LinkError) {
        link = try LinkSender(channel: channel, stream: stream)
    }

    func open() throws {}

    func receive(_ frame: OutputFrame) {
        autoreleasepool {
            let handed = HostTime.now()
            let source = frame.texture
            guard source.pixelFormat == .rgba8Unorm else {
                failure = "知らない画素の形式で絵が届いた (\(source.pixelFormat.rawValue))"
                return
            }
            link.prepare(width: frame.width, height: frame.height, format: .rgba8DisplayP3)
            // 受け手が居ない・面を待っている・空いている面が無い — どれも失敗ではない
            guard let slot = link.acquire() else {
                failure = nil
                return
            }
            guard let queue = queue(for: source.device),
                let target = texture(for: slot, device: source.device),
                let commands = queue.makeCommandBuffer(),
                let blit = commands.makeBlitCommandEncoder()
            else {
                link.abandon(slot)
                failure = "受け手の面へ写す支度ができなかった"
                return
            }
            blit.copy(from: source, to: target)
            blit.endEncoding()
            let link = self.link
            let number = frame.frame
            let time = frame.time
            let statistics = self.statistics
            commands.addCompletedHandler { buffer in
                if buffer.status == .completed {
                    statistics.addGPUTime(buffer.gpuEndTime - buffer.gpuStartTime)
                    link.publish(slot, frame: number, time: time, handedHostTime: handed)
                } else {
                    link.abandon(slot)
                }
            }
            commands.commit()
            failure = nil
        }
    }

    func close() {
        link.close()
        textures = [:]
        texturesGeneration = nil
    }

    // MARK: - 支度

    private func queue(for device: any MTLDevice) -> (any MTLCommandQueue)? {
        if let queue { return queue }
        guard let queue = device.makeCommandQueue() else { return nil }
        queue.label = "mokumesh.send"
        self.queue = queue
        queuesMade += 1
        return queue
    }

    private func texture(for slot: LinkSender.Slot, device: any MTLDevice) -> (any MTLTexture)? {
        if texturesGeneration != slot.generation {
            textures = [:]
            texturesGeneration = slot.generation
        }
        if let texture = textures[slot.index] { return texture }
        let surface = slot.surface
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface), mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        textures[slot.index] = texture
        texturesMade += 1
        return texture
    }
}

/// 送り出しの統計を、スレッドをまたいで足していく箱。
final class StatisticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gpuSeconds: Double = 0
    private var gpuSamples = 0

    func addGPUTime(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        gpuSeconds += seconds
        gpuSamples += 1
    }

    var gpu: (seconds: Double, samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuSeconds, gpuSamples)
    }
}

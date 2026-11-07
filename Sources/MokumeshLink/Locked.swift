// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 錠で守った値。
///
/// `Synchronization.Mutex` は中身を `sending` で出し入れさせるので、IOSurface のように
/// `Sendable` を名乗らない (がスレッドをまたいでよい) 型を状態に持つと書けなくなる。
/// ここでは錠の内側だけで触ることを約束にして、検査を外す。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

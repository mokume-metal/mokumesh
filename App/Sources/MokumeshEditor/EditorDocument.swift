// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshMapping
import Observation

/// 編集している設定 1 つ (ADR-0003 決定 2)。
///
/// 設定を変える口は `perform` だけで、取り消しの登録・未保存の印・検証・変更の知らせを
/// ここでまとめて扱う。ドラッグのように続けて変えるものは `beginGesture` / `endGesture` で
/// 挟み、取り消しを 1 回にまとめる。
///
/// 取り消しは設定の値の snapshot で持つ (設定は小さな値型である)。
@MainActor
@Observable
public final class EditorDocument {
    /// いまの設定。変えるのは `perform` だけ。
    public private(set) var config: MappingConfig
    /// 変わるたびに 1 つ増える (取り消し・やり直し・読み込みでも)。描き直しの目安に使う。
    public private(set) var revision = 0
    /// 読み書きするファイル。
    public private(set) var fileURL: URL?
    /// 最後に読んだ・保存した設定。いまの設定と違えば未保存。
    private var savedConfig: MappingConfig

    /// 取り消しの登録先。窓の側が持つものを渡す (操作窓と出力の窓で 1 つを共有する)。
    @ObservationIgnored public var undoManager: UndoManager?

    /// 変わったあとに呼ぶ (前の設定・いまの設定)。窓の開け閉めのように、ビューの外で
    /// 追従するものがここで受ける。
    @ObservationIgnored private var changeHandlers: [(MappingConfig, MappingConfig) -> Void] = []

    /// 続けて変えている途中なら、その始まりの設定と名前。
    @ObservationIgnored private var gesture: (start: MappingConfig, actionName: String)?

    public init(config: MappingConfig = MappingConfig(), fileURL: URL? = nil) {
        self.config = config
        self.fileURL = fileURL
        savedConfig = config
    }

    /// 保存していない変更があるか。
    public var isDirty: Bool { config != savedConfig }

    /// 続けて変えている途中か。
    public var isInGesture: Bool { gesture != nil }

    /// 変わったことを受ける。
    public func observeChanges(_ handler: @escaping (_ old: MappingConfig, _ new: MappingConfig) -> Void) {
        changeHandlers.append(handler)
    }

    // MARK: - 変える

    /// 設定を変える。映せない形 (`MappingConfig.validate` が断るもの) になる変更は採らない。
    ///
    /// - Parameter actionName: 取り消しのメニューに出す名前 (「面を消す」など)。
    /// - Returns: 変わったか (何も変わらない・映せない形になるなら `false`)。
    @discardableResult
    public func perform(_ actionName: String, _ body: (inout MappingConfig) -> Void) -> Bool {
        var next = config
        body(&next)
        guard next != config, (try? next.validate()) != nil else { return false }
        if gesture == nil { registerUndo(restoring: config, actionName: actionName) }
        set(next)
        return true
    }

    /// 続けて変え始める (ドラッグの始まり)。`endGesture` までの `perform` は、取り消し 1 回にまとまる。
    public func beginGesture(_ actionName: String) {
        if gesture != nil { endGesture() }
        gesture = (config, actionName)
    }

    /// 続けて変えるのを終える。始まりから変わっていれば、取り消しを 1 回登録する。
    public func endGesture() {
        guard let gesture else { return }
        self.gesture = nil
        if config != gesture.start { registerUndo(restoring: gesture.start, actionName: gesture.actionName) }
    }

    // MARK: - 読み書き

    /// ファイルから読み、取り消しの履歴を捨てる。
    public func load(from url: URL) throws {
        let loaded = try MappingConfig.decode(Data(contentsOf: url))
        replace(with: loaded, fileURL: url)
    }

    /// 設定を丸ごと差し替え、保存済みとして扱う (取り消しの履歴は捨てる)。
    public func replace(with config: MappingConfig, fileURL: URL?) {
        gesture = nil
        undoManager?.removeAllActions(withTarget: self)
        self.fileURL = fileURL
        savedConfig = config
        set(config)
    }

    /// ファイルに書き、保存済みにする。
    public func save(to url: URL) throws {
        try config.encode().write(to: url, options: .atomic)
        fileURL = url
        savedConfig = config
    }

    // MARK: - 中身

    private func set(_ next: MappingConfig) {
        let old = config
        config = next
        revision += 1
        for handler in changeHandlers { handler(old, next) }
    }

    /// `previous` へ戻す取り消しを登録する。取り消しの最中に呼べば、やり直しとして積まれる。
    private func registerUndo(restoring previous: MappingConfig, actionName: String) {
        guard let undoManager else { return }
        // 1 回ずつ group で閉じる。イベントごとの group (`groupsByEvent`) の中では入れ子になり、
        // 同じイベントで変えたものは 1 回の取り消しにまとまる
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.registerUndo(restoring: document.config, actionName: actionName)
                document.gesture = nil
                document.set(previous)
            }
        }
        undoManager.setActionName(actionName)
    }
}

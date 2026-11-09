// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// 操作窓の中央。2×2 のペインと、下端の知らせ。
struct WorkspaceContentView: View {
    let context: AppContext

    var body: some View {
        VStack(spacing: 0) {
            PaneGrid(context: context)
            Divider()
            StatusBar(context: context)
        }
    }
}

/// 2×2 のペイン。枠は `PaneLayout` が求め、ここは置くだけ (仕切りのドラッグ・最大化・畳み)。
struct PaneGrid: View {
    let context: AppContext
    private let metrics = PaneLayout.Metrics(header: 26, divider: 1, minimum: 140)

    private var session: EditorSession { context.session }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let layout = session.paneLayout
            let frames = layout.frames(width: size.width, height: size.height, metrics: metrics)
            ZStack(alignment: .topLeading) {
                Color(nsColor: .separatorColor)
                ForEach(PaneKind.allCases) { kind in
                    if let frame = frames[kind] {
                        PaneChrome(context: context, kind: kind) { pane(kind) }
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.x, y: frame.y)
                    }
                }
                if layout.maximized == nil {
                    dividers(size: size, layout: layout)
                }
            }
            .coordinateSpace(name: Self.space)
        }
    }

    private static let space = "pane-grid"

    @ViewBuilder
    private func pane(_ kind: PaneKind) -> some View {
        switch kind {
        case .input: InputPane(context: context)
        case .stage: StagePane(context: context)
        case .projectors: ProjectorLayoutPane(context: context)
        case .output: OutputPane(context: context)
        }
    }

    /// 仕切りのつかみ。見た目の線 (1 point) より広く掴めるようにする。
    @ViewBuilder
    private func dividers(size: CGSize, layout: PaneLayout) -> some View {
        let grip: Double = 8
        let left = layout.columnWidth(width: size.width, metrics: metrics)
        handle(cursor: .resizeLeftRight)
            .frame(width: grip, height: size.height)
            .offset(x: left + metrics.divider / 2 - grip / 2)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space)).onChanged { value in
                    session.paneLayout.dragColumnDivider(to: value.location.x, width: size.width, metrics: metrics)
                })
        ForEach(0..<PaneLayout.columns.count, id: \.self) { column in
            let x = column == 0 ? 0 : left + metrics.divider
            let width = column == 0 ? left : size.width - left - metrics.divider
            let top = layout.topHeight(column: column, height: size.height, metrics: metrics)
            handle(cursor: .resizeUpDown)
                .frame(width: width, height: grip)
                .offset(x: x, y: top + metrics.divider / 2 - grip / 2)
                .gesture(
                    DragGesture(coordinateSpace: .named(Self.space)).onChanged { value in
                        session.paneLayout.dragRowDivider(
                            column: column, to: value.location.y, height: size.height, metrics: metrics)
                    })
        }
    }

    private func handle(cursor: NSCursor) -> some View {
        Color.clear.contentShape(Rectangle()).onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

/// ペイン 1 つの見出しと中身。見出しのダブルクリックで最大化、ボタンで畳む・最大化する。
struct PaneChrome<Content: View>: View {
    let context: AppContext
    let kind: PaneKind
    @ViewBuilder let content: () -> Content

    private var session: EditorSession { context.session }

    var body: some View {
        let collapsed = session.paneLayout.collapsed.contains(kind)
        let maximized = session.paneLayout.maximized == kind
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    session.paneLayout.toggleCollapsed(kind)
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 12)
                }
                .buttonStyle(.borderless)
                .disabled(maximized)
                .help(collapsed ? "開く" : "畳む")
                Text(kind.title).font(.callout.weight(.semibold))
                Spacer()
                Button {
                    session.paneLayout.toggleMaximized(kind)
                } label: {
                    Image(
                        systemName: maximized
                            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(maximized ? "元に戻す" : "最大化")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { session.paneLayout.toggleMaximized(kind) }
            if !collapsed {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .clipped()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 操作窓の下端。受け手の状態・見つからない表示装置・最後の知らせ。
struct StatusBar: View {
    let context: AppContext

    var body: some View {
        HStack(spacing: 12) {
            Label("チャンネル \(context.document.config.channel)", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            if let error = context.status.receiverError {
                Text(error).foregroundStyle(.red)
            }
            let missing = context.session.missingDisplays.map(\.display.name)
            if !missing.isEmpty {
                Label("見つからない表示装置: \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }
            Spacer()
            if let message = context.status.message {
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

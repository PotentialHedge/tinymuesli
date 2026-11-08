import SwiftUI

/// Content with an inspector on its right, laid out by SwiftUI itself rather than `.inspector`.
/// SwiftUI's `.inspector` widened the window by the inspector's width each time it opened and
/// never gave it back, and on macOS 27 it relays the window in a loop when a divider is dragged.
/// AppKit's split view hosted in SwiftUI fared no better: the two fought over the panes' sizes.
///
/// Here the content gives way to the inspector, as in Finder or Xcode; the window grows only when
/// the content would go below its minimum. The inspector slides in and out when `isPresented`
/// changes inside an animation. Drag its edge to resize it; the width is remembered.
struct InspectorPanel<Content: View, Inspector: View>: View {
    @Binding var isPresented: Bool
    var contentMinWidth: CGFloat
    var widths: ClosedRange<CGFloat>
    @AppStorage var storedWidth: Double
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    @State private var totalWidth: CGFloat = 0
    /// The inspector's width when the drag began.
    @State private var dragStart: CGFloat?

    init(isPresented: Binding<Bool>, contentMinWidth: CGFloat, widths: ClosedRange<CGFloat>, idealWidth: CGFloat,
         widthKey: String, @ViewBuilder content: () -> Content, @ViewBuilder inspector: () -> Inspector) {
        _isPresented = isPresented
        self.contentMinWidth = contentMinWidth
        self.widths = widths
        _storedWidth = AppStorage(wrappedValue: idealWidth, widthKey)
        self.content = content()
        self.inspector = inspector()
    }

    /// The stored width, narrowed to leave the content its minimum.
    private var width: CGFloat {
        let room = totalWidth > 0 ? totalWidth - contentMinWidth - 1 : .infinity
        return max(widths.lowerBound, min(CGFloat(storedWidth), widths.upperBound, room))
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(minWidth: contentMinWidth, maxWidth: .infinity)
            Divider()
                .opacity(isPresented ? 1 : 0)
            // Laid out at its full width while it slides, so only its visible part changes and
            // nothing inside reflows on each frame. Gone once closed, so its .onDisappear runs.
            ZStack(alignment: .leading) {
                if isPresented {
                    inspector
                        // Smaller controls, as .inspector draws them.
                        .controlSize(.small)
                        .frame(width: width)
                        // Stays while it slides out.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .frame(width: isPresented ? width : 0, alignment: .leading)
            .clipped()
        }
        .overlay(alignment: .trailing) {
            if isPresented { resizeHandle }
        }
        // The window's minimum: the content's, plus the narrowest inspector while it's open.
        .frame(minWidth: contentMinWidth + (isPresented ? widths.lowerBound + 1 : 0))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { totalWidth = $0 }
    }

    /// A strip over the inspector's left edge that resizes it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? width
                        dragStart = start
                        let room = totalWidth - contentMinWidth - 1
                        storedWidth = Double(max(widths.lowerBound, min(start - drag.translation.width, widths.upperBound, room)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .padding(.trailing, width - 4)
    }
}

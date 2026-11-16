import SwiftUI
import AppKit

extension View {
    /// An opaque backing for text that floats over a terminal. A translucent material takes on whatever is behind
    /// it, a dark terminal included, which left grey text unreadable in light mode.
    func solidPanel<S: InsettableShape>(_ shape: S) -> some View {
        self
            .foregroundStyle(.primary)
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(.separator))
    }
}

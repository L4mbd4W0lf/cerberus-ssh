import SwiftUI

extension Color {
    /// This colour at `base` opacity, or much stronger when the person has turned on Increase Contrast.
    /// Tinted selection and highlight fills are drawn at a low opacity that the system's own controls
    /// do not follow, so without this they would vanish for exactly the people who asked for more contrast.
    func fill(_ base: Double, _ contrast: ColorSchemeContrast) -> Color {
        opacity(contrast == .increased ? min(1, base * 2.5) : base)
    }
}

extension View {
    /// Dims the text and plain symbols inside when the window is not the key one, as the sidebar does by itself.
    /// The rest of the window has to ask: a plain area keeps its colours. Inside, use `.primary` and `.secondary`
    /// rather than `Color.primary` and `Color.secondary`, which are fixed and would not dim. Tints (folder blue,
    /// status colours) stay, as they do in the sidebar.
    func dimsWhenInactive() -> some View { modifier(DimsWhenInactive()) }
}

private struct DimsWhenInactive: ViewModifier {
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        // One modifier either way, not an `if`: swapping views would throw away the state of everything inside.
        // Each level is given its own strength, matched to the sidebar's: derived from one dimmed colour, the
        // secondary text (sizes, dates) faded almost to nothing.
        let inactive = activeState == .inactive
        content.foregroundStyle(
            inactive ? AnyShapeStyle(Color.primary.opacity(0.42)) : AnyShapeStyle(.primary),
            inactive ? AnyShapeStyle(Color.primary.opacity(0.3)) : AnyShapeStyle(.secondary),
            inactive ? AnyShapeStyle(Color.primary.opacity(0.2)) : AnyShapeStyle(.tertiary)
        )
    }
}

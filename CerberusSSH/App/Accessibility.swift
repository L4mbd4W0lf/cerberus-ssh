import SwiftUI

extension Color {
    /// This colour at `base` opacity, or much stronger when the person has turned on Increase Contrast.
    /// Tinted selection and highlight fills are drawn at a low opacity that the system's own controls
    /// do not follow, so without this they would vanish for exactly the people who asked for more contrast.
    func fill(_ base: Double, _ contrast: ColorSchemeContrast) -> Color {
        opacity(contrast == .increased ? min(1, base * 2.5) : base)
    }
}

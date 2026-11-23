import SwiftUI
import CerberusModels

extension NodeColor {
    /// The colour on screen, from the asset catalog (Node… colours, with light and dark values).
    var color: Color {
        switch self {
        case .red: .nodeRed
        case .orange: .nodeOrange
        case .yellow: .nodeYellow
        case .green: .nodeGreen
        case .teal: .nodeTeal
        case .blue: .nodeBlue
        case .purple: .nodePurple
        case .pink: .nodePink
        case .graphite: .nodeGraphite
        }
    }
}

/// A folder's colour as a small mark beside a name, or several colours as a gradient from top to bottom (a tab whose
/// panes are from different groups). Always with the colours' names in the tooltip, so the colour is never the only
/// thing that says it.
struct NodeColorMark: View {
    let colors: [NodeColor]
    var width: CGFloat = 3
    var height: CGFloat = 14

    init(color: NodeColor, width: CGFloat = 3, height: CGFloat = 14) {
        self.init(colors: [color], width: width, height: height)
    }

    init(colors: [NodeColor], width: CGFloat = 3, height: CGFloat = 14) {
        self.colors = colors
        self.width = width
        self.height = height
    }

    private var names: String { colors.map(\.displayName).joined(separator: ", ") }

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: colors.map(\.color), startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: height)
            .help(names)
            .accessibilityLabel(names)
    }
}

/// The colours to choose from, as a row of swatches, with one for "none" (inherit from the folder above).
struct NodeColorPicker: View {
    @Binding var tag: String?
    /// What "none" means here, shown under the row: the colour inherited, or that there is none.
    var inherited: NodeColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                swatch(nil)
                ForEach(NodeColor.allCases, id: \.self) { swatch($0) }
            }
            Text(tag == nil ? (inherited.map { "No colour of its own: uses the \($0.displayName.lowercased()) of the folder above." } ?? "No colour.") : "")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func swatch(_ color: NodeColor?) -> some View {
        let selected = (tag == color?.rawValue)
        return Button { tag = color?.rawValue } label: {
            ZStack {
                Circle().fill(color?.color ?? Color.clear)
                if color == nil {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                    Image(systemName: "slash.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(color == nil ? Color.primary : Color.onHighlight) }
            }
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.6 : 0), lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .help(color?.displayName ?? "No colour")
        .accessibilityLabel(color?.displayName ?? "No colour")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("node-color-\(color?.rawValue ?? "none")")
    }
}

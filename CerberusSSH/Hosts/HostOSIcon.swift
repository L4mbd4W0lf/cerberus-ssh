import SwiftUI
import CerberusModels

/// The logo of the system a host runs, once a connection has found it out; the generic server symbol until then.
struct HostOSIcon: View {
    let os: OperatingSystem?
    /// Tint of the generic symbol. The logos keep their own colours.
    var fallbackTint: Color = .secondary

    var body: some View {
        if let os {
            Image(os.iconName)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(os.displayName)
        } else {
            Image(systemName: "server.rack")
                .foregroundStyle(fallbackTint)
        }
    }
}

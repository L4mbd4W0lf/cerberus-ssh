import CerberusModels
import CerberusTerminal
import CerberusVault
import SwiftData
import SwiftUI

struct ConnectionSettings: View {
    @AppStorage(ConnectionLogSettings.key) private var level = 0

    var body: some View {
        Form {

            Section("Connection log detail") {
                Picker("Verbosity", selection: $level) {
                    Text("Off  (basic steps only)").tag(0)
                    Text("Basic  (like ssh -v)").tag(1)
                    Text("Detailed  (like ssh -vv)").tag(2)
                    Text("Debug  (like ssh -vvv)").tag(3)
                }
                .pickerStyle(.radioGroup)

                Text(explanation)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Good to know") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "The Connection Log button in the toolbar is always available. It records the basic steps of every connection, even when this is Off.",
                        systemImage: "list.bullet.rectangle"
                    )
                    Label(
                        "Detailed and Debug record more in that log. Nothing is printed in the terminal.",
                        systemImage: "terminal"
                    )
                    Label(
                        "Applies to the next connection you open.",
                        systemImage: "arrow.clockwise"
                    )
                    Label(
                        "Passwords, passphrases, key material and environment values are never logged.",
                        systemImage: "lock.shield"
                    )
                    Label(
                        "The log shows what CerberusSSH observes. It is not a packet trace: the SSH library does not expose one.",
                        systemImage: "info.circle"
                    )
                    if level >= 2 {
                        Label(
                            "Detailed and Debug make one extra, unauthenticated connection to read the server's algorithm list.",
                            systemImage: "network"
                        )
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        switch level {
        case 1:
            "Connection steps: host key, authentication methods tried, channel requests, and how the session ended."
        case 2:
            "Adds the server's identification and algorithm lists, which of them CerberusSSH can use, and request details."
        case 3:
            "Adds state changes, socket options, and flow control (output throttling). Each line is timestamped in the saved log."
        default:
            "Only the basic connection steps are recorded in the toolbar log."
        }
    }
}

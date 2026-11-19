import SwiftUI
import SwiftData
import Observation
import CerberusModels
import CerberusVault
import CerberusSSHCore

/// Typing into several panes at once.
extension AppModel {
    // MARK: Broadcast input

    func isBroadcasting(tab tabID: UUID) -> Bool { broadcastSets[tabID] != nil }

    func broadcastMembers(in tabID: UUID) -> Set<UUID> { broadcastSets[tabID] ?? [] }

    /// Starts or stops broadcasting in a tab. Starting includes every pane; the user then
    /// unticks the ones to leave out.
    func toggleBroadcast(inTab tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if broadcastSets[tabID] == nil {
            broadcastSets[tabID] = Set(tab.layout.leaves)
        } else {
            broadcastSets[tabID] = nil
        }
    }

    /// Toggles broadcast for the active window's selected tab (⇧⌘B).
    func toggleBroadcastForSelectedTab() {
        if let tab = selectedTab { toggleBroadcast(inTab: tab.id) }
    }

    func toggleBroadcastMembership(_ session: SessionViewModel, inTab tabID: UUID) {
        guard let set = broadcastSets[tabID] else { return }
        broadcastSets[tabID] = Broadcast.toggle(session.id, in: set)
    }

    /// Copies what was typed in `session` to the other broadcasting panes of its tab.
    func mirrorInput(_ bytes: [UInt8], from session: SessionViewModel) {
        guard let tab = tab(containing: session), let set = broadcastSets[tab.id] else { return }
        for id in Broadcast.targets(from: session.id, set: set, tabPanes: tab.layout.leaves) {
            guard let target = self.session(withID: id), target.isLive else { continue }
            Task {
                do { try await target.connection.send(bytes) } catch {
                    CerberusLog.warning("broadcast", "could not copy input to \(target.title): \(CerberusLog.describe(error))")
                }
            }
        }
    }

    /// Sends text (a snippet) to the focused pane, or to the whole broadcast group when the
    /// focused pane is part of one.
    func sendToGroup(_ bytes: [UInt8], from session: SessionViewModel) {
        guard let tab = tab(containing: session) else { return }
        let recipients = Broadcast.recipients(
            from: session.id, set: broadcastSets[tab.id] ?? [], tabPanes: tab.layout.leaves
        )
        for id in recipients {
            guard let target = self.session(withID: id), target.isLive else { continue }
            Task {
                do { try await target.connection.send(bytes) } catch {
                    CerberusLog.warning("broadcast", "could not copy input to \(target.title): \(CerberusLog.describe(error))")
                }
            }
        }
    }

    /// A pane that text can be sent to by hand: its session and where it is.
    struct PaneChoice: Identifiable {
        let id: UUID
        let title: String
        let tabTitle: String
    }

    /// Every live terminal pane, in tab order, for the snippet palette's "Choose panes…".
    func paneChoices() -> [PaneChoice] {
        tabs.flatMap { tab -> [PaneChoice] in
            let tabTitle = title(of: tab)
            return tab.layout.leaves.compactMap { id in
                guard let pane = session(withID: id), pane.isLive else { return nil }
                return PaneChoice(id: id, title: pane.title, tabTitle: tabTitle)
            }
        }
    }

    /// Sends text to exactly these panes, whatever tab or broadcast group they are in. A pane that
    /// has closed or lost its connection since is skipped.
    func sendToPanes(_ bytes: [UInt8], panes: Set<UUID>) {
        for id in panes {
            guard let target = session(withID: id), target.isLive else { continue }
            Task {
                do { try await target.connection.send(bytes) } catch {
                    CerberusLog.warning("snippet", "could not send to \(target.title): \(CerberusLog.describe(error))")
                }
            }
        }
    }

    /// How many panes a snippet would reach from `session`, for the palette to say so.
    func groupSize(for session: SessionViewModel) -> Int {
        guard let tab = tab(containing: session) else { return 1 }
        return Broadcast.recipients(from: session.id, set: broadcastSets[tab.id] ?? [], tabPanes: tab.layout.leaves).count
    }

    func pruneBroadcast(afterClosing tabID: UUID?) {
        for (id, set) in broadcastSets {
            guard let tab = tabs.first(where: { $0.id == id }) else { broadcastSets[id] = nil; continue }
            broadcastSets[id] = Broadcast.pruned(set, panes: tab.layout.leaves)
        }
        if let tabID, !tabs.contains(where: { $0.id == tabID }) { broadcastSets[tabID] = nil }
    }
}

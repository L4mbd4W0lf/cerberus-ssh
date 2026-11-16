import XCTest
import AppKit

/// Driving the system's save and open panels, which the app runs in-process (it is not sandboxed).
extension CerberusUITestCase {
    /// Types a path into the panel's "Go to the folder" sheet (⇧⌘G) and confirms it. In a save panel
    /// this moves to the folder; in an open panel a path to a file selects that file.
    func goToFolder(_ path: String) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let sheet = app.sheets["GoToWindow"].exists ? app.sheets["GoToWindow"] : app.dialogs.firstMatch.sheets.firstMatch
        let field = sheet.textFields["PathTextField"]
        wait(field, "the panel did not offer to go to a folder")
        field.typeKey("a", modifierFlags: .command)
        paste(path)
        field.typeKey(.return, modifierFlags: [])
        waitGone(field, "the panel did not take the path")
    }

    /// Saves in the save panel the app has open, to `directory`/`name`.
    func savePanel(directory: URL, name: String) {
        let panel = app.dialogs["save-panel"]
        wait(panel, "no save panel")
        goToFolder(directory.path)
        let field = panel.textFields["saveAsNameTextField"]
        replace(field, with: name)
        panel.buttons["OKButton"].click()
        waitGone(panel, "the save panel did not close")
    }

    /// Chooses `file` in the open panel the app has open.
    func openPanel(choose file: URL) {
        let panel = app.dialogs["open-panel"].exists ? app.dialogs["open-panel"] : app.dialogs.firstMatch
        wait(panel, "no open panel")
        goToFolder(file.path)
        panel.buttons["OKButton"].click()
        waitGone(panel, "the open panel did not close")
    }
}

/// Typing a long string key by key costs about a tenth of a second a character, and a test types
/// passphrases and paths. Pasting it is instant. The person's clipboard is put back afterwards.
extension CerberusUITestCase {
    /// Pastes `text` into whatever has the keyboard.
    func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.25)   // let the app read it before it is put back
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    /// Clicks `field` and enters `text`: typed if it is short, pasted if it is not.
    func enter(_ text: String, in field: XCUIElement) {
        field.click()
        if text.count <= 8 { field.typeText(text) } else { paste(text) }
    }

    /// Replaces whatever `field` holds with `text`.
    func replace(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if text.count <= 8 { field.typeText(text) } else { paste(text) }
    }
}

import XCTest

/// Settings ▸ Advanced ▸ Migration backups: the copies made before a migration, listed with the version each came
/// from, and put back or removed. (The catalogue in a test is in memory, so the files are seeded; what writes a
/// real one, and the restore itself, are covered by the package tests.)
final class MigrationBackupsTests: CerberusUITestCase {
    private func element(_ id: String) -> XCUIElement {
        settingsWindow.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func open() {
        launch()
        openSettings(tab: "Advanced")
        wait(settingsWindow.staticTexts["Migration backups"], "the section is not there")
    }

    @MainActor func testWithNoBackupsTheSectionSaysSoAndOffersNothingToDelete() {
        open()
        wait(element("migration-backups-empty"))
        XCTAssertFalse(element("migration-backups-delete-all").isEnabled)
    }

    @MainActor func testEachBackupIsListedByTheVersionItCameFrom() {
        options.migrationBackups = ["1.2.0", "1.3.0"]
        open()
        wait(element("migration-backup-1.3.0"))
        wait(element("migration-backup-1.2.0"))
        wait(settingsWindow.staticTexts["From version 1.3.0"])
        wait(settingsWindow.staticTexts["From version 1.2.0"])
        XCTAssertFalse(element("migration-backups-empty").exists)
    }

    @MainActor func testDeletingOneBackupAsksFirstAndLeavesTheOthers() {
        options.migrationBackups = ["1.2.0", "1.3.0"]
        open()
        wait(element("migration-backup-delete-1.2.0"))
        element("migration-backup-delete-1.2.0").click()
        // Cancelling changes nothing.
        wait(element("migration-backups-confirm-delete"))
        settingsWindow.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(element("migration-backup-1.2.0").exists)

        element("migration-backup-delete-1.2.0").click()
        wait(element("migration-backups-confirm-delete"))
        element("migration-backups-confirm-delete").click()
        waitGone(element("migration-backup-1.2.0"), "the backup was not deleted")
        XCTAssertTrue(element("migration-backup-1.3.0").exists, "the other backup went too")
    }

    @MainActor func testDeleteAllClearsTheListAfterAsking() {
        options.migrationBackups = ["1.2.0", "1.3.0"]
        open()
        wait(element("migration-backups-delete-all"))
        element("migration-backups-delete-all").click()
        wait(element("migration-backups-confirm-delete-all"))
        element("migration-backups-confirm-delete-all").click()
        wait(element("migration-backups-empty"), "the list was not emptied")
        XCTAssertFalse(element("migration-backup-1.3.0").exists)
    }

    @MainActor func testReMigratingAtTheNextLaunchIsShownAndCanBeCancelled() {
        options.migrationBackups = ["1.3.0"]
        open()
        wait(element("migration-backup-remigrate-1.3.0"))
        element("migration-backup-remigrate-1.3.0").click()
        wait(element("migration-backups-remigrate-later"), "no choice of when to re-migrate")
        XCTAssertTrue(element("migration-backups-remigrate-quit").exists)
        element("migration-backups-remigrate-later").click()

        wait(element("migration-backups-pending"), "the waiting re-migrate is not shown")
        XCTAssertFalse(element("migration-backup-remigrate-1.3.0").isEnabled, "a second re-migrate can be started while one waits")
        element("migration-backups-cancel-pending").click()
        waitGone(element("migration-backups-pending"))
        XCTAssertTrue(element("migration-backup-remigrate-1.3.0").isEnabled)
    }
}

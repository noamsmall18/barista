import Cocoa

/// Handles export/import of widget profiles as .barista JSON files.
class ProfileExporter {

    struct ExportedProfile: Codable {
        let version: Int
        let name: String
        let widgets: [ExportedWidget]
        let appearance: MenuBarAppearance?
        let exportDate: Date
    }

    struct ExportedWidget: Codable {
        let widgetID: String
        let order: Int
        let configData: Data?
    }

    // MARK: - Export

    /// Export the current widget layout to a file.
    static func exportCurrent(name: String) {
        let widgets = WidgetStore.shared.loadActiveWidgets()
        let exported = ExportedProfile(
            version: 1,
            name: name,
            widgets: widgets.map { ExportedWidget(widgetID: $0.widgetID, order: $0.order, configData: $0.configData) },
            appearance: MenuBarAppearance.load(),
            exportDate: Date()
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(name).barista.json"
        panel.title = "Export Profile"
        panel.message = "Save your Barista widget layout"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exported)
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Export a specific profile to a file.
    static func export(profile: WidgetProfile) {
        let exported = ExportedProfile(
            version: 1,
            name: profile.name,
            widgets: profile.widgets.map { ExportedWidget(widgetID: $0.widgetID, order: $0.order, configData: $0.configData) },
            appearance: profile.appearance,
            exportDate: Date()
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).barista.json"
        panel.title = "Export Profile"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exported)
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Import

    /// Import a profile from a .barista.json file.
    /// Returns the imported profile name, or nil on failure/cancel.
    @discardableResult
    static func importProfile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Import Profile"
        panel.message = "Select a Barista profile to import"
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ExportedProfile.self, from: data)

            // Validate version
            guard decoded.version == 1 else {
                showError("This profile was created with a newer version of Barista.")
                return nil
            }

            // Validate widgets exist in registry
            let registry = WidgetRegistry.shared
            let validWidgets = decoded.widgets.filter { registry.entry(for: $0.widgetID) != nil }

            if validWidgets.isEmpty {
                showError("None of the widgets in this profile are available.")
                return nil
            }

            let skipped = decoded.widgets.count - validWidgets.count

            // Create saved widgets
            let savedWidgets = validWidgets.enumerated().map { (i, w) in
                SavedWidget(instanceID: UUID(), widgetID: w.widgetID, order: i, configData: w.configData, isEnabled: true)
            }

            // Save as a named profile
            let profile = WidgetProfile(name: decoded.name, widgets: savedWidgets, appearance: decoded.appearance, icon: "square.and.arrow.down")
            ProfileManager.shared.save(profile: profile)

            // Ask if user wants to activate now
            let alert = NSAlert()
            alert.messageText = "Profile Imported"
            var info = "\"\(decoded.name)\" with \(validWidgets.count) widgets has been saved."
            if skipped > 0 {
                info += " (\(skipped) widget\(skipped == 1 ? "" : "s") skipped - not available in this version)"
            }
            alert.informativeText = info
            alert.addButton(withTitle: "Activate Now")
            alert.addButton(withTitle: "Save Only")
            alert.alertStyle = .informational

            if alert.runModal() == .alertFirstButtonReturn {
                ProfileManager.shared.activate(id: profile.id)
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.statusBarController.removeAllWidgets()
                    delegate.statusBarController.syncMenuBar()
                    delegate.rebuildSettingsUI()
                }
            }

            return decoded.name
        } catch {
            showError("Could not read this file: \(error.localizedDescription)")
            return nil
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

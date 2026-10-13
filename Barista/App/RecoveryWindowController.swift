import Cocoa
import UniformTypeIdentifiers

/// Recovery is available even when no widget can be loaded. Its operations are
/// injected so the complete native restore flow can run with disposable data.
final class RecoveryWindowController: NSWindowController {
    private let store: RecoveryStore
    private let prepareRestore: () -> Void
    private let willRestore: () -> Void
    private let didRestore: () -> Void
    private let confirmRestore: ((RecoveryStore.Backup) -> Bool)?
    private let picker = NSPopUpButton()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let previewScroll = NSScrollView()
    private let previewDocument = FlippedView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(title: "Restore Selected Backup…", target: nil, action: nil)
    private var choices: [RecoveryStore.Backup] = []

    init(store: RecoveryStore, prepareRestore: @escaping () -> Void = {}, willRestore: @escaping () -> Void = {}, didRestore: @escaping () -> Void = {},
         confirmRestore: ((RecoveryStore.Backup) -> Bool)? = nil) {
        self.store = store
        self.prepareRestore = prepareRestore
        self.willRestore = willRestore
        self.didRestore = didRestore
        self.confirmRestore = confirmRestore
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Backup & Recovery"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let root = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
                stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
            ])
        }
        let title = NSTextField(labelWithString: "Backup & Recovery")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)
        let explanation = NSTextField(wrappingLabelWithString:
            "Automatic backups keep all your app data.\nRestoring saves a backup so you can undo it.")
        explanation.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(explanation)
        picker.identifier = NSUserInterfaceItemIdentifier("recovery.backups")
        picker.target = self
        picker.action = #selector(selectionChanged)
        stack.addArrangedSubview(picker)
        picker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        details.identifier = NSUserInterfaceItemIdentifier("recovery.preview")
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.maximumNumberOfLines = 0
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.scrollerStyle = .overlay
        previewScroll.drawsBackground = false
        previewScroll.documentView = previewDocument
        previewDocument.addSubview(details)
        stack.addArrangedSubview(previewScroll)
        previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreButton.bezelStyle = .rounded
        restoreButton.identifier = NSUserInterfaceItemIdentifier("recovery.restore")
        let restoreActions = NSStackView(views: [restoreButton, makeButton("Back Up Now", #selector(backUpNow))])
        restoreActions.spacing = 8
        stack.addArrangedSubview(restoreActions)
        let actions = NSStackView(views: [makeButton("Save Backup File…", #selector(exportBackup)),
                                        makeButton("Open Backup File…", #selector(importBackup))])
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        let footer = NSTextField(wrappingLabelWithString:
            "Save a backup file on another drive for recovery if your Mac is lost or fails.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
        status.identifier = NSUserInterfaceItemIdentifier("recovery.status")
        status.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(status)
        for view in [explanation, footer, status] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reload()
        showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    func reload() {
        do {
            choices = try store.backups()
            picker.removeAllItems()
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            for backup in choices {
                picker.addItem(withTitle: formatter.string(from: backup.archive.createdAt) + " · " + backup.archive.reason)
            }
            if choices.isEmpty { picker.addItem(withTitle: "No usable backups yet") }
            if let previous = choices.firstIndex(where: { !store.matchesCurrent($0) }) {
                picker.selectItem(at: previous)
            }
            picker.isEnabled = !choices.isEmpty
            selectionChanged()
            if let problem = store.currentDataProblem() {
                status.stringValue = "Your saved data could not be loaded. It has been preserved. Choose a usable backup. " + problem
            } else if let error = store.lastError {
                status.stringValue = "Automatic backup needs attention: " + error
            }
        } catch { showError(error) }
    }

    @objc private func selectionChanged() {
        restoreButton.isEnabled = choices.indices.contains(picker.indexOfSelectedItem)
        details.stringValue = restoreButton.isEnabled ? choices[picker.indexOfSelectedItem].summary : "Click Back Up Now to create your first recovery point. Damaged or incompatible backups are never used to replace your data."
        // A long portfolio list scrolls inside the compact window.
        window?.contentView?.layoutSubtreeIfNeeded()
        let width = previewScroll.contentSize.width
        let height = max(100, details.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 100)
        previewDocument.frame = NSRect(x: 0, y: 0, width: width, height: height)
        details.frame = previewDocument.bounds
        previewScroll.contentView.scroll(to: .zero)
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    @objc private func backUpNow() {
        do {
            prepareRestore()
            _ = try store.capture(reason: "Manual backup", kept: true, force: true)
            reload()
            status.stringValue = "Backup saved. You can restore it from this list at any time."
        } catch { showError(error) }
    }

    @objc private func restoreSelected() {
        guard choices.indices.contains(picker.indexOfSelectedItem) else { return }
        restore(choices[picker.indexOfSelectedItem])
    }

    private func restore(_ backup: RecoveryStore.Backup) {
        let approved: Bool
        if let confirmRestore { approved = confirmRestore(backup) }
        else {
            let alert = NSAlert()
            alert.messageText = "Restore this backup?"
            alert.informativeText = backup.summary + "\n\nThis replaces the app’s current saved data. A backup of your current data will be kept as “Before restore — undo this restore”."
            alert.addButton(withTitle: "Restore Backup")
            alert.addButton(withTitle: "Cancel")
            approved = alert.runModal() == .alertFirstButtonReturn
        }
        guard approved else { return }
        do {
            // Recheck the selected file after the confirmation dialog.
            guard try store.preview(backup.url).archive.checksum == backup.archive.checksum else {
                throw RecoveryStore.RecoveryError.invalid("The backup changed while it was open. Select it again.")
            }
            prepareRestore()
            willRestore()
            defer { didRestore() }
            _ = try store.restore(backup.url)
            reload()
            status.stringValue = "Restored successfully. To undo, select “Before restore — undo this restore”."
        } catch { showError(error) }
    }

    @objc private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppFlavor.current.displayName)-Backup.marketbarbackup"
        panel.allowedContentTypes = [UTType(filenameExtension: "marketbarbackup") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            prepareRestore()
            try store.export(to: url)
            reload()
            status.stringValue = "Backup file saved. Keep a copy somewhere safe."
        } catch { showError(error) }
    }

    @objc private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { restore(try store.preview(url)) }
        catch { showError(error) }
    }

    private func showError(_ error: Error) {
        status.stringValue = "Recovery could not finish: " + error.localizedDescription
    }
}

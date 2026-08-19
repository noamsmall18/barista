import Cocoa

/// Handler for declarative toggle switches in config panels
class DeclToggleHandler: NSObject {
    let set: (Bool) -> Void
    weak var instance: WidgetInstance?
    weak var delegate: AppDelegate?

    init(set: @escaping (Bool) -> Void, instance: WidgetInstance, delegate: AppDelegate) {
        self.set = set
        self.instance = instance
        self.delegate = delegate
    }

    @objc func toggled(_ sender: NSSwitch) {
        set(sender.state == .on)
        guard let instance = instance else { return }
        if let data = instance.widget.getConfigData() {
            WidgetStore.shared.updateConfig(instanceID: instance.id, configData: data)
        }
        instance.updateStatusItem()
    }
}

/// Handler for declarative sliders in config panels
class DeclSliderHandler: NSObject {
    let set: (Double) -> Void
    weak var valLabel: NSTextField?
    let format: String
    let step: Double
    weak var instance: WidgetInstance?
    weak var delegate: AppDelegate?

    init(set: @escaping (Double) -> Void, valLabel: NSTextField, format: String, step: Double, instance: WidgetInstance, delegate: AppDelegate) {
        self.set = set
        self.valLabel = valLabel
        self.format = format
        self.step = step
        self.instance = instance
        self.delegate = delegate
    }

    @objc func slid(_ sender: NSSlider) {
        var value = sender.doubleValue
        if step >= 1 {
            value = (value / step).rounded() * step
        }
        set(value)
        valLabel?.stringValue = String(format: format, value)
        guard let instance = instance else { return }
        if let data = instance.widget.getConfigData() {
            WidgetStore.shared.updateConfig(instanceID: instance.id, configData: data)
        }
        instance.updateStatusItem()
    }
}

/// Handler for declarative text fields in config panels
class DeclTextHandler: NSObject, NSTextFieldDelegate {
    let set: (String) -> Void
    weak var instance: WidgetInstance?
    weak var delegate: AppDelegate?

    init(set: @escaping (String) -> Void, instance: WidgetInstance, delegate: AppDelegate) {
        self.set = set
        self.instance = instance
        self.delegate = delegate
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        set(field.stringValue)
        guard let instance = instance else { return }
        if let data = instance.widget.getConfigData() {
            WidgetStore.shared.updateConfig(instanceID: instance.id, configData: data)
        }
        instance.widget.refresh()
        instance.updateStatusItem()
    }
}

/// Handler for declarative popup buttons in config panels
class DeclPickerHandler: NSObject {
    let options: [(title: String, value: String)]
    let set: (String) -> Void
    weak var instance: WidgetInstance?
    weak var delegate: AppDelegate?

    init(options: [(title: String, value: String)], set: @escaping (String) -> Void, instance: WidgetInstance, delegate: AppDelegate) {
        self.options = options
        self.set = set
        self.instance = instance
        self.delegate = delegate
    }

    @objc func picked(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < options.count else { return }
        set(options[idx].value)
        guard let instance = instance else { return }
        if let data = instance.widget.getConfigData() {
            WidgetStore.shared.updateConfig(instanceID: instance.id, configData: data)
        }
        instance.widget.refresh()
        instance.updateStatusItem()
    }
}

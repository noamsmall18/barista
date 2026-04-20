import Cocoa

// Type-erased wrapper for BaristaWidget so we can store heterogeneous widgets
class AnyBaristaWidget {
    let widgetID: String
    let displayName: String
    let subtitle: String
    let iconName: String
    let category: WidgetCategory
    let isPremium: Bool

    // Store the underlying widget for type-specific access
    private let _underlying: AnyObject

    private let _start: () -> Void
    private let _stop: () -> Void
    private let _render: () -> WidgetDisplayMode
    private let _buildDropdownMenu: () -> NSMenu
    private let _buildConfigControls: (@escaping () -> Void) -> [NSView]
    private let _refreshInterval: () -> TimeInterval?
    private let _setOnDisplayUpdate: (@escaping () -> Void) -> Void
    private let _getConfigData: () -> Data?
    private let _setConfigData: (Data) -> Void
    private let _refresh: () -> Void

    // Cycleable support
    let isCycleable: Bool
    private let _itemCount: () -> Int
    private let _currentIndex: () -> Int
    private let _cycleInterval: () -> TimeInterval
    private let _cycleNext: () -> Void

    // InteractiveDropdown support
    let hasInteractiveDropdown: Bool
    private let _buildDropdownPopover: () -> NSView
    private let _dropdownSize: () -> NSSize

    func underlying<T: AnyObject>(as type: T.Type) -> T? {
        _underlying as? T
    }

    init<W: BaristaWidget>(_ widget: W) {
        self._underlying = widget
        self.widgetID = W.widgetID
        self.displayName = W.displayName
        self.subtitle = W.subtitle
        self.iconName = W.iconName
        self.category = W.category
        self.isPremium = W.isPremium

        _start = { widget.start() }
        _stop = { widget.stop() }
        _render = { widget.render() }
        _buildDropdownMenu = { widget.buildDropdownMenu() }
        _buildConfigControls = { widget.buildConfigControls(onChange: $0) }
        _refreshInterval = { widget.refreshInterval }
        _setOnDisplayUpdate = { callback in widget.onDisplayUpdate = callback }
        _getConfigData = { try? JSONEncoder().encode(widget.config) }
        _setConfigData = { data in
            if let config = try? JSONDecoder().decode(W.Config.self, from: data) {
                widget.config = config
            }
        }
        _refresh = {
            widget.stop()
            widget.start()
        }

        // Cycleable support
        if let cycleable = widget as? Cycleable {
            self.isCycleable = true
            _itemCount = { cycleable.itemCount }
            _currentIndex = { cycleable.currentIndex }
            _cycleInterval = { cycleable.cycleInterval }
            _cycleNext = { cycleable.cycleNext() }
        } else {
            self.isCycleable = false
            _itemCount = { 0 }
            _currentIndex = { 0 }
            _cycleInterval = { 0 }
            _cycleNext = {}
        }

        // InteractiveDropdown support
        if let interactive = widget as? InteractiveDropdown {
            self.hasInteractiveDropdown = true
            _buildDropdownPopover = { interactive.buildDropdownPopover() }
            _dropdownSize = { interactive.dropdownSize }
        } else {
            self.hasInteractiveDropdown = false
            _buildDropdownPopover = { NSView() }
            _dropdownSize = { NSSize(width: 300, height: 200) }
        }
    }

    func start() { _start() }
    func stop() { _stop() }
    func render() -> WidgetDisplayMode { _render() }
    func buildDropdownMenu() -> NSMenu { _buildDropdownMenu() }
    func buildConfigControls(onChange: @escaping () -> Void) -> [NSView] { _buildConfigControls(onChange) }
    var refreshInterval: TimeInterval? { _refreshInterval() }
    func setOnDisplayUpdate(_ callback: @escaping () -> Void) { _setOnDisplayUpdate(callback) }
    func getConfigData() -> Data? { _getConfigData() }
    func setConfigData(_ data: Data) { _setConfigData(data) }
    func refresh() { _refresh() }

    // Cycleable accessors
    var itemCount: Int { _itemCount() }
    var currentIndex: Int { _currentIndex() }
    var cycleInterval: TimeInterval { _cycleInterval() }
    func cycleNext() { _cycleNext() }

    // InteractiveDropdown accessors
    func buildDropdownPopover() -> NSView { _buildDropdownPopover() }
    var dropdownSize: NSSize { _dropdownSize() }
}

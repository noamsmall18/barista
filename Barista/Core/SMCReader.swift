import Foundation
import IOKit

/// Reads SMC (System Management Controller) values for temperature sensors and GPU stats.
/// Works on both Intel and Apple Silicon Macs via IOKit.
class SMCReader {
    static let shared = SMCReader()

    private var connection: io_connect_t = 0
    private var isOpen = false

    private init() {
        open()
    }

    deinit {
        close()
    }

    // MARK: - Connection

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        isOpen = (result == kIOReturnSuccess)
    }

    private func close() {
        if isOpen {
            IOServiceClose(connection)
            isOpen = false
        }
    }

    // MARK: - SMC Data Types

    private struct SMCKeyData {
        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct PLimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let smcHandlerID: UInt32 = 2

    // MARK: - Key Encoding

    private func fourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }

    // MARK: - Read Value

    /// Read a raw SMC value for a 4-character key.
    func readValue(key: String) -> Double? {
        guard isOpen else { return nil }

        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCharCode(key)
        input.data8 = 9 // kSMCGetKeyInfo

        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        var result = IOConnectCallStructMethod(
            connection, SMCReader.smcHandlerID,
            &input, inputSize,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }

        let dataType = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize

        // Now read the actual value
        input.keyInfo.dataSize = dataSize
        input.data8 = 5 // kSMCReadKey

        result = IOConnectCallStructMethod(
            connection, SMCReader.smcHandlerID,
            &input, inputSize,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }

        return decodeValue(output: output, dataType: dataType, dataSize: dataSize)
    }

    private func decodeValue(output: SMCKeyData, dataType: UInt32, dataSize: UInt32) -> Double? {
        let bytes = output.bytes

        // "flt " - 32-bit float
        if dataType == fourCharCode("flt ") && dataSize == 4 {
            let raw = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
            return Double(Float(bitPattern: raw))
        }

        // "sp78" - signed 7.8 fixed point (common for temps)
        if dataType == fourCharCode("sp78") && dataSize == 2 {
            let raw = Int16(Int16(bytes.0) << 8 | Int16(bytes.1))
            return Double(raw) / 256.0
        }

        // "ui8 " - unsigned 8-bit
        if dataType == fourCharCode("ui8 ") && dataSize == 1 {
            return Double(bytes.0)
        }

        // "ui16" - unsigned 16-bit
        if dataType == fourCharCode("ui16") && dataSize == 2 {
            let raw = UInt16(bytes.0) << 8 | UInt16(bytes.1)
            return Double(raw)
        }

        // "ui32" - unsigned 32-bit
        if dataType == fourCharCode("ui32") && dataSize == 4 {
            let raw = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
            return Double(raw)
        }

        return nil
    }

    // MARK: - Convenience: Temperature Sensors

    /// Common temperature sensor keys.
    struct TempSensor {
        let key: String
        let name: String
    }

    /// All known temperature sensor keys. Not all will be present on every Mac.
    static let knownSensors: [TempSensor] = [
        // CPU
        TempSensor(key: "TC0P", name: "CPU Proximity"),
        TempSensor(key: "TC0D", name: "CPU Die"),
        TempSensor(key: "TC0E", name: "CPU Core 1"),
        TempSensor(key: "TC1E", name: "CPU Core 2"),
        TempSensor(key: "TC2E", name: "CPU Core 3"),
        TempSensor(key: "TC3E", name: "CPU Core 4"),
        TempSensor(key: "TC0F", name: "CPU Performance Core 1"),
        TempSensor(key: "TC1F", name: "CPU Performance Core 2"),
        TempSensor(key: "Tp09", name: "CPU Efficiency Core 1"),
        TempSensor(key: "Tp0T", name: "CPU Efficiency Core 2"),
        // GPU
        TempSensor(key: "TG0P", name: "GPU Proximity"),
        TempSensor(key: "TG0D", name: "GPU Die"),
        TempSensor(key: "Tg05", name: "GPU Core 1"),
        TempSensor(key: "Tg0D", name: "GPU Core 2"),
        // Memory
        TempSensor(key: "Tm0P", name: "Memory Proximity"),
        TempSensor(key: "TM0P", name: "Memory Module"),
        // SSD/Storage
        TempSensor(key: "TH0P", name: "SSD Proximity"),
        TempSensor(key: "TH0a", name: "SSD A"),
        TempSensor(key: "TH0b", name: "SSD B"),
        // Battery
        TempSensor(key: "TB0T", name: "Battery"),
        TempSensor(key: "TB1T", name: "Battery 2"),
        // Airflow
        TempSensor(key: "TA0P", name: "Ambient"),
        TempSensor(key: "TW0P", name: "Airport"),
        // Palm rest / Enclosure
        TempSensor(key: "Ts0P", name: "Palm Rest"),
        TempSensor(key: "Ts1P", name: "Palm Rest 2"),
    ]

    /// Returns all readable temperature sensors with current values.
    func readAllTemperatures() -> [(name: String, key: String, value: Double)] {
        var results: [(name: String, key: String, value: Double)] = []
        for sensor in SMCReader.knownSensors {
            if let value = readValue(key: sensor.key), value > 0 && value < 150 {
                results.append((name: sensor.name, key: sensor.key, value: value))
            }
        }
        return results
    }

    /// Read a specific named temperature.
    func cpuTemperature() -> Double? {
        // Try Apple Silicon keys first, then Intel
        return readValue(key: "Tp09") ?? readValue(key: "TC0P") ?? readValue(key: "TC0D")
    }

    func gpuTemperature() -> Double? {
        return readValue(key: "Tg05") ?? readValue(key: "TG0P") ?? readValue(key: "TG0D")
    }

    // MARK: - Fan Speed

    /// Read fan RPM. Fan index 0, 1, etc.
    func fanSpeed(index: Int) -> Double? {
        let key = String(format: "F%dAc", index)
        return readValue(key: key)
    }

    /// Number of fans.
    func fanCount() -> Int {
        if let count = readValue(key: "FNum") {
            return Int(count)
        }
        return 0
    }
}

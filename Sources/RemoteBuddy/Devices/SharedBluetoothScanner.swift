import CoreBluetooth

/// One broadcast scan serves every offline remote; connections retain their own managers.
@MainActor
final class SharedBluetoothScanner: NSObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = SharedBluetoothScanner()
    struct Advertisement {
        let identifier: UUID
        let name: String?
        let data: [String: Any]
    }
    private var central: CBCentralManager?
    private lazy var subscriptions = BluetoothScanSubscriptions<Advertisement>(
        start: { [weak self] in self?.startScanning() },
        stop: { [weak self] in self?.central?.stopScan() }
    )

    func subscribe(_ observer: @escaping (Advertisement) -> Void) -> UUID {
        subscriptions.subscribe(observer)
    }

    func unsubscribe(_ token: UUID) { subscriptions.unsubscribe(token) }

    private func startScanning() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
        guard let central, central.state == .poweredOn else { return }
        // Some compatible remotes advertise only a name; service filtering would lose them.
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, subscriptions.hasObservers { startScanning() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        subscriptions.publish(Advertisement(identifier: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            data: advertisementData))
    }
}

@MainActor
final class BluetoothScanSubscriptions<Advertisement> {
    private var observers: [UUID: (Advertisement) -> Void] = [:]
    private let start: () -> Void
    private let stop: () -> Void
    var hasObservers: Bool { !observers.isEmpty }

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.start = start
        self.stop = stop
    }

    func subscribe(_ observer: @escaping (Advertisement) -> Void) -> UUID {
        let token = UUID()
        let wasEmpty = observers.isEmpty
        observers[token] = observer
        // A new reconnect attempt needs fresh discoveries even while another
        // remote keeps the shared scan alive. Restart clears CoreBluetooth deduplication.
        if !wasEmpty { stop() }
        start()
        return token
    }

    func unsubscribe(_ token: UUID) {
        guard observers.removeValue(forKey: token) != nil else { return }
        if observers.isEmpty { stop() }
    }

    func publish(_ advertisement: Advertisement) {
        for observer in Array(observers.values) { observer(advertisement) }
    }
}

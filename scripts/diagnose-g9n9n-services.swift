// SPDX-License-Identifier: GPL-3.0-only
// Run with: swift scripts/diagnose-g9n9n-services.swift
// Discovers public GATT services only: no writes, subscriptions, or audio capture.
import CoreBluetooth
import Foundation

func record(_ message: String) {
    print(message)
    fflush(stdout)
}

final class ServiceProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var remote: CBPeripheral?
    var requestedHID = false
    var completed = false
    private let hidService = CBUUID(string: "1812")

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("STATE value=\(central.state.rawValue)")
        guard central.state == .poweredOn else {
            if [.unauthorized, .unsupported, .poweredOff].contains(central.state) {
                CFRunLoopStop(CFRunLoopGetMain())
            }
            return
        }
        let candidates = central.retrieveConnectedPeripherals(withServices: [
            CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664"),
        ]).filter {
            ["chromecast", "chromecast remote", "chromecast voice remote", "g9n9n"]
                .contains(($0.name ?? "").lowercased())
        }
        record("CANDIDATES count=\(candidates.count)")
        guard remote == nil else { return }
        guard candidates.count == 1, let peripheral = candidates.first else {
            record("INCONCLUSIVE requires_one_connected_candidate")
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        remote = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        record("CONNECTED")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        record("ERROR connection_failed")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            let failure = error! as NSError
            record("ERROR service_discovery domain=\(failure.domain) code=\(failure.code)")
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        let services = peripheral.services ?? []
        let uuids = services.map { $0.uuid.uuidString }.sorted().joined(separator: ",")
        record("SERVICES request=\(requestedHID ? "1812" : "all") visible=\(uuids) hid_visible=\(services.contains { $0.uuid == hidService })")
        if !requestedHID {
            requestedHID = true
            peripheral.discoverServices([hidService])
        } else {
            completed = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}

guard CBManager.authorization == .allowedAlways else {
    record("INCONCLUSIVE bluetooth_permission_required; run from an authorized terminal")
    exit(1)
}
let probe = ServiceProbe()
probe.central = CBCentralManager(
    delegate: probe, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]
)
CFRunLoopRunInMode(.defaultMode, 30, false)
if let remote = probe.remote { probe.central.cancelPeripheralConnection(remote) }
record("SUMMARY completed=\(probe.completed)")
exit(probe.completed ? 0 : 1)

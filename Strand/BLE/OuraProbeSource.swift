import Foundation
import Combine
import CoreBluetooth

/// EXPERIMENTAL, ISOLATED probe for the Oura ring.
///
/// HONEST DEAD-END BY DESIGN. The Oura ring does NOT expose an open live health stream — it's
/// proprietary and syncs to Oura's own app over its private protocol. We make the detection attempt (scan
/// for the ring, optionally connect and enumerate its advertised services so the user sees we genuinely
/// looked), then surface a CLEAR message that Oura live isn't available and point at the file-import lane.
/// This driver never streams, never persists, and never fabricates a reading.
///
/// WHOOP-FIRST ISOLATION: its own `CBCentralManager`, no `BLEManager` reference. The only shared surface
/// is the injected `log` closure (the exportable strap log) — it touches no `LiveState`, no store.
@MainActor
public final class OuraProbeSource: NSObject, ObservableObject {

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    /// The honest outcome once we've probed a ring: there is no open live stream. The UI shows this and the
    /// "use file import" route. nil until a probe completes.
    @Published public private(set) var deadEndMessage: String? = nil

    private let log: (String) -> Void

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Scan broadly and keep only peripherals whose advertised name reads as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        deadEndMessage = nil
        log("Oura: scanning for an Oura ring…")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) — scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    /// Connect to the ring purely to enumerate its services — so we can HONESTLY report "we looked, there's
    /// no open live stream" rather than assuming. We never subscribe to anything.
    public func probe(_ id: UUID) {
        stopScan()
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            pendingConnectID = id
            log("Oura: ring \(id) not cached yet — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            return
        }
        log("Oura: probing \(id) — enumerating services to confirm there's no open live stream")
        central.connect(p, options: nil)
    }

    public func stop() {
        stopScan()
        pendingConnectID = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    /// Record the honest dead-end (once). Called whether or not the connect/enumerate succeeds — the
    /// outcome is the same: Oura has no open live health stream, so the user should import a file.
    private func announceDeadEnd() {
        guard deadEndMessage == nil else { return }
        let msg = "Oura live data isn't available. The ring is proprietary and only syncs to the Oura app, " +
                  "so there's no open Bluetooth stream NOOP can read. Export from Oura and use file import " +
                  "instead."
        deadEndMessage = msg
        log("Oura: \(msg)")
    }
}

// MARK: - CBCentralManagerDelegate

extension OuraProbeSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        guard ExperimentalBrand.recognise(name: name) == .oura else { return }
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id, name: name.isEmpty ? "Oura" : name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        if pendingConnectID == id {
            pendingConnectID = nil
            probe(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected, enumerating services (subscribing to nothing)")
        peripheral.delegate = self
        peripheral.discoverServices(nil)   // enumerate everything, subscribe to nothing
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Couldn't even connect — still the honest outcome: no usable live stream.
        announceDeadEnd()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
    }
}

// MARK: - CBPeripheralDelegate

extension OuraProbeSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let uuids = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        log("Oura: services advertised: [\(uuids)] — none is an open live health stream")
        announceDeadEnd()
        // We're done; drop the link. No subscription, no data.
        central.cancelPeripheralConnection(peripheral)
    }
}

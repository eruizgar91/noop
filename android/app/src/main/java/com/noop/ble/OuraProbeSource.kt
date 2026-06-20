package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * EXPERIMENTAL, ISOLATED probe for the Oura ring.
 *
 * Faithful Kotlin twin of Strand/BLE/OuraProbeSource.swift.
 *
 * HONEST DEAD-END BY DESIGN. The Oura ring does NOT expose an open live health stream — it's proprietary
 * and syncs to Oura's own app over its private protocol. We make the detection attempt (scan for the
 * ring, optionally connect and enumerate its advertised services so the user sees we genuinely looked),
 * then publish a CLEAR message that Oura live isn't available and point at the file-import lane. This
 * driver never streams, never persists, and never fabricates a reading.
 *
 * WHOOP-FIRST ISOLATION: its own scanner + [BluetoothGatt], no [WhoopBleClient] reference. The only
 * shared surface is the injected [log] closure (the exportable strap log).
 *
 * Android runtime-permission notes: the caller must hold BLUETOOTH_SCAN + BLUETOOTH_CONNECT.
 */
@SuppressLint("MissingPermission")
class OuraProbeSource(
    context: Context,
    private val log: (String) -> Unit = {},
) {

    /** An Oura ring seen during a scan (UI affordance). */
    data class DiscoveredRing(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredRing>>(emptyList())
    val discovered: StateFlow<List<DiscoveredRing>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _deadEndMessage = MutableStateFlow<String?>(null)
    /** The honest outcome once a ring is probed: there is no open live stream. null until a probe runs. */
    val deadEndMessage: StateFlow<String?> = _deadEndMessage.asStateFlow()

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    private var pendingProbeAddress: String? = null
    private val handler = Handler(Looper.getMainLooper())

    /** Scan broadly and keep only peripherals whose advertised name reads as an Oura ring. */
    fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _deadEndMessage.value = null
        log("Oura: scanning for an Oura ring…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Oura: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Oura: Bluetooth adapter is off — cannot scan")
            return
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        sc.startScan(null, settings, scanCallback)
    }

    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    /**
     * Connect to the ring purely to enumerate its services — so we can HONESTLY report "we looked, there's
     * no open live stream" rather than assuming. We never subscribe to anything.
     */
    fun probe(address: String) {
        stopScan()
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingProbeAddress = address; return }
        log("Oura: probing $address — enumerating services to confirm there's no open live stream")
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            // Couldn't even start the connection — still the honest outcome.
            announceDeadEnd()
            null
        }
    }

    fun stop() {
        stopScan()
        pendingProbeAddress = null
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            if (ExperimentalBrand.recognise(name) != ExperimentalBrand.OURA) return
            val firstSight = seen.put(address, device) == null
            if (firstSight) log("Oura: found $name ($address) rssi ${result.rssi}")
            val ring = DiscoveredRing(address = address, name = name.ifBlank { "Oura" }, rssi = result.rssi)
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = ring else list.add(ring)
            _discovered.value = list
            if (pendingProbeAddress == address) {
                pendingProbeAddress = null
                handler.post { probe(address) }
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            runCatching {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> g.discoverServices()  // subscribe to nothing
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        if (gatt === g) { runCatching { g.close() }; gatt = null }
                        // A failure to connect/bond is itself the honest dead-end.
                        if (status != BluetoothGatt.GATT_SUCCESS) announceDeadEnd()
                    }
                }
                Unit
            }.onFailure { announceDeadEnd() }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            runCatching {
                val uuids = g.services?.joinToString(", ") { it.uuid.toString() } ?: ""
                log("Oura: services advertised: [$uuids] — none is an open live health stream")
                announceDeadEnd()
                runCatching { g.disconnect(); g.close() }
                if (gatt === g) gatt = null
            }.onFailure { announceDeadEnd() }
        }
    }

    private fun announceDeadEnd() {
        if (_deadEndMessage.value != null) return
        val msg = "Oura live data isn't available. The ring is proprietary and only syncs to the Oura app, " +
            "so there's no open Bluetooth stream NOOP can read. Export from Oura and use file import instead."
        _deadEndMessage.value = msg
        log("Oura: $msg")
    }
}

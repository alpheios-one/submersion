package com.submersion.libdivecomputer

// Explains why a GATT connection produced no usable serial characteristics.
//
// A Shearwater Petrel 2 owner reported "Failed to connect to device" and
// sent a debug log whose whole account of the failure was
// "connectAndDiscover: connected=true writeChar=null credits=0
// result=false" (issue #957). The link was up and the MTU had been
// negotiated, so the failure was somewhere in service discovery -- but
// every branch that leaves writeCharacteristic null returned silently:
// a discovery the stack refused returned early on its status, and a
// discovery that produced no service with both a write and a notify
// characteristic simply fell through. The two are different bugs with
// different fixes and the log could not tell them apart.
//
// Framework-free so it can run as a JVM unit test; the Android GATT
// constants are duplicated here rather than referenced, as BondDiagnostics
// does for the bond states and BleScanDiagnostics for the scan failures.
object GattDiagnostics {

    // Mirrors android.bluetooth.BluetoothDevice device types.
    const val DEVICE_TYPE_UNKNOWN = 0
    const val DEVICE_TYPE_CLASSIC = 1
    const val DEVICE_TYPE_LE = 2
    const val DEVICE_TYPE_DUAL = 3

    // Mirrors android.bluetooth.BluetoothGatt.GATT_SUCCESS plus the
    // connection-layer statuses the stack passes through unchanged. Only
    // GATT_SUCCESS and a handful of ATT codes are public API; the rest come
    // from the HCI error codes in stack/include/gatt_api.h and are stable.
    const val GATT_SUCCESS = 0
    const val GATT_INSUFFICIENT_AUTHENTICATION = 5
    const val GATT_CONN_TIMEOUT = 8
    const val GATT_CONN_TERMINATE_PEER_USER = 19
    const val GATT_CONN_TERMINATE_LOCAL_HOST = 22
    const val GATT_CONN_LMP_TIMEOUT = 34
    const val GATT_CONN_FAIL_ESTABLISH = 62
    const val GATT_INTERNAL_ERROR = 129
    const val GATT_ERROR = 133
    const val GATT_CONN_CANCEL = 256
    const val GATT_FAILURE = 257

    /**
     * Human-readable name for a BluetoothDevice.getType() value.
     *
     * The distinction matters: a dual-mode radio is reached over Bluetooth
     * Classic by default, and a computer that serves its serial bridge only
     * over LE then answers service discovery with nothing.
     */
    fun describeDeviceType(type: Int): String = when (type) {
        DEVICE_TYPE_CLASSIC -> "Bluetooth Classic only"
        DEVICE_TYPE_LE -> "LE only"
        DEVICE_TYPE_DUAL -> "dual-mode (Bluetooth Classic + LE)"
        DEVICE_TYPE_UNKNOWN -> "unknown to the Bluetooth stack"
        else -> "unrecognized device type ($type)"
    }

    /**
     * Names the transport a connect actually ran on.
     *
     * Written from the same flag that picks the connectGatt overload so the
     * two cannot drift: a line that claimed LE while the call fell back to
     * TRANSPORT_AUTO would misreport the one fact this instrumentation
     * exists to establish.
     */
    fun describeTransport(leRequested: Boolean): String =
        if (leRequested) "LE" else "AUTO (LE cannot be demanded below API 23)"

    /** Human-readable reason for a BluetoothGattCallback status code. */
    fun describeGattStatus(status: Int): String = when (status) {
        GATT_SUCCESS ->
            "success"
        GATT_INSUFFICIENT_AUTHENTICATION ->
            "insufficient authentication; the stored pairing keys are stale " +
                "or the computer demanded encryption"
        GATT_CONN_TIMEOUT ->
            "the connection timed out; the computer moved out of range or " +
                "switched its radio off"
        GATT_CONN_TERMINATE_PEER_USER ->
            "the computer closed the connection"
        GATT_CONN_TERMINATE_LOCAL_HOST ->
            "this phone closed the connection"
        GATT_CONN_LMP_TIMEOUT ->
            "the computer stopped answering the radio link"
        GATT_CONN_FAIL_ESTABLISH ->
            "the connection could not be established"
        GATT_INTERNAL_ERROR ->
            "internal Bluetooth stack error"
        GATT_ERROR ->
            "generic GATT error; usually the computer refused the operation " +
                "or the link was not usable for it"
        GATT_CONN_CANCEL ->
            "the connection attempt was cancelled"
        GATT_FAILURE ->
            "the operation failed"
        else ->
            "unknown GATT status ($status)"
    }

    /**
     * Message for a service discovery the stack refused, naming the radio
     * the computer was reached on.
     *
     * A dual-mode computer earns an extra clause: Android connects such a
     * device over Bluetooth Classic unless the caller demands
     * TRANSPORT_LE, and a GATT server that only exists on the LE radio is
     * then invisible. That is the failure behind #957, and naming it in the
     * log is what makes a future report of it self-diagnosing.
     */
    fun describeDiscoveryFailure(status: Int, deviceType: Int): String {
        val base = "Service discovery failed: status=$status " +
            "(${describeGattStatus(status)}); the computer's radio is " +
            describeDeviceType(deviceType)
        if (deviceType != DEVICE_TYPE_DUAL) return base
        return "$base. A dual-mode computer answers GATT only on its LE " +
            "radio, so this discovery must run over the LE transport"
    }

    /**
     * Message for a discovery that completed but exposed no service
     * carrying both a write and a notify/indicate characteristic, which is
     * the pair the serial bridge needs.
     *
     * An empty list is reported in its own words: no services at all means
     * the connection was not really usable, while a populated list that
     * still yields no pair means the computer is exposing something this
     * build does not know how to drive, and the UUIDs are what a new
     * descriptor would be written from.
     */
    fun describeNoUsableService(serviceUuids: List<String>): String {
        if (serviceUuids.isEmpty()) {
            return "Service discovery succeeded but the computer reported " +
                "no services at all"
        }
        return "No discovered service carries both a write and a notify " +
            "characteristic; ${serviceUuids.size} service(s) seen: " +
            serviceUuids.joinToString(", ")
    }
}

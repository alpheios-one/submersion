package com.submersion.libdivecomputer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// JVM tests for the GATT connect/discovery diagnostics (issue #957).
//
// A Shearwater Petrel 2 owner reported "Failed to connect to device" and
// sent a debug log whose entire account of the failure was
// "connectAndDiscover: connected=true writeChar=null credits=0
// result=false". Every path that can leave writeChar null returned without
// logging anything: a refused service discovery returned early, and a
// discovery that found no usable service simply fell through. These tests
// pin the messages that tell those cases apart in a bug report.
class GattDiagnosticsTest {

    @Test
    fun dualModeDeviceTypeIsNamed() {
        val described = GattDiagnostics.describeDeviceType(
            GattDiagnostics.DEVICE_TYPE_DUAL
        )

        assertTrue(described.contains("dual"))
        assertTrue(described.contains("LE"))
    }

    @Test
    fun everyDeviceTypeIsDescribed() {
        assertEquals("Bluetooth Classic only", GattDiagnostics.describeDeviceType(
            GattDiagnostics.DEVICE_TYPE_CLASSIC
        ))
        assertEquals("LE only", GattDiagnostics.describeDeviceType(
            GattDiagnostics.DEVICE_TYPE_LE
        ))
        assertTrue(
            GattDiagnostics.describeDeviceType(
                GattDiagnostics.DEVICE_TYPE_UNKNOWN
            ).contains("unknown")
        )
    }

    @Test
    fun unrecognizedDeviceTypeStillReportsItsValue() {
        assertTrue(GattDiagnostics.describeDeviceType(42).contains("42"))
    }

    @Test
    fun commonGattStatusesAreExplained() {
        assertTrue(GattDiagnostics.describeGattStatus(0).contains("success"))
        assertTrue(
            GattDiagnostics.describeGattStatus(
                GattDiagnostics.GATT_INSUFFICIENT_AUTHENTICATION
            ).contains("pairing")
        )
        assertTrue(
            GattDiagnostics.describeGattStatus(
                GattDiagnostics.GATT_CONN_TIMEOUT
            ).contains("timed out")
        )
        assertTrue(
            GattDiagnostics.describeGattStatus(
                GattDiagnostics.GATT_ERROR
            ).isNotEmpty()
        )
    }

    @Test
    fun unknownGattStatusReportsItsValue() {
        assertTrue(GattDiagnostics.describeGattStatus(200).contains("200"))
    }

    @Test
    fun discoveryFailureNamesTheStatusAndTheDeviceType() {
        val message = GattDiagnostics.describeDiscoveryFailure(
            GattDiagnostics.GATT_ERROR,
            GattDiagnostics.DEVICE_TYPE_LE
        )

        assertTrue(message.contains("133"))
        assertTrue(message.contains("LE only"))
    }

    @Test
    fun discoveryFailureOnADualModeDeviceNamesTheTransportTrap() {
        val message = GattDiagnostics.describeDiscoveryFailure(
            GattDiagnostics.GATT_ERROR,
            GattDiagnostics.DEVICE_TYPE_DUAL
        )

        // The dual-mode radio is the whole diagnosis of #957: Android
        // connects such a device over Bluetooth Classic unless the LE
        // transport is demanded, and GATT discovery then finds nothing.
        assertTrue(message.contains("Classic"))
    }

    @Test
    fun singleModeDiscoveryFailureDoesNotBlameTheTransport() {
        val message = GattDiagnostics.describeDiscoveryFailure(
            GattDiagnostics.GATT_ERROR,
            GattDiagnostics.DEVICE_TYPE_LE
        )

        assertFalse(message.contains("Classic"))
    }

    @Test
    fun theTransportLabelFollowsWhatTheConnectActuallyRequested() {
        assertEquals("LE", GattDiagnostics.describeTransport(true))

        // A log that claims LE on a connect that ran under TRANSPORT_AUTO
        // would misreport the one fact this instrumentation exists to
        // establish, so the fallback must never read as LE.
        val fallback = GattDiagnostics.describeTransport(false)
        assertFalse(fallback == "LE")
        assertTrue(fallback.contains("AUTO"))
    }

    @Test
    fun emptyDiscoveryIsDistinguishedFromAnUnusableOne() {
        val empty = GattDiagnostics.describeNoUsableService(emptyList())

        assertTrue(empty.contains("no services"))
    }

    @Test
    fun unusableDiscoveryListsWhatTheComputerExposed() {
        val message = GattDiagnostics.describeNoUsableService(
            listOf(
                "00001800-0000-1000-8000-00805f9b34fb",
                "0000fefb-0000-1000-8000-00805f9b34fb"
            )
        )

        assertTrue(message.contains("2"))
        assertTrue(message.contains("00001800-0000-1000-8000-00805f9b34fb"))
        assertTrue(message.contains("0000fefb-0000-1000-8000-00805f9b34fb"))
    }
}

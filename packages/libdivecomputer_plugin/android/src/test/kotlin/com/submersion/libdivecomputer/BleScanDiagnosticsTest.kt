package com.submersion.libdivecomputer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// JVM tests for the BLE scan diagnostics used by BleScanner (issue #123).
//
// A Suunto Ocean owner was asked twice for the "Unmatched device" log line
// and could not produce it, because every failure mode ahead of that line
// returned silently. These tests pin the behaviour that makes an
// unsupported -- or unnamed -- dive computer visible in the debug log.
//
// The resolveName tests also cover issue #723, where a supported computer
// was visible in that log but still unmatched because its advertised name
// carried a trailing NUL.
class BleScanDiagnosticsTest {

    // Spelled out rather than escaped so the terminator is obvious in the
    // assertions below.
    private val NUL = 0.toChar().toString()

    @Test
    fun unmatchedNamedDeviceIsDescribedWithAddressAndName() {
        val diagnostics = BleScanDiagnostics()

        val message = diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62)

        assertNotNull(message)
        assertTrue(message!!.contains("AA:BB:CC:DD:EE:FF"))
        assertTrue(message.contains("Suunto Ocean"))
        assertTrue(message.contains("-62"))
    }

    @Test
    fun repeatedAdvertisementsFromTheSameDeviceAreLoggedOnce() {
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62))
        assertNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -63))
        assertNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -58))
    }

    @Test
    fun differentDevicesAreEachLogged() {
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62))
        assertNotNull(diagnostics.describeUnmatched("11:22:33:44:55:66", "Some Watch", -70))
    }

    @Test
    fun unnamedDeviceIsStillLoggedWithItsAddress() {
        val diagnostics = BleScanDiagnostics()

        val message = diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -62)

        assertNotNull(message)
        assertTrue(message!!.contains("AA:BB:CC:DD:EE:FF"))
        assertTrue(message.contains("-62"))
    }

    @Test
    fun unnamedDeviceIsLoggedAgainOnceItsNameBecomesKnown() {
        // Many peripherals omit the local name from the initial advertisement
        // and only supply it in the scan response. Suppressing the later,
        // named sighting would hide the one string a descriptor patch needs.
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -62))
        assertNotNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62))
    }

    @Test
    fun unnamedSightingsAreThemselvesDeduplicated() {
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -62))
        assertNull(diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -64))
    }

    @Test
    fun addresslessAdvertisementsAreReportedOncePerSession() {
        // These cannot be deduplicated per device, so an unthrottled line
        // would flood the log file and rotate away the useful entries.
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeAddressless())
        assertNull(diagnostics.describeAddressless())

        diagnostics.reset()
        assertNotNull(diagnostics.describeAddressless())
    }

    @Test
    fun addresslessReportingDoesNotSuppressRealDevices() {
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeAddressless())
        assertNotNull(diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -62))
        assertNotNull(
            diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62)
        )
    }

    @Test
    fun resetAllowsANewScanSessionToLogTheSameDeviceAgain() {
        val diagnostics = BleScanDiagnostics()
        assertNotNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62))

        diagnostics.reset()

        assertNotNull(diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62))
    }

    @Test
    fun scanRecordNameIsPreferredOverTheCachedDeviceName() {
        assertEquals(
            "Suunto Ocean",
            BleScanDiagnostics.resolveName("Suunto Ocean", "stale cached name")
        )
    }

    @Test
    fun cachedDeviceNameIsUsedWhenTheAdvertisementCarriesNone() {
        assertEquals("Suunto D5", BleScanDiagnostics.resolveName(null, "Suunto D5"))
    }

    @Test
    fun emptyNamesCountAsAbsent() {
        // A zero-length Complete Local Name AD field is reported as "" rather
        // than omitted. Treating it as a real name would match an empty prefix
        // against the descriptor table and log a nameless "(...)" line.
        assertNull(BleScanDiagnostics.resolveName("", ""))
        assertNull(BleScanDiagnostics.resolveName(null, ""))
        assertNull(BleScanDiagnostics.resolveName("", null))
    }

    @Test
    fun anEmptyScanRecordNameFallsBackToTheDeviceName() {
        assertEquals("Suunto D5", BleScanDiagnostics.resolveName("", "Suunto D5"))
    }

    @Test
    fun aTrailingNulInTheAdvertisedNameIsStripped() {
        // Issue #723: the Shearwater Perdix 3 pads its Complete Local Name
        // with the C string terminator, and Android's scan record parser
        // keeps it. JNI encodes U+0000 as two non-zero bytes, so the exact
        // strcasecmp in libdivecomputer never saw "Perdix 3" and the
        // computer was logged as "Unmatched device ... (Perdix 3 )".
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName("Perdix 3$NUL", null))
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName(null, "Perdix 3$NUL"))
    }

    @Test
    fun theNameEndsAtTheFirstNulLikeEveryOtherPlatform() {
        // iOS, macOS, Windows and Linux hand the name to C as a real
        // NUL-terminated string, so anything after the terminator is
        // invisible there. Mirror that rather than only trimming the end.
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName("Perdix 3$NUL$NUL", null))
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName("Perdix 3${NUL}junk", null))
    }

    @Test
    fun surroundingWhitespacePaddingIsStripped() {
        // The same log had a camera advertising "EOSR7_fabian    ": padding
        // is common in fixed-width name fields and can never be part of a
        // descriptor product name.
        assertEquals("EOSR7_fabian", BleScanDiagnostics.resolveName("EOSR7_fabian    ", null))
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName(" Perdix 3  ", null))
    }

    @Test
    fun aNameThatIsOnlyPaddingCountsAsAbsent() {
        assertNull(BleScanDiagnostics.resolveName(NUL, null))
        assertNull(BleScanDiagnostics.resolveName("   ", ""))
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName(" ", "Perdix 3"))
        assertEquals("Perdix 3", BleScanDiagnostics.resolveName(NUL, "Perdix 3"))
    }

    @Test
    fun anAbsentNameDoesNotCollideWithAnEmptyOne() {
        // Both used to produce the dedupe key "<address>|", so whichever
        // arrived first silently suppressed the other.
        val diagnostics = BleScanDiagnostics()

        assertNotNull(diagnostics.describeUnnamed("AA:BB:CC:DD:EE:FF", -62))
        assertNotNull(
            diagnostics.describeUnmatched("AA:BB:CC:DD:EE:FF", "Suunto Ocean", -62)
        )
    }

    @Test
    fun knownScanFailureCodesAreDescribedInWords() {
        assertTrue(
            BleScanDiagnostics.describeScanFailure(BleScanDiagnostics.SCAN_FAILED_ALREADY_STARTED)
                .contains("already started", ignoreCase = true)
        )
        assertTrue(
            BleScanDiagnostics.describeScanFailure(
                BleScanDiagnostics.SCAN_FAILED_FEATURE_UNSUPPORTED
            ).contains("unsupported", ignoreCase = true)
        )
        assertTrue(
            BleScanDiagnostics.describeScanFailure(
                BleScanDiagnostics.SCAN_FAILED_SCANNING_TOO_FREQUENTLY
            ).contains("too frequently", ignoreCase = true)
        )
    }

    @Test
    fun unknownScanFailureCodeKeepsTheRawValue() {
        assertTrue(BleScanDiagnostics.describeScanFailure(42).contains("42"))
    }

    @Test
    fun scanFailureDescriptionsAreDistinct() {
        val codes = listOf(1, 2, 3, 4, 5, 6)
        val descriptions = codes.map { BleScanDiagnostics.describeScanFailure(it) }

        assertEquals(codes.size, descriptions.toSet().size)
    }
}

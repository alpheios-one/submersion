package com.submersion.libdivecomputer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Pins [libdcEventTypeName] to the order of `parser_sample_event_t` in
 * `third_party/libdivecomputer/include/libdivecomputer/parser.h`. The C
 * wrapper's copy of this table is checked against the enum symbols themselves
 * by `test/native/test_event_type_names.c`; this JVM copy cannot see the
 * header, so the enum order is spelled out here and must be kept in step.
 */
class LibdcEventTypeNamesTest {
    // parser_sample_event_t, in declaration order.
    private val enumOrder = listOf(
        "none",                 // SAMPLE_EVENT_NONE
        "deco",                 // SAMPLE_EVENT_DECOSTOP
        "rbt",                  // SAMPLE_EVENT_RBT
        "ascent",               // SAMPLE_EVENT_ASCENT
        "ceiling",              // SAMPLE_EVENT_CEILING
        "workload",             // SAMPLE_EVENT_WORKLOAD
        "transmitter",          // SAMPLE_EVENT_TRANSMITTER
        "violation",            // SAMPLE_EVENT_VIOLATION
        "bookmark",             // SAMPLE_EVENT_BOOKMARK
        "surface",              // SAMPLE_EVENT_SURFACE
        "safetystop",           // SAMPLE_EVENT_SAFETYSTOP
        "gaschange",            // SAMPLE_EVENT_GASCHANGE
        "safetystop_voluntary", // SAMPLE_EVENT_SAFETYSTOP_VOLUNTARY
        "safetystop_mandatory", // SAMPLE_EVENT_SAFETYSTOP_MANDATORY
        "deepstop",             // SAMPLE_EVENT_DEEPSTOP
        "ceiling_safetystop",   // SAMPLE_EVENT_CEILING_SAFETYSTOP
        "floor",                // SAMPLE_EVENT_FLOOR
        "divetime",             // SAMPLE_EVENT_DIVETIME
        "maxdepth",             // SAMPLE_EVENT_MAXDEPTH
        "OLF",                  // SAMPLE_EVENT_OLF
        "PO2",                  // SAMPLE_EVENT_PO2
        "airtime",              // SAMPLE_EVENT_AIRTIME
        "rgbm",                 // SAMPLE_EVENT_RGBM
        "heading",              // SAMPLE_EVENT_HEADING
        "tissuelevel",          // SAMPLE_EVENT_TISSUELEVEL
        "gaschange2",           // SAMPLE_EVENT_GASCHANGE2
    )

    @Test
    fun `every enum member maps to its name in declaration order`() {
        enumOrder.forEachIndexed { code, name ->
            assertEquals("code $code", name, libdcEventTypeName(code))
        }
    }

    @Test
    fun `an ascent-rate alarm is never reported as a ceiling`() {
        // The Mares Icon HD family raises SAMPLE_EVENT_ASCENT (3) for its
        // fast-ascent alarms, several times on an ordinary recreational dive.
        assertEquals("ascent", libdcEventTypeName(3))
        assertNotEquals("ceiling", libdcEventTypeName(3))
        assertEquals("ceiling", libdcEventTypeName(4))
    }

    @Test
    fun `codes outside the enum are unknown`() {
        assertEquals("unknown", libdcEventTypeName(enumOrder.size))
        assertEquals("unknown", libdcEventTypeName(-1))
        assertEquals("unknown", libdcEventTypeName(Int.MAX_VALUE))
    }
}

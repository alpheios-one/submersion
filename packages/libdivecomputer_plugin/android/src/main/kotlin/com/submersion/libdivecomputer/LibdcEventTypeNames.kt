package com.submersion.libdivecomputer

/**
 * Name of a libdivecomputer sample event type (`parser_sample_event_t`), in
 * the spelling the Dart layer switches on ("ascent", "ceiling", ...).
 *
 * This is the JVM twin of `libdc_event_type_name` in the C wrapper
 * (`macos/Classes/libdc_download.c`), which every other platform calls
 * directly. The JNI layer hands events to Kotlin as positional arrays, and a
 * JVM unit test cannot load the native library, so the table is kept here in
 * Kotlin and pinned to the enum order in
 * `third_party/libdivecomputer/include/libdivecomputer/parser.h` by
 * [LibdcEventTypeNamesTest].
 *
 * The per-file copies this replaced had all skipped `SAMPLE_EVENT_RBT` (2),
 * which shifted every later code by one: ascent-rate alarms were reported as
 * "ceiling" and displayed as deco violations on no-deco dives.
 */
internal fun libdcEventTypeName(type: Int): String = when (type) {
    0 -> "none"
    1 -> "deco"
    2 -> "rbt"
    3 -> "ascent"
    4 -> "ceiling"
    5 -> "workload"
    6 -> "transmitter"
    7 -> "violation"
    8 -> "bookmark"
    9 -> "surface"
    10 -> "safetystop"
    11 -> "gaschange"
    12 -> "safetystop_voluntary"
    13 -> "safetystop_mandatory"
    14 -> "deepstop"
    15 -> "ceiling_safetystop"
    16 -> "floor"
    17 -> "divetime"
    18 -> "maxdepth"
    19 -> "OLF"
    20 -> "PO2"
    21 -> "airtime"
    22 -> "rgbm"
    23 -> "heading"
    24 -> "tissuelevel"
    25 -> "gaschange2"
    else -> "unknown"
}

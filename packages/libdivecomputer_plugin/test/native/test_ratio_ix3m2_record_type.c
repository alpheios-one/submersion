/* Issue #1481: a Ratio iX3M 2 PRO on APOS5 firmware 5.2.11/016 imported every
   dive as 0 m / 0 min.

   The iX3M record type at sample offset 52 used to be a plain enum: 0 for a
   sample record, 1 for the info record carrying the GPS fix. Since APOS5
   5.2.11 the firmware re-uses the high bits of that field for tank data, so a
   perfectly ordinary sample now reports a type like 0x800E. The parser tested
   `type != REC_SAMPLE` and skipped everything that was not literally 0, which
   threw away the whole profile: no samples, no depth, no duration.

   Upstream fixed it by detecting the info record with `type == REC_INFO`
   instead and treating every other value as a sample (commit 8d50dc6), then
   decoding the new high bits (commit ec78926). Both are cherry-picked onto
   our submersion-patches branch.

   There is no capture of an affected dive in the repository, so the fixtures
   here are synthesised from the record layout the parser itself documents.
   That keeps the bits that matter (the record-type word) visible in the test
   rather than buried in an opaque blob. */

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libdc_wrapper.h"

/* Ratio "iX3M 2 GPS Pro", DC_FAMILY_DIVESYSTEM_IDIVE model 0x92. */
#define IX3M2_VENDOR  "Ratio"
#define IX3M2_PRODUCT "iX3M 2 GPS Pro"
#define IX3M2_MODEL   0x92

#define HEADER_SIZE 0x36
#define SAMPLE_SIZE 0x40 /* APOS4 and later */

/* Firmware words as the device reports them: 5.2.11/016 and 5.2.9/016. */
#define FIRMWARE_APOS5_5_2_11 50211016u
#define FIRMWARE_APOS4_5_2_9  50209016u

/* Record types. REC_INFO is the legacy GPS record; the sample types below are
   what APOS5 emits once it starts packing tank data into the high bits. */
#define REC_INFO            0x0001
#define REC_SAMPLE_LEGACY   0x0000
#define REC_SAMPLE_APOS5    0x800E /* valid + RF channel 14, as reported in #1481 */
#define REC_SAMPLE_APOS5_HP 0x8020 /* valid + pressure MSB, 300 bar transmitter */

/* One synthetic record. `type` is the word at offset 52 that #1481 is about. */
typedef struct {
    unsigned int type;
    unsigned int timestamp;  /* seconds */
    unsigned int depth_dm;   /* 1/10 m */
    int temperature_dc;      /* 1/10 degC */
    unsigned int pressure;   /* bar, low 8 bits (the 9th comes from the type) */
    /* Info records only, in 1e-7 degrees and mm. */
    int altitude_mm;
    int longitude_e7;
    int latitude_e7;
} idive_record_t;

static void put_u16(unsigned char *p, unsigned int value) {
    p[0] = (unsigned char)(value & 0xFF);
    p[1] = (unsigned char)((value >> 8) & 0xFF);
}

static void put_u32(unsigned char *p, unsigned int value) {
    p[0] = (unsigned char)(value & 0xFF);
    p[1] = (unsigned char)((value >> 8) & 0xFF);
    p[2] = (unsigned char)((value >> 16) & 0xFF);
    p[3] = (unsigned char)((value >> 24) & 0xFF);
}

/* Build a raw iX3M 2 dive: a 0x36-byte header followed by 0x40-byte records.
   Caller owns the buffer. */
static unsigned char *build_dive(unsigned int firmware,
                                 const idive_record_t *records,
                                 unsigned int count,
                                 unsigned int *size_out) {
    unsigned int size = HEADER_SIZE + count * SAMPLE_SIZE;
    unsigned char *data = (unsigned char *)calloc(1, size);
    assert(data != NULL);

    put_u16(data + 1, count);          /* number of records */
    put_u32(data + 7, 500000000u);     /* timestamp, seconds since 2008-01-01 */
    put_u16(data + 11, 10000);         /* atmospheric pressure, 1/10000 bar */
    data[34] = 0;                      /* salt water */
    put_u32(data + 0x2A, firmware);
    data[48] = 30;                     /* timezone index: UTC */

    for (unsigned int i = 0; i < count; i++) {
        unsigned char *rec = data + HEADER_SIZE + i * SAMPLE_SIZE;
        const idive_record_t *r = &records[i];

        if (r->type == REC_INFO) {
            put_u32(rec + 40, (unsigned int)r->altitude_mm);
            put_u32(rec + 44, (unsigned int)r->longitude_e7);
            put_u32(rec + 48, (unsigned int)r->latitude_e7);
        } else {
            put_u32(rec + 2, r->timestamp);
            put_u16(rec + 6, r->depth_dm);
            put_u16(rec + 8, (unsigned int)(r->temperature_dc & 0xFFFF));
            rec[10] = 21;              /* O2 % */
            rec[11] = 0;               /* He % */
            rec[14] = 0;               /* Buhlmann */
            rec[15] = 85;              /* GF high */
            rec[16] = 30;              /* GF low */
            rec[18] = 0;               /* open circuit */
            rec[47] = 0;               /* tank id 0, no transmitter flags */
            rec[49] = (unsigned char)(r->pressure & 0xFF);
            put_u16(rec + 50, 0);      /* no compass bearing */
        }

        put_u16(rec + 52, r->type);
    }

    *size_out = size;
    return data;
}

/* libdc_parse_raw_dive fills a caller-owned struct, so its two heap members
   (samples and events, the only ones the wrapper allocates) are released
   individually. libdc_parsed_dive_free() cannot be used here: it also frees the
   struct itself, which is fine for a heap dive and undefined for this one. */
static void release(libdc_parsed_dive_t *dive) {
    free(dive->samples);
    free(dive->events);
    dive->samples = NULL;
    dive->events = NULL;
}

static void parse(unsigned int firmware, const idive_record_t *records,
                  unsigned int count, libdc_parsed_dive_t *dive) {
    unsigned int size = 0;
    unsigned char *data = build_dive(firmware, records, count, &size);

    char err[256] = {0};
    int rc = libdc_parse_raw_dive(IX3M2_VENDOR, IX3M2_PRODUCT, IX3M2_MODEL,
                                  data, size, dive, err, sizeof(err));
    if (rc != 0) {
        printf("FAIL: libdc_parse_raw_dive returned %d (%s)\n", rc, err);
    }
    assert(rc == 0);
    free(data);
}

/* A five-sample profile, 10 s apart, descending to 30 m and back. */
static void fill_profile(idive_record_t *records, unsigned int type) {
    static const unsigned int depths[5] = {50, 180, 300, 220, 60};
    for (unsigned int i = 0; i < 5; i++) {
        records[i].type = type;
        records[i].timestamp = (i + 1) * 10;
        records[i].depth_dm = depths[i];
        records[i].temperature_dc = 180;
        records[i].pressure = 200 - i * 10;
        records[i].altitude_mm = 0;
        records[i].longitude_e7 = 0;
        records[i].latitude_e7 = 0;
    }
}

/* The heart of #1481: a record type with the new high bits set is still a
   sample, so the profile, depth and duration must all survive. */
static void test_apos5_samples_are_not_skipped(void) {
    idive_record_t records[5];
    fill_profile(records, REC_SAMPLE_APOS5);

    libdc_parsed_dive_t dive;
    parse(FIRMWARE_APOS5_5_2_11, records, 5, &dive);

    printf("  APOS5: %u samples, %.1f m, %u s\n",
           dive.sample_count, dive.max_depth, dive.duration);
    assert(dive.sample_count == 5);
    assert(fabs(dive.max_depth - 30.0) < 0.001);
    assert(dive.duration == 50);

    release(&dive);
    printf("PASS: test_apos5_samples_are_not_skipped\n");
}

/* The same dive recorded on 5.2.9, where the type word really is 0, has always
   worked and must keep working. */
static void test_legacy_firmware_still_parses(void) {
    idive_record_t records[5];
    fill_profile(records, REC_SAMPLE_LEGACY);

    libdc_parsed_dive_t dive;
    parse(FIRMWARE_APOS4_5_2_9, records, 5, &dive);

    printf("  APOS4: %u samples, %.1f m, %u s\n",
           dive.sample_count, dive.max_depth, dive.duration);
    assert(dive.sample_count == 5);
    assert(fabs(dive.max_depth - 30.0) < 0.001);
    assert(dive.duration == 50);

    release(&dive);
    printf("PASS: test_legacy_firmware_still_parses\n");
}

/* Type 1 keeps its legacy meaning, so the GPS fix in the info record must
   still reach the dive. The fix would be worthless if it turned the info
   record into a bogus sample. */
static void test_info_record_still_yields_gps(void) {
    idive_record_t records[6];
    records[0].type = REC_INFO;
    records[0].timestamp = 0;
    records[0].depth_dm = 0;
    records[0].temperature_dc = 0;
    records[0].pressure = 0;
    records[0].altitude_mm = 12000;      /* 12 m */
    records[0].longitude_e7 = 44120000;  /* 4.412 E */
    records[0].latitude_e7 = 512300000;  /* 51.23 N */
    fill_profile(records + 1, REC_SAMPLE_APOS5);

    libdc_parsed_dive_t dive;
    parse(FIRMWARE_APOS5_5_2_11, records, 6, &dive);

    printf("  info record: %u samples, entry %.5f / %.5f\n",
           dive.sample_count, dive.entry_latitude, dive.entry_longitude);
    assert(dive.sample_count == 5);
    assert(!isnan(dive.entry_latitude));
    assert(fabs(dive.entry_latitude - 51.23) < 0.0001);
    assert(fabs(dive.entry_longitude - 4.412) < 0.0001);

    release(&dive);
    printf("PASS: test_info_record_still_yields_gps\n");
}

/* APOS5 stopped setting the legacy 300 bar flag and moved the 9th pressure bit
   into the type word instead, so a high pressure transmitter reads half its
   real value without the second upstream commit. */
static void test_high_pressure_bit_extends_tank_pressure(void) {
    idive_record_t records[5];
    fill_profile(records, REC_SAMPLE_APOS5_HP);
    for (unsigned int i = 0; i < 5; i++) {
        records[i].pressure = (300 - i * 10) & 0xFF; /* low 8 bits only */
    }

    libdc_parsed_dive_t dive;
    parse(FIRMWARE_APOS5_5_2_11, records, 5, &dive);

    assert(dive.sample_count == 5);
    assert(dive.tank_count == 1);
    printf("  high pressure tank: %.0f -> %.0f bar\n",
           dive.samples[0].tank_pressure[0],
           dive.samples[4].tank_pressure[0]);
    assert(fabs(dive.samples[0].tank_pressure[0] - 300.0) < 0.001);
    assert(fabs(dive.samples[4].tank_pressure[0] - 260.0) < 0.001);

    release(&dive);
    printf("PASS: test_high_pressure_bit_extends_tank_pressure\n");
}

int main(void) {
    printf("Running Ratio iX3M 2 record type tests (issue #1481)...\n");
    test_apos5_samples_are_not_skipped();
    test_legacy_firmware_still_parses();
    test_info_record_still_yields_gps();
    test_high_pressure_bit_extends_tank_pressure();
    printf("All Ratio iX3M 2 record type tests passed\n");
    return 0;
}

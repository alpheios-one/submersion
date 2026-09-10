// Integration test for libdc_descriptor_match against the REAL libdivecomputer
// descriptor table. Unlike test_descriptor_matcher.c (which unit-tests the
// strcasecmp_nospace helper in isolation), this test links the actual
// descriptor.c so it exercises end-to-end BLE name -> descriptor resolution.
//
// Regression for issue #285: the Scubapro Galileo HUD advertises the short BLE
// name "HUD", but dc_filter_uwatec matches that alias against EVERY Uwatec/
// Scubapro descriptor. Without an alias->model mapping, the matcher falls back
// to the first family-level descriptor ("Aladin Sport Matrix", model 0x17)
// instead of the real model ("G2 HUD", model 0x42). The same alias-vs-product
// gap affects "Galileo 3" (product "G3"), "A1" ("Aladin A1") and "A2"
// ("Aladin A2"). Model codes below come from descriptor.c.
//
// Regression for issue #357: a Halcyon Symbios Handset (an all-digit BLE
// serial) was always identified as a HUD. Both Symbios descriptor rows
// ("Symbios HUD" model 1, "Symbios Handset" model 7) share dc_filter_halcyon,
// which matched the serial against the UNION {1, 7}, so both rows passed for
// any Symbios serial and the first (HUD) always won. dc_match_halcyon
// disambiguates by the serial's [4:6] digits (01 = HUD, 07 = Handset), so each
// row must filter on its own model. The serials below are synthetic: only the
// model-code digits [4:6] are significant, so the surrounding manufacture-date
// and unit-number digits are zeroed (the bug was first reported against real
// Symbios devices in issue #288).
//
// Regression for issue #1419: the Seac Tablet never appeared in a BLE scan.
// Its filter demanded a name of "Tablet" plus ASCII digits and nothing else,
// so any separator or letter in the advertised serial dropped the device.

// Every check in this file is an assert, so a build that defines NDEBUG would
// compile all of them out and leave each test printing PASS while verifying
// nothing. CI configures without a build type today, so asserts are live, but
// adding -DCMAKE_BUILD_TYPE=Release is an ordinary thing to do and would
// silently turn this file into a no-op. Keep assertions regardless.
#undef NDEBUG

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "libdc_wrapper.h"

static void expect_ble_match(const char *name, const char *expected_product,
                             unsigned int expected_model) {
    libdc_descriptor_info_t info;
    memset(&info, 0, sizeof(info));
    int ok = libdc_descriptor_match(name, LIBDC_TRANSPORT_BLE, &info);
    if (!ok) {
        fprintf(stderr, "FAIL: \"%s\" did not match any descriptor\n", name);
        assert(ok);
    }
    if (strcmp(info.product, expected_product) != 0 ||
        info.model != expected_model) {
        fprintf(stderr,
                "FAIL: \"%s\" resolved to %s/0x%02x, expected %s/0x%02x\n",
                name, info.product, info.model, expected_product,
                expected_model);
        assert(0);
    }
}

static void expect_no_ble_match(const char *name) {
    libdc_descriptor_info_t info;
    memset(&info, 0, sizeof(info));
    int ok = libdc_descriptor_match(name, LIBDC_TRANSPORT_BLE, &info);
    if (ok) {
        fprintf(stderr, "FAIL: \"%s\" resolved to %s %s/0x%02x, expected no match\n",
                name, info.vendor, info.product, info.model);
        assert(!ok);
    }
}

// The reported device: BLE name "HUD" must resolve to the G2 HUD (0x42),
// not the family-level "Aladin Sport Matrix" fallback (0x17).
static void test_hud_resolves_to_g2_hud(void) {
    expect_ble_match("HUD", "G2 HUD", 0x42);
    printf("PASS: test_hud_resolves_to_g2_hud\n");
}

// Same alias-vs-product gap for the other short Scubapro/Uwatec BLE names.
static void test_other_short_aliases_resolve(void) {
    expect_ble_match("Galileo 3", "G3", 0x34);
    expect_ble_match("A1", "Aladin A1", 0x25);
    expect_ble_match("A2", "Aladin A2", 0x28);
    printf("PASS: test_other_short_aliases_resolve\n");
}

// Aliases are case-insensitive (BLE advertised names vary by stack/firmware).
static void test_alias_match_is_case_insensitive(void) {
    expect_ble_match("hud", "G2 HUD", 0x42);
    expect_ble_match("a1", "Aladin A1", 0x25);
    printf("PASS: test_alias_match_is_case_insensitive\n");
}

// Regression guard: names whose product string already matches exactly must
// keep resolving to themselves and must NOT be captured by the alias table.
static void test_exact_product_names_unchanged(void) {
    expect_ble_match("G2", "G2", 0x32);
    expect_ble_match("G2 TEK", "G2 TEK", 0x31);
    expect_ble_match("Luna 2.0", "Luna 2.0", 0x51);
    expect_ble_match("Luna 2.0 AI", "Luna 2.0 AI", 0x50);
    printf("PASS: test_exact_product_names_unchanged\n");
}

// Regression guard: a non-Uwatec device (different vendor/filter) is unaffected.
static void test_non_uwatec_device_unaffected(void) {
    libdc_descriptor_info_t info;
    memset(&info, 0, sizeof(info));
    int ok = libdc_descriptor_match("Teric", LIBDC_TRANSPORT_BLE, &info);
    assert(ok);
    assert(strcmp(info.vendor, "Shearwater") == 0);
    assert(strcmp(info.product, "Teric") == 0);
    printf("PASS: test_non_uwatec_device_unaffected\n");
}

// Issue #483: the Shearwater Perdix 3 advertises the BLE name "Perdix 3",
// which was absent from both the descriptor table and dc_filter_shearwater's
// exact-match whitelist, so every descriptor rejected it and the device never
// appeared during scanning. Model 14 continues Shearwater's sequential model
// numbering (Petrel 3 = 10, Perdix 2 = 11, Tern = 12, Peregrine TX = 13).
static void test_perdix_3_resolves(void) {
    expect_ble_match("Perdix 3", "Perdix 3", 14);
    expect_ble_match("perdix 3", "Perdix 3", 14);
    printf("PASS: test_perdix_3_resolves\n");
}

// Issue #590: HW OSTC BLE names can carry a serial suffix; the prefix
// tiebreaker must resolve them to their own descriptor instead of the first
// hw_ostc3 family row ("OSTC 2"). Unsuffixed names must stay put.
static void test_hw_ostc_suffixed_names_resolve(void) {
    expect_ble_match("OSTC4", "OSTC 4", 0x43);
    expect_ble_match("OSTC4 12345", "OSTC 4", 0x43);
    expect_ble_match("OSTC 4 12345", "OSTC 4", 0x43);
    expect_ble_match("OSTC5-9876", "OSTC 5", 0x44);
    expect_ble_match("OSTC 2", "OSTC 2", 0);
    expect_ble_match("OSTC Plus 321", "OSTC Plus", 0);
    printf("PASS: test_hw_ostc_suffixed_names_resolve\n");
}

// Issue #1246: an OSTC Sport advertises "OSTCs" plus its serial. That is an
// ABBREVIATION, not a prefix of "OSTC Sport", so neither the exact-name nor
// the longest-prefix tiebreaker could reach the right row and the device was
// reported as an "OSTC 2". The alias table resolves it by product name,
// because the whole hw_ostc3 family below OSTC 4 shares model 0 and so cannot
// be told apart by model code.
static void test_hw_ostc_sport_alias_resolves(void) {
    expect_ble_match("OSTCs 21211", "OSTC Sport", 0);
    expect_ble_match("OSTCs", "OSTC Sport", 0);
    expect_ble_match("ostcs 21211", "OSTC Sport", 0);
    // The spelled-out product must keep resolving through the ordinary
    // exact/prefix path rather than depending on the alias.
    expect_ble_match("OSTC Sport", "OSTC Sport", 0);
    expect_ble_match("OSTC Sport 4711", "OSTC Sport", 0);
    printf("PASS: test_hw_ostc_sport_alias_resolves\n");
}

// The alias must not swallow a longer word that merely starts with it:
// product_prefix_len rejects a match that ends mid-word, so a hypothetical
// "OSTCsomething" falls back to the family row instead of claiming to be a
// Sport.
static void test_hw_ostc_alias_does_not_match_longer_word(void) {
    expect_ble_match("OSTCsomething", "OSTC 2", 0);
    printf("PASS: test_hw_ostc_alias_does_not_match_longer_word\n");
}

// Issue #483 regression guard: dc_filter_shearwater passes a whitelisted name
// for EVERY Shearwater row, so resolution relies on the wrapper preferring the
// row whose product exactly equals the BLE name. The new "Perdix 3" row must
// not disturb that for the older Perdix models.
static void test_other_perdix_models_unchanged(void) {
    expect_ble_match("Perdix", "Perdix", 5);
    expect_ble_match("Perdix 2", "Perdix 2", 11);
    printf("PASS: test_other_perdix_models_unchanged\n");
}

// Issue #357: a Handset serial (model-code digits [4:6] = "07") must resolve to
// the "Symbios Handset" descriptor (model 7), not the "Symbios HUD" row
// (model 1) that previously always won because both rows matched the union
// {1, 7}.
static void test_symbios_handset_resolves_to_handset(void) {
    expect_ble_match("0000070000", "Symbios Handset", 7);
    printf("PASS: test_symbios_handset_resolves_to_handset\n");
}

// Issue #357 regression guard: a HUD serial (model-code digits [4:6] = "01")
// must keep resolving to the "Symbios HUD" descriptor and must not be captured
// by the Handset row once each row filters on its own model.
static void test_symbios_hud_resolves_to_hud(void) {
    expect_ble_match("0000010000", "Symbios HUD", 1);
    printf("PASS: test_symbios_hud_resolves_to_hud\n");
}

// Issue #123: the Suunto Ocean advertises "S19 <4 hex> LE". dc_filter_oceans
// prefix-matches the two characters "S1" with strncasecmp, so the Oceans S1
// descriptor claimed the watch: the download wizard announced a "Recognized
// Device" and the connect then failed, because Submersion was speaking the
// Oceans line protocol to a Suunto smartwatch. libdivecomputer has no support
// for the Ocean (its protocol is still uncaptured upstream), so the only
// correct answer is to claim nothing.
//
// Both the hex group and the MAC address rotate between sessions
// ("S19 1DFC LE", then "S19 700B LE" five minutes later), so only the "S19"
// model code and the " LE" suffix are stable enough to match on.
static void test_suunto_ocean_is_not_claimed_by_oceans_s1(void) {
    expect_no_ble_match("S19 1DFC LE");
    expect_no_ble_match("S19 700B LE");
    printf("PASS: test_suunto_ocean_is_not_claimed_by_oceans_s1\n");
}

// Advertised names vary in case by Bluetooth stack and firmware, exactly as
// the alias tables above assume.
static void test_suunto_ocean_rejection_is_case_insensitive(void) {
    expect_no_ble_match("s19 1dfc le");
    expect_no_ble_match("S19 1dfc Le");
    printf("PASS: test_suunto_ocean_rejection_is_case_insensitive\n");
}

// The rejection is keyed on the whole observed shape, not on the "S19" model
// code alone, so it cannot quietly grow to cover names we have never seen.
static void test_suunto_rejection_requires_the_full_shape(void) {
    expect_ble_match("S19", "S1", 0);
    expect_ble_match("S19 1DFC", "S1", 0);
    expect_ble_match("S19 1DFC LE EXTRA", "S1", 0);
    printf("PASS: test_suunto_rejection_requires_the_full_shape\n");
}

// The model code is pinned to the captured "S19" rather than to any "S1x", so
// a sibling model on the same Suunto platform is still claimed by the Oceans
// S1 row until someone logs its advertised name. That is deliberate:
// suppressing a name nobody has captured is the same guess this fix avoids,
// and hiding a device is harder to diagnose than mislabelling one.
static void test_unobserved_model_codes_are_not_suppressed(void) {
    expect_ble_match("S18 1DFC LE", "S1", 0);
    expect_ble_match("S10 700B LE", "S1", 0);
    printf("PASS: test_unobserved_model_codes_are_not_suppressed\n");
}

// Issue #123 regression guard: the Oceans S1 itself must be untouched. Its
// real advertised name is documented nowhere: not in libdivecomputer, not in
// Subsurface, not in the S1 manual, which pairs by QR code. That is exactly
// why this fix rejects one known-foreign name instead of tightening the "S1"
// prefix on a guess. Every plausible S1 name still resolves.
static void test_oceans_s1_names_still_resolve(void) {
    expect_ble_match("S1", "S1", 0);
    expect_ble_match("S1 1234", "S1", 0);
    expect_ble_match("S12345", "S1", 0);
    expect_ble_match("S1-1234", "S1", 0);
    printf("PASS: test_oceans_s1_names_still_resolve\n");
}

// Issue #1419: a Seac Tablet was never discovered over BLE on Android even
// though the same computer downloads fine over the USB cable. "Tablet" is the
// only BLE-capable Seac row, so the digits in its advertised name are a plain
// serial and disambiguate nothing -- yet upstream matched them with
// dc_match_prefix_with_number, which accepts "Tablet" followed by ASCII digits
// and NOTHING else. Any separator or letter in the serial made the scanner
// drop the advertisement before it ever reached the wizard.
//
// The serials below are synthetic: no digit position is significant, only the
// shape of the name.
static void test_seac_tablet_serial_spellings_resolve(void) {
    // The form upstream documented, and the bare model word.
    expect_ble_match("Tablet123456", "Tablet", 0x10);
    expect_ble_match("Tablet", "Tablet", 0x10);
    // Separated serials.
    expect_ble_match("Tablet 123456", "Tablet", 0x10);
    expect_ble_match("Tablet-123456", "Tablet", 0x10);
    expect_ble_match("Tablet_123456", "Tablet", 0x10);
    // Alphanumeric serials.
    expect_ble_match("Tablet1A2B3C", "Tablet", 0x10);
    expect_ble_match("Tablet A1B2C3", "Tablet", 0x10);
    // Vendor-prefixed, the spelling several other vendors advertise.
    expect_ble_match("Seac Tablet 123456", "Tablet", 0x10);
    expect_ble_match("SeacTablet123456", "Tablet", 0x10);
    // Advertised names vary in case by firmware and Bluetooth stack.
    expect_ble_match("TABLET-123456", "Tablet", 0x10);
    expect_ble_match("SEAC TABLET 123456", "Tablet", 0x10);
    printf("PASS: test_seac_tablet_serial_spellings_resolve\n");
}

// "Tablet" is an ordinary English word, so widening the Seac filter must not
// turn every nearby consumer peripheral into a "recognized" dive computer.
// A false positive is worse than a miss: the wizard promises a download and
// then speaks the Seac protocol to something that cannot answer (issue #123).
// The serial token has to contain a digit, and only one separator is allowed,
// which is what keeps these out.
static void test_seac_filter_does_not_claim_generic_tablets(void) {
    expect_no_ble_match("Tablet PC");
    expect_no_ble_match("Tablet-Pro");
    expect_no_ble_match("Tabletop");
    // A serial that is not separated from the model word has to start with a
    // digit. Without that boundary a letter simply continues "Tablet" and any
    // later digit satisfies the serial rule, so ordinary consumer names get
    // claimed: these three are the shapes that slipped through.
    expect_no_ble_match("Tabletop123");
    expect_no_ble_match("TabletS6");
    expect_no_ble_match("TabletPC1");
    expect_no_ble_match("Tablet S6 Lite");
    expect_no_ble_match("My Tablet 123456");
    expect_no_ble_match("Seac");
    printf("PASS: test_seac_filter_does_not_claim_generic_tablets\n");
}

// An advertised name can arrive whitespace-padded, and trailing space survives
// strlen where the Perdix 3's trailing NUL (issue #723) does not: a NUL simply
// ends the C string. Padding leaves no serial token, which is the bare model
// word rather than a foreign device.
static void test_seac_tablet_padded_names_resolve(void) {
    expect_ble_match("Tablet ", "Tablet", 0x10);
    expect_ble_match("Tablet 123456 ", "Tablet", 0x10);
    expect_ble_match("Seac Tablet ", "Tablet", 0x10);
    // A dangling "-" or "_" is not padding. A separator promises a serial
    // token, so a name ending on one is malformed rather than padded, and
    // tolerating it would widen the false-positive surface for no device
    // anyone has observed.
    expect_no_ble_match("Tablet-");
    expect_no_ble_match("Tablet_");
    expect_no_ble_match("Tablet - ");
    printf("PASS: test_seac_tablet_padded_names_resolve\n");
}

// The manufacturer is Seacsub S.p.A. and its own marketing writes "SEAC SUB",
// so the vendor word is not always the bare "Seac" token. Stripping only the
// short spelling leaves the longer ones unmatched for no reason.
static void test_seac_vendor_word_spellings_resolve(void) {
    expect_ble_match("Seacsub Tablet 123456", "Tablet", 0x10);
    expect_ble_match("SEAC SUB Tablet 123456", "Tablet", 0x10);
    expect_ble_match("SeacSub Tablet", "Tablet", 0x10);
    expect_ble_match("Seacsub-Tablet-123456", "Tablet", 0x10);
    // The vendor word is only ever stripped when the model word follows it, so
    // neither the bare vendor name nor an unrelated Seac product is claimed.
    expect_no_ble_match("Seacsub");
    expect_no_ble_match("Seacraft Ghost 123456");
    printf("PASS: test_seac_vendor_word_spellings_resolve\n");
}

// The other two Seac Screen rows are cable-only (DC_TRANSPORT_SERIAL), so a
// BLE advertisement must not resolve to them however it is spelled.
static void test_seac_cable_only_models_stay_off_ble(void) {
    expect_no_ble_match("Screen123456");
    expect_no_ble_match("Action123456");
    printf("PASS: test_seac_cable_only_models_stay_off_ble\n");
}

int main(void) {
    test_hud_resolves_to_g2_hud();
    test_other_short_aliases_resolve();
    test_alias_match_is_case_insensitive();
    test_exact_product_names_unchanged();
    test_non_uwatec_device_unaffected();
    test_perdix_3_resolves();
    test_hw_ostc_suffixed_names_resolve();
    test_hw_ostc_sport_alias_resolves();
    test_hw_ostc_alias_does_not_match_longer_word();
    test_other_perdix_models_unchanged();
    test_symbios_handset_resolves_to_handset();
    test_symbios_hud_resolves_to_hud();
    test_suunto_ocean_is_not_claimed_by_oceans_s1();
    test_suunto_ocean_rejection_is_case_insensitive();
    test_suunto_rejection_requires_the_full_shape();
    test_unobserved_model_codes_are_not_suppressed();
    test_oceans_s1_names_still_resolve();
    test_seac_tablet_serial_spellings_resolve();
    test_seac_filter_does_not_claim_generic_tablets();
    test_seac_tablet_padded_names_resolve();
    test_seac_vendor_word_spellings_resolve();
    test_seac_cable_only_models_stay_off_ble();
    printf("\nAll descriptor match integration tests passed.\n");
    return 0;
}

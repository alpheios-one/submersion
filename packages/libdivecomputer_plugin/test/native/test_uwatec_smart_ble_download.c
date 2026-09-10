// Regression test for issue #285: a Scubapro G2 HUD connected over BLE,
// streamed its whole logbook to 100%, and then the download failed with
// result=-8 (macOS) or result=-7 (Android). Both failures live at the
// transport boundary, not in the Uwatec driver, and this test pins the
// contract the driver relies on from the driver's side.
//
// uwatec_smart_usbhid_receive() treats every dc_iostream_read() as exactly
// one BLE notification: it strips the first byte and keeps `transferred - 1`
// bytes of payload. It cannot re-frame a read that carries several
// notifications, because G2 firmware 1.4+ no longer puts a length in that
// first byte for multi-packet replies (see the comment in uwatec_smart.c), so
// there is no boundary information left in the bytes themselves. That makes
// the BLE transport's one-notification-per-read guarantee (PacketReadBuffer
// on darwin, the readQueue in the Android BleIoStream) load-bearing for this
// driver:
//
//   * A transport that coalesces notifications into one flat read (the
//     darwin behaviour before PR #321) hands the 4-byte CMD_DATA answer to the
//     driver glued to the first data packets. The driver sees 64+ bytes of
//     payload for a 4-byte answer and returns DC_STATUS_PROTOCOL (-8). That
//     is the reporter's macOS trace byte for byte.
//   * A transport that loses a single notification (the Android trace, where
//     a leaked second GATT client and the default connection interval were in
//     play) leaves the receive loop short of the announced length. The stream
//     carries no flow control and no trailer, so the loop waits for bytes that
//     never come and returns DC_STATUS_TIMEOUT (-7) after the last packet.
//
// The scripted conversation (command bytes and every reply) is taken from the
// reporter's macOS debug log for the HUD, so the handshake values are those
// of a real device: model 0x42 (G2 HUD), hardware 0x24, software 0x15,
// serial 0x044AAAC7, and the a5a55a5a dive header that opens its logbook.
//
// uwatec_smart_device_dump/foreach are static, so the translation unit is
// #included. The device struct is built by hand, as test_hw_ostc3_read.c does,
// because device.c (dc_device_allocate and friends) cannot be linked without
// dragging in every driver.

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libdivecomputer/buffer.h>
#include <libdivecomputer/common.h>
#include <libdivecomputer/context.h>
#include <libdivecomputer/custom.h>

#include "uwatec_smart.c"

// ---------------------------------------------------------------------------
// Stubs for device.c symbols the #included driver references.
// ---------------------------------------------------------------------------

// uwatec_smart_extract_dives guards with ISINSTANCE; the hand-built device is
// a genuine uwatec_smart_device_t, so answer yes.
int dc_device_isinstance(dc_device_t *device, const dc_device_vtable_t *vtable) {
  (void)device;
  (void)vtable;
  return 1;
}

// Only reachable from uwatec_smart_device_open, which this test never calls.
dc_device_t *dc_device_allocate(dc_context_t *context,
                                const dc_device_vtable_t *vtable) {
  (void)context;
  (void)vtable;
  return NULL;
}
void dc_device_deallocate(dc_device_t *device) { (void)device; }

// Capture the events the dump emits so the test can check the device info
// and the progress accounting the Flutter progress bar is fed from.
static dc_event_progress_t g_progress;
static dc_event_devinfo_t g_devinfo;
static int g_devinfo_events;

void device_event_emit(dc_device_t *device, dc_event_type_t event,
                       const void *data) {
  (void)device;
  if (event == DC_EVENT_PROGRESS) {
    g_progress = *(const dc_event_progress_t *)data;
  } else if (event == DC_EVENT_DEVINFO) {
    g_devinfo = *(const dc_event_devinfo_t *)data;
    g_devinfo_events++;
  }
}

// ---------------------------------------------------------------------------
// The HUD's side of the conversation.
// ---------------------------------------------------------------------------

// One GATT notification on the HUD is at most 20 bytes: a leading byte the
// driver discards plus 19 bytes of payload.
#define NOTIFICATION_MAX 20
#define NOTIFICATION_PAYLOAD 19

// The logbook served for the test: one dive record whose header, length and
// fingerprint are the first bytes the reporter's HUD sent after CMD_DATA
// (a5a55a5a 83010000 a8b3f352). 0x183 = 387 bytes, so the stream is 20 full
// notifications plus a short 8-byte tail, like the real download's tail.
#define DIVE_LENGTH 0x183
static const unsigned char kDiveHeader[12] = {0xa5, 0xa5, 0x5a, 0x5a, 0x83, 0x01,
                                              0x00, 0x00, 0xa8, 0xb3, 0xf3, 0x52};

// A scripted exchange: the bytes the driver must write, followed by the
// notifications the HUD answers with. The data stream after CMD_DATA is
// generated rather than listed.
typedef struct {
  const unsigned char *command;
  size_t command_len;
  const unsigned char *reply;
  size_t reply_len;
} exchange_t;

static const unsigned char kCmdModel[] = {0x01, 0x10};
static const unsigned char kRepModel[] = {0x01, 0x42};
static const unsigned char kCmdHardware[] = {0x01, 0x11};
static const unsigned char kRepHardware[] = {0x01, 0x24};
static const unsigned char kCmdSoftware[] = {0x01, 0x13};
static const unsigned char kRepSoftware[] = {0x01, 0x15};
static const unsigned char kCmdSerial[] = {0x01, 0x14};
static const unsigned char kRepSerial[] = {0x04, 0xc7, 0xaa, 0x4a, 0x04};
static const unsigned char kCmdDevtime[] = {0x01, 0x1a};
static const unsigned char kRepDevtime[] = {0x04, 0x88, 0xfc, 0x57, 0x63};
// Fingerprint 0 (full download), then the fixed 10 27 00 00 tail.
static const unsigned char kCmdSize[] = {0x09, 0xc6, 0x00, 0x00, 0x00,
                                         0x00, 0x10, 0x27, 0x00, 0x00};
static const unsigned char kRepSize[] = {0x04, DIVE_LENGTH & 0xff,
                                         (DIVE_LENGTH >> 8) & 0xff, 0x00, 0x00};
static const unsigned char kCmdData[] = {0x09, 0xc4, 0x00, 0x00, 0x00,
                                         0x00, 0x10, 0x27, 0x00, 0x00};
// CMD_DATA announces length + 4, which the driver cross-checks.
static const unsigned char kRepData[] = {0x04, (DIVE_LENGTH + 4) & 0xff,
                                         ((DIVE_LENGTH + 4) >> 8) & 0xff, 0x00,
                                         0x00};

static const exchange_t kScript[] = {
    {kCmdModel, sizeof(kCmdModel), kRepModel, sizeof(kRepModel)},
    {kCmdHardware, sizeof(kCmdHardware), kRepHardware, sizeof(kRepHardware)},
    {kCmdSoftware, sizeof(kCmdSoftware), kRepSoftware, sizeof(kRepSoftware)},
    {kCmdSerial, sizeof(kCmdSerial), kRepSerial, sizeof(kRepSerial)},
    {kCmdDevtime, sizeof(kCmdDevtime), kRepDevtime, sizeof(kRepDevtime)},
    {kCmdSize, sizeof(kCmdSize), kRepSize, sizeof(kRepSize)},
    {kCmdData, sizeof(kCmdData), kRepData, sizeof(kRepData)},
};
#define SCRIPT_STEPS (sizeof(kScript) / sizeof(kScript[0]))
#define DATA_STEP (SCRIPT_STEPS - 1)

typedef struct {
  unsigned char bytes[NOTIFICATION_MAX];
  size_t len;
} notification_t;

#define QUEUE_MAX 64

typedef struct {
  // Transport behaviour under test.
  int coalesce;           // 1: flatten queued notifications into one read
  int drop_data_packet;   // index of the data notification to lose, or -1

  // Scripted state.
  size_t step;
  int script_error;
  unsigned char logbook[DIVE_LENGTH];

  // Pending notifications, oldest first.
  notification_t queue[QUEUE_MAX];
  size_t head;
  size_t tail;

  int read_calls;
  int write_calls;
} mock_hud_t;

static void mock_init(mock_hud_t *m, int coalesce, int drop_data_packet) {
  memset(m, 0, sizeof(*m));
  m->coalesce = coalesce;
  m->drop_data_packet = drop_data_packet;
  memcpy(m->logbook, kDiveHeader, sizeof(kDiveHeader));
  for (size_t i = sizeof(kDiveHeader); i < DIVE_LENGTH; i++) {
    m->logbook[i] = (unsigned char)(i & 0xff);
  }
}

static void mock_notify(mock_hud_t *m, const unsigned char *bytes, size_t len) {
  assert(m->tail < QUEUE_MAX);
  assert(len <= NOTIFICATION_MAX);
  memcpy(m->queue[m->tail].bytes, bytes, len);
  m->queue[m->tail].len = len;
  m->tail++;
}

// Stream the logbook the way the HUD does: 19 payload bytes per notification
// behind a leading byte the driver ignores on BLE. The real firmware puts its
// rolling 0x13/0x27/... counter there; the test uses 0x13 throughout, since
// the driver must not read it.
static void mock_stream_logbook(mock_hud_t *m) {
  size_t offset = 0;
  int index = 0;
  while (offset < DIVE_LENGTH) {
    size_t payload = DIVE_LENGTH - offset;
    if (payload > NOTIFICATION_PAYLOAD) payload = NOTIFICATION_PAYLOAD;
    if (index != m->drop_data_packet) {
      unsigned char packet[NOTIFICATION_MAX];
      packet[0] = 0x13;
      memcpy(packet + 1, m->logbook + offset, payload);
      mock_notify(m, packet, payload + 1);
    }
    offset += payload;
    index++;
  }
}

static dc_status_t mock_write(void *userdata, const void *data, size_t size,
                              size_t *actual) {
  mock_hud_t *m = (mock_hud_t *)userdata;
  m->write_calls++;
  if (m->step >= SCRIPT_STEPS) {
    fprintf(stderr, "  unexpected write after the script ended\n");
    m->script_error = 1;
    return DC_STATUS_IO;
  }
  const exchange_t *x = &kScript[m->step];
  if (size != x->command_len || memcmp(data, x->command, size) != 0) {
    fprintf(stderr, "  step %zu: unexpected command bytes\n", m->step);
    m->script_error = 1;
    return DC_STATUS_IO;
  }
  mock_notify(m, x->reply, x->reply_len);
  if (m->step == DATA_STEP) mock_stream_logbook(m);
  m->step++;
  if (actual) *actual = size;
  return DC_STATUS_SUCCESS;
}

// Copy from the oldest notification, keeping any unread remainder at the
// head. This is the PacketReadBuffer / BleIoStream.readQueue contract.
static size_t mock_take_one(mock_hud_t *m, unsigned char *dest, size_t size) {
  notification_t *n = &m->queue[m->head];
  size_t count = size < n->len ? size : n->len;
  memcpy(dest, n->bytes, count);
  if (count < n->len) {
    memmove(n->bytes, n->bytes + count, n->len - count);
    n->len -= count;
  } else {
    m->head++;
  }
  return count;
}

static dc_status_t mock_read(void *userdata, void *data, size_t size,
                             size_t *actual) {
  mock_hud_t *m = (mock_hud_t *)userdata;
  m->read_calls++;
  if (m->head == m->tail) {
    // Nothing queued and nothing more coming: the 5 s read timeout expires.
    if (actual) *actual = 0;
    return DC_STATUS_TIMEOUT;
  }
  unsigned char *dest = (unsigned char *)data;
  size_t n = 0;
  if (m->coalesce) {
    // Pre-#321 darwin: every buffered notification that fits is returned in
    // one read, with no record of where one ended and the next began.
    while (m->head != m->tail && n < size) {
      n += mock_take_one(m, dest + n, size - n);
    }
  } else {
    n = mock_take_one(m, dest, size);
  }
  if (actual) *actual = n;
  return DC_STATUS_SUCCESS;
}

static dc_status_t mock_close(void *userdata) {
  (void)userdata;
  return DC_STATUS_SUCCESS;
}

// ---------------------------------------------------------------------------
// Driving the driver.
// ---------------------------------------------------------------------------

typedef struct {
  int dives;
  int payload_ok;
  unsigned char fingerprint[4];
} dive_sink_t;

static int on_dive(const unsigned char *data, unsigned int size,
                   const unsigned char *fingerprint, unsigned int fsize,
                   void *userdata) {
  dive_sink_t *sink = (dive_sink_t *)userdata;
  sink->dives++;
  sink->payload_ok = (size == DIVE_LENGTH &&
                      memcmp(data, kDiveHeader, sizeof(kDiveHeader)) == 0);
  if (fsize == sizeof(sink->fingerprint)) {
    memcpy(sink->fingerprint, fingerprint, fsize);
  }
  return 1;
}

static dc_status_t run_download(mock_hud_t *m, dive_sink_t *sink) {
  memset(&g_progress, 0, sizeof(g_progress));
  memset(&g_devinfo, 0, sizeof(g_devinfo));
  g_devinfo_events = 0;
  memset(sink, 0, sizeof(*sink));

  dc_context_t *ctx = NULL;
  assert(dc_context_new(&ctx) == DC_STATUS_SUCCESS);

  dc_custom_cbs_t cbs;
  memset(&cbs, 0, sizeof(cbs));
  cbs.read = mock_read;
  cbs.write = mock_write;
  cbs.close = mock_close;

  dc_iostream_t *iostream = NULL;
  assert(dc_custom_open(&iostream, ctx, DC_TRANSPORT_BLE, &cbs, m) ==
         DC_STATUS_SUCCESS);

  // What uwatec_smart_device_open sets up for DC_TRANSPORT_BLE, minus the
  // allocation that needs device.c.
  uwatec_smart_device_t dev;
  memset(&dev, 0, sizeof(dev));
  dev.base.vtable = &uwatec_smart_device_vtable;
  dev.base.context = ctx;
  dev.iostream = iostream;
  dev.send = uwatec_smart_usbhid_send;
  dev.receive = uwatec_smart_usbhid_receive;
  dev.timestamp = 0;
  dev.systime = (dc_ticks_t)-1;

  dc_status_t rc = uwatec_smart_device_foreach(&dev.base, on_dive, sink);

  dc_iostream_close(iostream);
  dc_context_free(ctx);
  return rc;
}

static int failures = 0;

#define CHECK(cond, ...)                          \
  do {                                            \
    if (!(cond)) {                                \
      failures++;                                 \
      fprintf(stderr, "  FAIL: " __VA_ARGS__);    \
      fprintf(stderr, "\n");                      \
    }                                             \
  } while (0)

// The whole progress range the dump announces: 4 + 11 handshake bytes, the
// 4-byte data answer, and the logbook itself.
#define EXPECTED_PROGRESS_MAX (4u + 11u + DIVE_LENGTH + 4u)

// Case 1: a transport that returns one notification per read completes the
// download, delivers the dive, and lands progress exactly on its maximum.
static void test_one_notification_per_read_downloads_the_logbook(void) {
  mock_hud_t m;
  dive_sink_t sink;
  mock_init(&m, /*coalesce=*/0, /*drop_data_packet=*/-1);

  dc_status_t rc = run_download(&m, &sink);

  CHECK(!m.script_error, "driver sent bytes the HUD did not expect");
  CHECK(rc == DC_STATUS_SUCCESS, "expected SUCCESS, got %d", (int)rc);
  CHECK(m.write_calls == (int)SCRIPT_STEPS, "expected %zu commands, got %d",
        SCRIPT_STEPS, m.write_calls);
  CHECK(sink.dives == 1, "expected 1 dive, got %d", sink.dives);
  CHECK(sink.payload_ok, "dive payload was not the logbook that was streamed");
  CHECK(memcmp(sink.fingerprint, kDiveHeader + 8, 4) == 0,
        "fingerprint was not the record's timestamp bytes");
  CHECK(g_devinfo_events == 1, "expected one DEVINFO event, got %d",
        g_devinfo_events);
  CHECK(g_devinfo.model == 0x42, "expected model 0x42 (G2 HUD), got 0x%02x",
        g_devinfo.model);
  CHECK(g_devinfo.serial == 72002247u, "expected serial 72002247, got %u",
        g_devinfo.serial);
  CHECK(g_devinfo.firmware == 15, "expected firmware 15, got %u",
        g_devinfo.firmware);
  CHECK(g_progress.maximum == EXPECTED_PROGRESS_MAX,
        "expected progress maximum %u, got %u", EXPECTED_PROGRESS_MAX,
        g_progress.maximum);
  CHECK(g_progress.current == g_progress.maximum,
        "progress ended at %u of %u", g_progress.current, g_progress.maximum);

  printf("%s: one notification per read -> rc=%d dives=%d reads=%d\n",
         failures ? "DONE" : "PASS", (int)rc, sink.dives, m.read_calls);
}

// Case 2: the macOS -8. A transport that flattens notifications hands the
// driver the 4-byte CMD_DATA answer glued to the first data packets. The
// driver has no way to re-frame that and must refuse it as a protocol error
// rather than treat the surplus as logbook bytes.
static void test_coalesced_reads_fail_with_protocol_error(void) {
  mock_hud_t m;
  dive_sink_t sink;
  mock_init(&m, /*coalesce=*/1, /*drop_data_packet=*/-1);

  dc_status_t rc = run_download(&m, &sink);

  CHECK(!m.script_error, "driver sent bytes the HUD did not expect");
  CHECK(rc == DC_STATUS_PROTOCOL, "expected PROTOCOL (-8), got %d", (int)rc);
  CHECK(sink.dives == 0, "no dive may be delivered from a misframed stream");
  // The handshake replies are single notifications, so they survive
  // coalescing; the failure is at the data answer.
  CHECK(m.write_calls == (int)SCRIPT_STEPS,
        "expected the failure at the CMD_DATA answer, but only %d commands ran",
        m.write_calls);

  printf("%s: coalesced reads -> rc=%d (the macOS -8)\n",
         failures ? "DONE" : "PASS", (int)rc);
}

// Case 3: the Android -7. Losing one notification from a stream with no flow
// control and no trailer leaves the receive loop waiting for bytes that never
// arrive. The failure is a timeout after the last real packet, with progress
// short by exactly one payload, and never a truncated dive.
static void test_dropped_notification_times_out_after_the_last_packet(void) {
  mock_hud_t m;
  dive_sink_t sink;
  mock_init(&m, /*coalesce=*/0, /*drop_data_packet=*/10);

  dc_status_t rc = run_download(&m, &sink);

  CHECK(!m.script_error, "driver sent bytes the HUD did not expect");
  CHECK(rc == DC_STATUS_TIMEOUT, "expected TIMEOUT (-7), got %d", (int)rc);
  CHECK(sink.dives == 0, "no dive may be delivered from a short stream");
  CHECK(g_progress.current == g_progress.maximum - NOTIFICATION_PAYLOAD,
        "expected progress short by one payload (%u), got %u of %u",
        NOTIFICATION_PAYLOAD, g_progress.current, g_progress.maximum);
  CHECK(m.head == m.tail, "the driver stopped before draining the stream");

  printf("%s: one dropped notification -> rc=%d (the Android -7)\n",
         failures ? "DONE" : "PASS", (int)rc);
}

int main(void) {
  test_one_notification_per_read_downloads_the_logbook();
  test_coalesced_reads_fail_with_protocol_error();
  test_dropped_notification_times_out_after_the_last_packet();

  if (failures) {
    printf("%d check(s) failed\n", failures);
    return 1;
  }
  printf("All uwatec_smart BLE download checks passed\n");
  return 0;
}

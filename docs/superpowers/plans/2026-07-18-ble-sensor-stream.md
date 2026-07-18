# M2a.2 — Accelerometer-over-BLE Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tag stream its accelerometer readings to the phone over a custom BLE GATT notify characteristic, verifiable in nRF Connect.

**Architecture:** A reusable `sensor_ble` module hides all SoftDevice/GATT detail behind two functions (`sensor_ble_init` / `sensor_ble_notify`). A thin `sensor_stream` example entry samples the accelerometer at 100 Hz via `app_timer`, assembles the frozen 16-byte packet (distance = sentinel), and notifies. The phone is the brain (see `docs/architecture.md`).

**Tech Stack:** nRF5 SDK 17.1.0, S112 SoftDevice (BLE API v7), SES/emBuild in Docker, J-Link from macOS host, LIS2DH12 accel driver (M1).

## Global Constraints

- **Wire contract is frozen** (verbatim from spec / iOS decoder): service UUID `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`, notify characteristic `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`; packet is **16 bytes little-endian**: `seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32`; `uwb_mm = 0xFFFFFFFF` (sentinel) in M2a.2.
- **Build in Docker, force amd64:** `DOCKER_DEFAULT_PLATFORM=linux/amd64 make build` (Docker Desktop must be running). Output hex: `Output/Common/Exe/dw3000_api.hex`.
- **Always `make clean` first when the emProject or its defines changed** — stale objects caused the M2a.1 HardFault.
- **Flash from macOS host** (Docker can't pass USB), SoftDevice first: `JLinkExe` → `erase`, `loadfile hex/s112_softdevice.hex`, `loadfile Output/Common/Exe/dw3000_api.hex`, `r`, `g`.
- **Board serials:** #1 `760224825`, #2 `760224846`. Only labelled data USB cable + J9 lower port.
- **Power-cycle before trusting an RTT read** (stale RAM latches ghost output).
- All new `.c` files MUST be added to `dw3000_api.emProject` or they won't compile.

---

### Task 1: Freeze the wire contract document

**Files:**
- Create: `firmware/ble-contract.md`

**Interfaces:**
- Produces: the single source of truth referenced by both firmware and `ios/SensorCore/Sources/SensorCore/SensorPacket.swift`.

- [ ] **Step 1: Write `firmware/ble-contract.md`**

```markdown
# BLE contract — sensor stream (single source of truth)

Shared by the tag firmware (`Src/ble/sensor_ble.c`) and the iOS app
(`ios/SensorCore/Sources/SensorCore/SensorPacket.swift`). Do not change one side
without the other.

## GATT
- Service UUID (128-bit):        `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
- Sensor characteristic (notify): `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
  - Properties: Notify. Contains a CCCD so the central can enable notifications.
  - Value length: 16 bytes, fixed.

## Packet (16 bytes, little-endian)
| offset | field          | type   | notes                                  |
|--------|----------------|--------|----------------------------------------|
| 0      | seq            | uint16 | +1 per packet, wraps at 65535          |
| 2      | board_time_ms  | uint32 | monotonic ms since boot                |
| 6      | ax             | int16  | raw left-justified LIS2DH12 X          |
| 8      | ay             | int16  | raw left-justified LIS2DH12 Y          |
| 10     | az             | int16  | raw left-justified LIS2DH12 Z          |
| 12     | uwb_mm         | uint32 | distance mm; 0xFFFFFFFF = none         |

- Accel raw counts: at rest the down axis reads ~±256 counts after `>>6` (1 g @ ±2 g).
- `uwb_mm = 0xFFFFFFFF` on the responder always, and on the initiator until live
  ranging exists (M2b). In M2a.2 both roles send the sentinel.

## Advertising
- Name by role: `DWM-INIT` / `DWM-RESP`.
- The 128-bit service UUID is included in the scan-response data (so the phone can
  scan by service UUID in M3).
```

- [ ] **Step 2: Verify it matches the iOS decoder**

Run: `sed -n '1,12p' ios/SensorCore/Sources/SensorCore/SensorPacket.swift`
Expected: the field order/offsets and the `0xFFFFFFFF` sentinel match the table above.

- [ ] **Step 3: Commit**

```bash
git add firmware/ble-contract.md
git commit -m "docs(fw): freeze BLE sensor-stream wire contract"
```

---

### Task 2: Implement the `sensor_ble` module + `sensor_stream` loop and verify the stream

**Files:**
- Create: `firmware/DWM3001C-starter-firmware/Src/ble/sensor_ble.h`
- Create: `firmware/DWM3001C-starter-firmware/Src/ble/sensor_ble.c`
- Create: `firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c`
- Modify: `firmware/DWM3001C-starter-firmware/Src/example_selection.h`
- Modify: `firmware/DWM3001C-starter-firmware/Src/main.c`
- Modify: `firmware/DWM3001C-starter-firmware/dw3000_api.emProject`

**Interfaces:**
- Consumes: `accel_init()`, `accel_read(int16_t*,int16_t*,int16_t*)` (from `Src/accel/accel.h`); `test_run_info(unsigned char*)` (main.c); SoftDevice `sd_ble_*`, `app_timer_*`.
- Produces: `bool sensor_ble_init(void)`, `void sensor_ble_notify(const uint8_t packet[16])` (in `sensor_ble.h`); `int sensor_stream(void)` (extern'd from main.c).

- [ ] **Step 1: Create `Src/ble/sensor_ble.h`**

```c
#ifndef SENSOR_BLE_H_
#define SENSOR_BLE_H_

#include <stdint.h>
#include <stdbool.h>

/* Bring up the S112 SoftDevice, the custom sensor GATT service (notify), and
 * advertising by role name (DWM-INIT / DWM-RESP per SENSOR_ROLE_INITIATOR).
 * Returns false on any init failure (step results are printed over RTT). */
bool sensor_ble_init(void);

/* Push one 16-byte sensor packet to the connected+subscribed central as a GATT
 * notification. Silent no-op if no central is connected, notifications are not
 * enabled, or the SoftDevice tx buffers are full. Never blocks. */
void sensor_ble_notify(const uint8_t packet[16]);

#endif /* SENSOR_BLE_H_ */
```

- [ ] **Step 2: Create `Src/ble/sensor_ble.c`**

```c
/* Custom BLE sensor service (Milestone 2a.2): S112 SoftDevice + advertising +
 * a notify characteristic streaming the 16-byte packet from firmware/ble-contract.md. */

#include "example_selection.h"

#if defined(TEST_SENSOR_STREAM)

#include <string.h>
#include <stdio.h>
#include "nrf_sdh.h"
#include "nrf_sdh_ble.h"
#include "nrf_sdh_soc.h"
#include "ble.h"
#include "ble_advdata.h"
#include "ble_advertising.h"
#include "nrf_ble_gatt.h"
#include "app_timer.h"
#include "app_error.h"
#include "nrf_soc.h"
#include "nrf_nvic.h"
#include "sensor_ble.h"

extern void test_run_info(unsigned char *data);

#if defined(SENSOR_ROLE_INITIATOR)
  #define DEVICE_NAME "DWM-INIT"
#else
  #define DEVICE_NAME "DWM-RESP"
#endif

#define APP_BLE_CONN_CFG_TAG   1
#define APP_BLE_OBSERVER_PRIO  3
#define APP_ADV_INTERVAL       64   /* 40 ms, in 0.625 ms units */
#define APP_ADV_DURATION       0    /* advertise forever */
#define SENSOR_PACKET_LEN      16

/* 128-bit base UUID (little-endian) for 6E40____-B5A3-F393-E0A9-E50E24DCCA9E;
 * the 16-bit part below selects the service/characteristic. */
#define SENSOR_UUID_BASE  {0x9E,0xCA,0xDC,0x24,0x0E,0xE5,0xA9,0xE0, \
                           0x93,0xF3,0xA3,0xB5,0x00,0x00,0x40,0x6E}
#define SENSOR_UUID_SERVICE  0xFE00
#define SENSOR_UUID_CHAR     0xFE01

NRF_BLE_GATT_DEF(m_gatt);
BLE_ADVERTISING_DEF(m_advertising);

static uint16_t                 m_conn_handle = BLE_CONN_HANDLE_INVALID;
static uint8_t                  m_uuid_type;
static uint16_t                 m_service_handle;
static ble_gatts_char_handles_t m_char_handles;

static void dbg(const char *name, uint32_t err)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "  %s -> 0x%lx", name, (unsigned long)err);
    test_run_info((unsigned char *)buf);
}

static void ble_evt_handler(ble_evt_t const *p_ble_evt, void *p_context)
{
    switch (p_ble_evt->header.evt_id)
    {
        case BLE_GAP_EVT_CONNECTED:
            m_conn_handle = p_ble_evt->evt.gap_evt.conn_handle;
            test_run_info((unsigned char *)"BLE: connected");
            break;

        case BLE_GAP_EVT_DISCONNECTED:
            m_conn_handle = BLE_CONN_HANDLE_INVALID;
            test_run_info((unsigned char *)"BLE: disconnected");
            (void)ble_advertising_start(&m_advertising, BLE_ADV_MODE_FAST);
            break;

        default:
            break;
    }
}
NRF_SDH_BLE_OBSERVER(m_ble_observer, APP_BLE_OBSERVER_PRIO, ble_evt_handler, NULL);

static bool stack_init(void)
{
    uint32_t err = nrf_sdh_enable_request();
    dbg("sdh_enable", err);
    if (err != NRF_SUCCESS) return false;

    uint32_t ram_start = 0;
    err = nrf_sdh_ble_default_cfg_set(APP_BLE_CONN_CFG_TAG, &ram_start);
    dbg("ble_cfg_set", err);
    if (err != NRF_SUCCESS) return false;

    err = nrf_sdh_ble_enable(&ram_start);
    dbg("ble_enable", err);
    return err == NRF_SUCCESS;
}

static bool gap_gatt_init(void)
{
    ble_gap_conn_sec_mode_t sec_mode;
    BLE_GAP_CONN_SEC_MODE_SET_OPEN(&sec_mode);
    uint32_t err = sd_ble_gap_device_name_set(
        &sec_mode, (const uint8_t *)DEVICE_NAME, strlen(DEVICE_NAME));
    if (err != NRF_SUCCESS) { dbg("name_set", err); return false; }

    ble_gap_conn_params_t cp;
    memset(&cp, 0, sizeof(cp));
    cp.min_conn_interval = MSEC_TO_UNITS(20, UNIT_1_25_MS);
    cp.max_conn_interval = MSEC_TO_UNITS(75, UNIT_1_25_MS);
    cp.slave_latency     = 0;
    cp.conn_sup_timeout  = MSEC_TO_UNITS(4000, UNIT_10_MS);
    err = sd_ble_gap_ppcp_set(&cp);
    if (err != NRF_SUCCESS) { dbg("ppcp_set", err); return false; }

    err = nrf_ble_gatt_init(&m_gatt, NULL);
    if (err != NRF_SUCCESS) { dbg("gatt_init", err); return false; }
    return true;
}

static bool service_init(void)
{
    ble_uuid128_t base = { SENSOR_UUID_BASE };
    uint32_t err = sd_ble_uuid_vs_add(&base, &m_uuid_type);
    if (err != NRF_SUCCESS) { dbg("uuid_vs_add", err); return false; }

    ble_uuid_t svc_uuid = { .type = m_uuid_type, .uuid = SENSOR_UUID_SERVICE };
    err = sd_ble_gatts_service_add(BLE_GATTS_SRVC_TYPE_PRIMARY, &svc_uuid, &m_service_handle);
    if (err != NRF_SUCCESS) { dbg("service_add", err); return false; }

    ble_gatts_attr_md_t cccd_md;
    memset(&cccd_md, 0, sizeof(cccd_md));
    BLE_GAP_CONN_SEC_MODE_SET_OPEN(&cccd_md.read_perm);
    BLE_GAP_CONN_SEC_MODE_SET_OPEN(&cccd_md.write_perm);
    cccd_md.vloc = BLE_GATTS_VLOC_STACK;

    ble_gatts_char_md_t char_md;
    memset(&char_md, 0, sizeof(char_md));
    char_md.char_props.notify = 1;
    char_md.p_cccd_md         = &cccd_md;

    ble_uuid_t char_uuid = { .type = m_uuid_type, .uuid = SENSOR_UUID_CHAR };

    ble_gatts_attr_md_t attr_md;
    memset(&attr_md, 0, sizeof(attr_md));
    BLE_GAP_CONN_SEC_MODE_SET_OPEN(&attr_md.read_perm);
    BLE_GAP_CONN_SEC_MODE_SET_NO_ACCESS(&attr_md.write_perm);
    attr_md.vloc = BLE_GATTS_VLOC_STACK;

    uint8_t initial[SENSOR_PACKET_LEN] = {0};
    ble_gatts_attr_t attr;
    memset(&attr, 0, sizeof(attr));
    attr.p_uuid    = &char_uuid;
    attr.p_attr_md = &attr_md;
    attr.init_len  = SENSOR_PACKET_LEN;
    attr.max_len   = SENSOR_PACKET_LEN;
    attr.p_value   = initial;

    err = sd_ble_gatts_characteristic_add(m_service_handle, &char_md, &attr, &m_char_handles);
    if (err != NRF_SUCCESS) { dbg("char_add", err); return false; }
    return true;
}

static ble_uuid_t m_adv_uuids[1];  /* referenced by the advertising module */

static bool advertising_init(void)
{
    m_adv_uuids[0].type = m_uuid_type;
    m_adv_uuids[0].uuid = SENSOR_UUID_SERVICE;

    ble_advertising_init_t init;
    memset(&init, 0, sizeof(init));
    init.advdata.name_type          = BLE_ADVDATA_FULL_NAME;
    init.advdata.include_appearance = false;
    init.advdata.flags              = BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE;
    init.srdata.uuids_complete.uuid_cnt = 1;
    init.srdata.uuids_complete.p_uuids  = m_adv_uuids;

    init.config.ble_adv_fast_enabled  = true;
    init.config.ble_adv_fast_interval = APP_ADV_INTERVAL;
    init.config.ble_adv_fast_timeout  = APP_ADV_DURATION;

    uint32_t err = ble_advertising_init(&m_advertising, &init);
    if (err != NRF_SUCCESS) { dbg("adv_init", err); return false; }
    ble_advertising_conn_cfg_tag_set(&m_advertising, APP_BLE_CONN_CFG_TAG);
    return true;
}

bool sensor_ble_init(void)
{
    if (!stack_init())       return false;
    if (!gap_gatt_init())    return false;
    if (!service_init())     return false;
    if (!advertising_init()) return false;
    uint32_t err = ble_advertising_start(&m_advertising, BLE_ADV_MODE_FAST);
    dbg("adv_start", err);
    return err == NRF_SUCCESS;
}

void sensor_ble_notify(const uint8_t packet[16])
{
    if (m_conn_handle == BLE_CONN_HANDLE_INVALID) return;

    uint16_t len = SENSOR_PACKET_LEN;
    ble_gatts_hvx_params_t hvx;
    memset(&hvx, 0, sizeof(hvx));
    hvx.handle = m_char_handles.value_handle;
    hvx.type   = BLE_GATT_HVX_NOTIFICATION;
    hvx.offset = 0;
    hvx.p_len  = &len;
    hvx.p_data = packet;
    (void)sd_ble_gatts_hvx(m_conn_handle, &hvx);  /* ignore INVALID_STATE/RESOURCES */
}

#endif /* TEST_SENSOR_STREAM */
```

- [ ] **Step 3: Create `Src/ble/sensor_stream.c`**

```c
/* Milestone 2a.2 entry point: sample the accelerometer at 100 Hz and stream the
 * 16-byte packet over BLE (uwb_mm = sentinel; live distance is M2b). */

#include "example_selection.h"

#if defined(TEST_SENSOR_STREAM)

#include <stdint.h>
#include "app_timer.h"
#include "app_error.h"
#include "nrf_soc.h"
#include "accel.h"
#include "sensor_ble.h"

extern void test_run_info(unsigned char *data);

#define SENSOR_UWB_SENTINEL  0xFFFFFFFFu
#define SAMPLE_PERIOD_MS     10   /* 100 Hz */

APP_TIMER_DEF(m_sample_timer);
static volatile bool     m_sample_due    = false;
static volatile uint32_t m_board_time_ms = 0;
static uint16_t          m_seq           = 0;

static void sample_timer_handler(void *ctx)
{
    (void)ctx;
    m_board_time_ms += SAMPLE_PERIOD_MS;
    m_sample_due = true;
}

static void pack_le16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void pack_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

int sensor_stream(void)
{
    test_run_info((unsigned char *)"SENSOR: start");

    uint32_t err = app_timer_init();
    APP_ERROR_CHECK(err);

    if (!accel_init())
    {
        test_run_info((unsigned char *)"SENSOR: accel_init FAILED");
        for (;;) { }
    }
    if (!sensor_ble_init())
    {
        test_run_info((unsigned char *)"SENSOR: sensor_ble_init FAILED");
        for (;;) { }
    }

    err = app_timer_create(&m_sample_timer, APP_TIMER_MODE_REPEATED, sample_timer_handler);
    APP_ERROR_CHECK(err);
    err = app_timer_start(m_sample_timer, APP_TIMER_TICKS(SAMPLE_PERIOD_MS), NULL);
    APP_ERROR_CHECK(err);

    test_run_info((unsigned char *)"SENSOR: streaming");

    for (;;)
    {
        if (m_sample_due)
        {
            m_sample_due = false;

            int16_t x = 0, y = 0, z = 0;
            (void)accel_read(&x, &y, &z);

            uint8_t pkt[16];
            pack_le16(&pkt[0],  m_seq++);
            pack_le32(&pkt[2],  m_board_time_ms);
            pack_le16(&pkt[6],  (uint16_t)x);
            pack_le16(&pkt[8],  (uint16_t)y);
            pack_le16(&pkt[10], (uint16_t)z);
            pack_le32(&pkt[12], SENSOR_UWB_SENTINEL);
            sensor_ble_notify(pkt);
        }
        (void)sd_app_evt_wait();   /* sleep until the next SoftDevice/app_timer event */
    }
    return 0;
}

#endif /* TEST_SENSOR_STREAM */
```

- [ ] **Step 4: Toggle the example in `Src/example_selection.h`**

Change the M2a block so `TEST_BLE` is off and the new stream + role are on:

```c
// Custom (Milestone 2a): BLE SoftDevice bring-up + advertising
//#define TEST_BLE

// Custom (Milestone 2a.2): accelerometer-over-BLE notify stream
#define TEST_SENSOR_STREAM
#define SENSOR_ROLE_INITIATOR   // comment out to build the DWM-RESP responder role
```

- [ ] **Step 5: Dispatch to `sensor_stream()` in `Src/main.c`**

Replace the active `ble_test();` dispatch line with the sensor stream (leave the commented examples as-is):

```c
    // extern int ble_test(void); ble_test();
    extern int sensor_stream(void); sensor_stream();
```

- [ ] **Step 6: Register the new sources in `dw3000_api.emProject`**

Replace the `ble` folder block:

```xml
      <folder Name="ble">
        <file file_name="Src/ble/ble_test.c" />
      </folder>
```

with:

```xml
      <folder Name="ble">
        <file file_name="Src/ble/ble_test.c" />
        <file file_name="Src/ble/sensor_ble.h" />
        <file file_name="Src/ble/sensor_ble.c" />
        <file file_name="Src/ble/sensor_stream.c" />
      </folder>
```

- [ ] **Step 7: Clean build**

Run: `cd firmware/DWM3001C-starter-firmware && DOCKER_DEFAULT_PLATFORM=linux/amd64 make clean && DOCKER_DEFAULT_PLATFORM=linux/amd64 make build`
Expected: ends with no "build errors"; `Output/Common/Exe/dw3000_api.hex` is produced (check `ls -la Output/Common/Exe/dw3000_api.hex`). If the link reports `NRF_ERROR`/undefined symbols, fix the API usage before flashing.

- [ ] **Step 8: Flash SoftDevice + app to board #2**

Run (from `firmware/`):
```bash
JLinkExe -CommanderScript /dev/stdin <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
erase
loadfile hex/s112_softdevice.hex
loadfile DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex
r
g
q
EOF
```
Expected: two `O.K.` "Program & Verify" lines.

- [ ] **Step 9: Confirm boot + init over RTT (power-cycle first)**

Unplug/replug the board's USB, then:
```bash
JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 /tmp/sensor_rtt.log &
sleep 4; kill %1; strings /tmp/sensor_rtt.log | grep -iE 'SENSOR|->|BLE'
```
Expected lines: `SENSOR: start`, `sdh_enable -> 0x0`, `ble_cfg_set -> 0x0`, `ble_enable -> 0x0`, `adv_start -> 0x0`, `SENSOR: streaming`. Any non-zero code names the failing step — fix and rebuild before continuing.

- [ ] **Step 10: Verify the stream in nRF Connect (phone)**

1. Scan → find `DWM-INIT`. Connect.
2. Discover service `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`; open characteristic `6E40FE01-…`; tap **Enable notifications** (the ↓↓↓ / triple-arrow icon).
3. Expected: 16-byte values stream and the middle bytes (offsets 6–11, the accel axes) change as you tilt/move the board.
4. Hand-decode one value: bytes[0..1] = `seq` (increments); bytes[2..5] = `board_time_ms` (increasing); bytes[6..11] = `ax/ay/az` int16 LE (one axis ≈ ±0x40xx at rest ≈ 1 g); bytes[12..15] = `FF FF FF FF`.

- [ ] **Step 11: Commit**

```bash
git add firmware/DWM3001C-starter-firmware/Src/ble/sensor_ble.h \
        firmware/DWM3001C-starter-firmware/Src/ble/sensor_ble.c \
        firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c \
        firmware/DWM3001C-starter-firmware/Src/example_selection.h \
        firmware/DWM3001C-starter-firmware/Src/main.c \
        firmware/DWM3001C-starter-firmware/dw3000_api.emProject
git commit -m "feat(fw): BLE notify stream of accel packets (M2a.2), verified in nRF Connect"
```

---

### Task 3: Verify the responder role, refresh the stashed hex, mark M2a.2 done

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/example_selection.h` (temporarily, for the responder check)
- Modify: `firmware/hex/sensor_stream_init.hex` (new stashed working image)
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: the working build from Task 2.
- Produces: confirmation both role names work; updated roadmap.

- [ ] **Step 1: Build + verify the responder name**

Comment out `#define SENSOR_ROLE_INITIATOR` in `example_selection.h`, then
`make clean && make build`, flash (Task 2 Step 8), and confirm in nRF Connect the
board now advertises **`DWM-RESP`** and streams the same packet with
`uwb_mm = FF FF FF FF`. Then restore `#define SENSOR_ROLE_INITIATOR` and
`make clean && make build` again so the committed default is the initiator.

- [ ] **Step 2: Stash the working initiator image**

Run (from `firmware/`): `cp DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex hex/sensor_stream_init.hex`

- [ ] **Step 3: Update the architecture roadmap**

In `docs/architecture.md` §6, change the M2a.2 row state from `⬜ **next**` to
`✅ verified` and set the M2b row to `⬜ **next**`. Add a decision-log line:
`- 2026-07-18 — M2a.2 verified: DWM-INIT/DWM-RESP stream accel packets over the sensor characteristic in nRF Connect.`

- [ ] **Step 4: Commit**

```bash
git add firmware/hex/sensor_stream_init.hex docs/architecture.md
git commit -m "chore(fw): stash M2a.2 stream image; mark M2a.2 verified in architecture roadmap"
```

---

## Self-Review

**Spec coverage:**
- Contract doc `firmware/ble-contract.md` → Task 1. ✅
- `sensor_ble.c/.h` two-function interface + GATT service/notify char → Task 2 Steps 1–2. ✅
- `app_timer` 100 Hz sampling, RTC-backed monotonic `board_time_ms`, sleep-between → Task 2 Step 3 (`sensor_stream.c`). ✅ (Note: `board_time_ms` is accumulated in the 10 ms `app_timer` handler — a monotonic ms source driven by the running RTC timer, wrap-safe to ~49 days; a refinement of the spec's "from the running timer".)
- `uwb_mm` sentinel in M2a.2 → `SENSOR_UWB_SENTINEL` in `sensor_stream.c`. ✅
- Compile-time role → `SENSOR_ROLE_INITIATOR` in `example_selection.h`, consumed in `sensor_ble.c`. ✅
- Service UUID in scan response (for M3 scan-by-service) → `advertising_init` `srdata`. ✅
- Verification via nRF Connect + hand-decode → Task 2 Steps 9–10. ✅
- Responder role check → Task 3 Step 1. ✅
- New sources added to emProject build → Task 2 Step 6. ✅

**Placeholder scan:** No TBD/TODO; all code blocks are complete. ✅

**Type consistency:** `sensor_ble_init`/`sensor_ble_notify` signatures match between `sensor_ble.h`, `sensor_ble.c`, and the `sensor_stream.c` call sites; `sensor_stream` is `int sensor_stream(void)` matching the `extern` in `main.c`; packet is 16 bytes everywhere (`SENSOR_PACKET_LEN` / `pkt[16]` / `const uint8_t packet[16]`). ✅

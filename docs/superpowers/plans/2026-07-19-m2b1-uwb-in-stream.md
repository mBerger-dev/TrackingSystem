# M2b.1 — Live UWB Distance in the Sensor Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The initiator streams real tag-to-tag distance in `uwb_mm` at 20 Hz while both tags keep streaming accelerometer data at 100 Hz.

**Architecture:** A new `ranging` module hides all `dwt_*` calls behind `ranging_init()` / `ranging_exchange()`. The responder answers polls from an interrupt (hard 650 µs deadline); the initiator runs one bounded blocking exchange on every fifth accel tick. Spec: `docs/superpowers/specs/2026-07-19-m2b1-uwb-in-stream-design.md`. Diagrams: `docs/architecture.drawio` pages 2 and 4.

**Tech Stack:** nRF5 SDK 17.1.0, S112 SoftDevice, DW3000/DW3110 UWB driver (`Shared/dwt_uwb_driver`), SES/emBuild in Docker, J-Link from macOS host.

## Global Constraints

- **Wire contract frozen.** 16 bytes LE: `seq:uint16 | board_time_ms:uint32 | ax:int16 | ay:int16 | az:int16 | uwb_mm:uint32`. No iOS change. Real `uwb_mm` **only** in the packet carrying a just-succeeded exchange; `0xFFFFFFFF` otherwise (between exchanges, on timeout, on failed sanity check, and always on the responder).
- **Sanity check:** reject distance < 0 or > 50 m → report failure → sentinel. This deliberately does *not* catch NLOS bias (that is M2b.2).
- **Build in Docker, force amd64:** `DOCKER_DEFAULT_PLATFORM=linux/amd64 make build` from `firmware/DWM3001C-starter-firmware`. Output: `Output/Common/Exe/dw3000_api.hex`.
- **Always `make clean` first when the emProject or its defines changed** — stale objects caused the M2a.1 HardFault.
- **Flash from macOS host**, SoftDevice **first**, both hex files, absolute paths. Board stops advertising if you flash the app alone.
- **Power-cycle before trusting an RTT read** (stale RAM latches ghost output).
- All new `.c` files MUST be added to `dw3000_api.emProject` or they will not compile.
- **Name collision warning:** ARM CoreSight `DWT->CYCCNT` (from `core_cm4.h`) is unrelated to the Qorvo `dwt_*` driver functions. Both appear in this plan.
- `main.c:87` already calls `dw_irq_init()` in every build, so the GPIOTE pin is configured before any example runs. Do not call it again.

## File Structure

| File | Responsibility |
|---|---|
| `Src/uwb/ranging.h` | Two-function public interface; no `dwt_*` types leak out |
| `Src/uwb/ranging.c` | All DW3000 setup, responder ISR, initiator exchange, sanity checks |
| `Src/ble/sensor_stream.c` | Modified: every-5th-tick ranging call, real `uwb_mm` in packet |
| `dw3000_api.emProject` | Modified: register the new sources |

---

### Task 1: Ranging module skeleton + responder ISR + deadline margin measurement

This is the **de-risking task**. It builds the responder's interrupt path but does *not* send a reply yet — it only measures how much of the 650 µs budget is left at the moment the reply would be armed. If the margin is negative or thin, `POLL_RX_TO_RESP_TX_DLY_UUS` must be raised on both roles before any further work.

**Files:**
- Create: `firmware/DWM3001C-starter-firmware/Src/uwb/ranging.h`
- Create: `firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c`
- Modify: `firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c`
- Modify: `firmware/DWM3001C-starter-firmware/dw3000_api.emProject`

**Interfaces:**
- Consumes: `test_run_info(unsigned char*)` from `main.c`; platform `port_set_dw_ic_spi_fastrate()`, `reset_DWIC()`, `port_set_dwic_isr()`, `port_EnableEXT_IRQ()`; driver `dwt_*`.
- Produces: `bool ranging_init(void)`, `bool ranging_exchange(uint32_t *out_mm)` in `ranging.h`. Task 2 completes the responder reply; Task 3 implements `ranging_exchange`.

**How the margin is measured (read before implementing).** We do not need a stopwatch. The DW3000 timestamps the poll's arrival in device time, and the reply must depart at `poll_rx_ts + 650 uus`. Reading the chip's *current* system time just before arming gives the remaining margin directly, in the same clock domain — no host-clock error:

```
margin_ticks = resp_tx_time - dwt_readsystimestamphi32()
margin_us    = margin_ticks * 4.0064 / 1000      /* hi32 tick = 256 * 15.65 ps */
```

A positive margin means the deadline was met with that much to spare. This is more trustworthy than `DWT->CYCCNT` because it measures the quantity that actually matters.

- [ ] **Step 1: Create `Src/uwb/ranging.h`**

```c
#ifndef RANGING_H_
#define RANGING_H_

#include <stdint.h>
#include <stdbool.h>

/* Configure the DW3000 for the role compiled in (SENSOR_ROLE_INITIATOR).
 * The responder additionally arms IRQ-driven poll answering.
 * Returns false on any init failure (details printed over RTT). */
bool ranging_init(void);

/* Initiator only: run one bounded SS-TWR exchange.
 * Returns true and writes *out_mm on success; false on timeout, bad frame,
 * or a result failing the sanity check. Blocks for at most a few ms.
 * On the responder this always returns false. */
bool ranging_exchange(uint32_t *out_mm);

#endif /* RANGING_H_ */
```

- [ ] **Step 2: Create `Src/uwb/ranging.c` (responder ISR + margin measurement only)**

```c
/* M2b.1: SS-TWR ranging alongside the BLE sensor stream.
 * Responder answers polls from the DW3000 IRQ (hard ~650 us deadline);
 * initiator runs a bounded blocking exchange. See
 * docs/superpowers/specs/2026-07-19-m2b1-uwb-in-stream-design.md */

#include "example_selection.h"

#if defined(TEST_SENSOR_STREAM)

#include <string.h>
#include <stdio.h>
#include "deca_device_api.h"
#include "deca_probe_interface.h"
#include "port.h"
#include "deca_spi.h"
#include "shared_defines.h"    /* UUS_TO_DWT_TIME */
#include "shared_functions.h"  /* get_rx_timestamp_u64, waitforsysstatus */
#include "ranging.h"

extern void test_run_info(unsigned char *data);
extern dwt_txconfig_t txconfig_options;

/* Same radio config as the stock SS-TWR examples (ex_06a/ex_06b). */
static dwt_config_t config = {
    5, DWT_PLEN_128, DWT_PAC8, 9, 9, 1, DWT_BR_6M8,
    DWT_PHRMODE_STD, DWT_PHRRATE_STD, (129 + 8 - 8),
    DWT_STS_MODE_OFF, DWT_STS_LEN_64, DWT_PDOA_M0
};

#define TX_ANT_DLY 16385
#define RX_ANT_DLY 16385

#define POLL_RX_TO_RESP_TX_DLY_UUS 650   /* responder turnaround, both roles must agree */
#define ALL_MSG_COMMON_LEN 10
#define ALL_MSG_SN_IDX      2
#define RX_BUF_LEN         24

/* One DW3000 hi32 system-time tick = 256 * 15.65 ps ~= 4.0064 ns. */
#define HI32_TICK_NS 4.0064f

static const uint8_t rx_poll_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'W', 'A', 'V', 'E', 0xE0, 0, 0 };
static uint8_t rx_buffer[RX_BUF_LEN];

static volatile int32_t  m_worst_margin_ticks = INT32_MAX;
static volatile uint32_t m_poll_count         = 0;

static void dbg(const char *name, uint32_t v)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "  %s -> %lu", name, (unsigned long)v);
    test_run_info((unsigned char *)buf);
}

/* ---- Responder RX callback (runs at GPIOTE priority 6) ---- */
static void rx_ok_cb(const dwt_cb_data_t *cb_data)
{
    if (cb_data->datalength > RX_BUF_LEN) { dwt_rxenable(DWT_START_RX_IMMEDIATE); return; }

    dwt_readrxdata(rx_buffer, cb_data->datalength, 0);
    rx_buffer[ALL_MSG_SN_IDX] = 0;
    if (memcmp(rx_buffer, rx_poll_msg, ALL_MSG_COMMON_LEN) != 0)
    {
        dwt_rxenable(DWT_START_RX_IMMEDIATE);
        return;
    }

    /* Deadline arithmetic, exactly as the reply path will do it in Task 2. */
    uint64_t poll_rx_ts  = get_rx_timestamp_u64();
    uint32_t resp_tx_time = (uint32_t)((poll_rx_ts + (POLL_RX_TO_RESP_TX_DLY_UUS * UUS_TO_DWT_TIME)) >> 8);

    /* MEASUREMENT: how much of the budget is left right now? */
    int32_t margin = (int32_t)(resp_tx_time - dwt_readsystimestamphi32());
    if (margin < m_worst_margin_ticks) { m_worst_margin_ticks = margin; }
    m_poll_count++;

    dwt_rxenable(DWT_START_RX_IMMEDIATE);
}

static void rx_fail_cb(const dwt_cb_data_t *cb_data)
{
    (void)cb_data;
    dwt_rxenable(DWT_START_RX_IMMEDIATE);
}

/* Print the worst margin seen so far. Called from thread mode. */
void ranging_report_margin(void)
{
    int32_t ticks = m_worst_margin_ticks;
    char buf[80];
    if (ticks == INT32_MAX)
    {
        snprintf(buf, sizeof(buf), "RANGE: no polls seen yet");
    }
    else
    {
        int32_t margin_ns = (int32_t)(ticks * HI32_TICK_NS);
        snprintf(buf, sizeof(buf), "RANGE: polls=%lu worst margin=%ld us (%ld ns)",
                 (unsigned long)m_poll_count, (long)(margin_ns / 1000), (long)margin_ns);
    }
    test_run_info((unsigned char *)buf);
}

static bool dw_common_init(void)
{
    port_set_dw_ic_spi_fastrate();
    reset_DWIC();
    Sleep(2);

    if (dwt_probe((struct dwt_probe_s *)&dw3000_probe_interf) != DWT_SUCCESS)
    {
        test_run_info((unsigned char *)"RANGE: probe FAILED"); return false;
    }
    while (!dwt_checkidlerc()) { }
    if (dwt_initialise(DWT_DW_INIT) == DWT_ERROR)
    {
        test_run_info((unsigned char *)"RANGE: init FAILED"); return false;
    }
    if (dwt_configure(&config))
    {
        test_run_info((unsigned char *)"RANGE: config FAILED"); return false;
    }
    dwt_configuretxrf(&txconfig_options);
    dwt_setrxantennadelay(RX_ANT_DLY);
    dwt_settxantennadelay(TX_ANT_DLY);
    dwt_setlnapamode(DWT_LNA_ENABLE | DWT_PA_ENABLE);
    return true;
}

bool ranging_init(void)
{
    if (!dw_common_init()) return false;

#if defined(SENSOR_ROLE_INITIATOR)
    test_run_info((unsigned char *)"RANGE: initiator ready");
#else
    /* dw_irq_init() already ran in main(); we only attach the ISR and enable it. */
    port_set_dwic_isr(dwt_isr);
    dwt_setcallbacks(NULL, rx_ok_cb, rx_fail_cb, rx_fail_cb, NULL, NULL, NULL);
    dwt_setinterrupt(DWT_INT_RXFCG_BIT_MASK | DWT_INT_ARFE_BIT_MASK | DWT_INT_RXFSL_BIT_MASK
                     | DWT_INT_RXSTO_BIT_MASK | DWT_INT_RXPHE_BIT_MASK | DWT_INT_RXFCE_BIT_MASK,
                     0, DWT_ENABLE_INT);
    port_EnableEXT_IRQ();
    dwt_rxenable(DWT_START_RX_IMMEDIATE);
    test_run_info((unsigned char *)"RANGE: responder listening (IRQ)");
#endif
    return true;
}

bool ranging_exchange(uint32_t *out_mm)
{
    (void)out_mm;
    return false;   /* implemented in Task 3 */
}

#endif /* TEST_SENSOR_STREAM */
```

- [ ] **Step 3: Call `ranging_init()` and report margin from `sensor_stream.c`**

Add the include near the existing ones:

```c
#include "uwb/ranging.h"
```

Declare the reporter above `sensor_stream()`:

```c
extern void ranging_report_margin(void);
```

After the existing `sensor_ble_init()` failure block, add:

```c
    if (!ranging_init())
    {
        test_run_info((unsigned char *)"SENSOR: ranging_init FAILED");
        for (;;) { }
    }
```

Inside the `for (;;)` loop, in the `if (m_sample_due)` body, after `sensor_ble_notify(pkt);` add a once-per-second margin report:

```c
            if ((m_seq % 100) == 0) { ranging_report_margin(); }
```

- [ ] **Step 4: Register the new sources in `dw3000_api.emProject`**

Add a `uwb` folder alongside the existing `ble` folder block:

```xml
      <folder Name="uwb">
        <file file_name="Src/uwb/ranging.h" />
        <file file_name="Src/uwb/ranging.c" />
      </folder>
```

- [ ] **Step 5: Clean build**

Run: `cd firmware/DWM3001C-starter-firmware && DOCKER_DEFAULT_PLATFORM=linux/amd64 make clean && DOCKER_DEFAULT_PLATFORM=linux/amd64 make build`
Expected: `ls -la Output/Common/Exe/dw3000_api.hex` shows a fresh timestamp. Build output is noisy; confirm the hex file, not the log tail.

- [ ] **Step 6: Flash the responder board**

Comment out `#define SENSOR_ROLE_INITIATOR` in `Src/example_selection.h`, then `make clean && make build`, and confirm the role took:

Run: `strings Output/Common/Exe/dw3000_api.elf | grep -E '^DWM-(INIT|RESP)$'`
Expected: `DWM-RESP`

Flash (from `firmware/`, SoftDevice first):
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
Expected: two `Program & Verify` `O.K.` lines.

- [ ] **Step 7: Flash the *other* board with the stock SS-TWR initiator as a poll source**

The responder needs someone to poll it. Use the stock example rather than our firmware — it needs no SoftDevice and polls once per second.

In `Src/example_selection.h` comment out `TEST_SENSOR_STREAM` and uncomment `#define TEST_SS_TWR_INITIATOR`, then `make clean && make build`, and flash **the second board** (app only, no SoftDevice needed):
```bash
JLinkExe -SelectEmuBySN <second-board-serial> -CommanderScript /dev/stdin <<'EOF'
si SWD
speed 4000
device NRF52833_XXAA
connect
erase
loadfile DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex
r
g
q
EOF
```
Then restore `example_selection.h` to `TEST_SENSOR_STREAM` with `SENSOR_ROLE_INITIATOR` commented out.

- [ ] **Step 8: Connect the phone, then read the margin over RTT**

The measurement must be taken **with BLE connected**, because SoftDevice radio activity is the dominant term. In nRF Connect, connect to `DWM-RESP` and enable notifications on `6E40FE01-…`.

Then, on the responder board:
```bash
JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 /tmp/margin.log &
sleep 60; pkill -f JLinkRTTLogger
strings /tmp/margin.log | grep RANGE
```
Expected: lines like `RANGE: polls=57 worst margin=412 us (412000 ns)`.

- [ ] **Step 9: Record the result on draw.io page 4 and decide**

Fill the worksheet's total row with the worst margin observed.

- **Margin comfortably positive (> ~150 µs):** proceed to Task 2 unchanged.
- **Margin thin or negative:** raise `POLL_RX_TO_RESP_TX_DLY_UUS` in `ranging.c` **and** in the initiator's matching constant (Task 3) — they must agree — then repeat Steps 5–8. Record the new value and why in the architecture decision log.
- **`polls=0`:** the responder never saw a poll. Check the second board is powered and running the stock initiator, and that both use channel 5.

- [ ] **Step 10: Commit**

```bash
git add firmware/DWM3001C-starter-firmware/Src/uwb/ranging.h \
        firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c \
        firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c \
        firmware/DWM3001C-starter-firmware/dw3000_api.emProject \
        docs/architecture.drawio
git commit -m "feat(fw): M2b.1 ranging skeleton + measured responder deadline margin"
```

---

### Task 2: Responder sends the reply

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c`

**Interfaces:**
- Consumes: `rx_ok_cb`, `config`, antenna delays, `POLL_RX_TO_RESP_TX_DLY_UUS` from Task 1.
- Produces: a responder that completes SS-TWR exchanges. Task 3's initiator depends on the reply frame layout below.

- [ ] **Step 1: Add the reply frame and timestamp helper near the top of `ranging.c`**

Place directly after the `rx_poll_msg` declaration:

```c
static uint8_t tx_resp_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'V', 'E', 'W', 'A', 0xE1,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
#define RESP_MSG_POLL_RX_TS_IDX 10
#define RESP_MSG_RESP_TX_TS_IDX 14
#define RESP_MSG_TS_LEN          4

static uint8_t frame_seq_nb = 0;

static void resp_msg_set_ts(uint8_t *ts_field, uint64_t ts)
{
    for (int i = 0; i < RESP_MSG_TS_LEN; i++) { ts_field[i] = (uint8_t)(ts >> (i * 8)); }
}

static void resp_msg_get_ts(const uint8_t *ts_field, uint32_t *ts)
{
    *ts = 0;
    for (int i = 0; i < RESP_MSG_TS_LEN; i++) { *ts += ((uint32_t)ts_field[i]) << (i * 8); }
}
```

- [ ] **Step 2: Replace the measurement-only tail of `rx_ok_cb` with the reply**

Replace everything in `rx_ok_cb` from the `/* MEASUREMENT ... */` comment to the end of the function with:

```c
    /* Keep the margin measurement — it stays useful for regression checking. */
    int32_t margin = (int32_t)(resp_tx_time - dwt_readsystimestamphi32());
    if (margin < m_worst_margin_ticks) { m_worst_margin_ticks = margin; }
    m_poll_count++;

    dwt_setdelayedtrxtime(resp_tx_time);

    uint64_t resp_tx_ts = (((uint64_t)(resp_tx_time & 0xFFFFFFFEUL)) << 8) + TX_ANT_DLY;
    resp_msg_set_ts(&tx_resp_msg[RESP_MSG_POLL_RX_TS_IDX], poll_rx_ts);
    resp_msg_set_ts(&tx_resp_msg[RESP_MSG_RESP_TX_TS_IDX], resp_tx_ts);

    tx_resp_msg[ALL_MSG_SN_IDX] = frame_seq_nb++;
    dwt_writetxdata(sizeof(tx_resp_msg), tx_resp_msg, 0);
    dwt_writetxfctrl(sizeof(tx_resp_msg), 0, 1);

    if (dwt_starttx(DWT_START_TX_DELAYED | DWT_RESPONSE_EXPECTED) != DWT_SUCCESS)
    {
        /* Deadline missed — abandon this exchange, listen again. */
        m_late_count++;
        dwt_rxenable(DWT_START_RX_IMMEDIATE);
    }
```

Note: on success the DW3000 re-enables RX itself because of `DWT_RESPONSE_EXPECTED`, so do **not** call `dwt_rxenable()` on that path.

- [ ] **Step 3: Add the late counter**

Next to `m_poll_count`:

```c
static volatile uint32_t m_late_count = 0;
```

And extend the report in `ranging_report_margin()` — replace the `snprintf` in the `else` branch with:

```c
        snprintf(buf, sizeof(buf), "RANGE: polls=%lu late=%lu worst margin=%ld us",
                 (unsigned long)m_poll_count, (unsigned long)m_late_count,
                 (long)((int32_t)(ticks * HI32_TICK_NS) / 1000));
```

- [ ] **Step 4: Build and flash the responder**

`example_selection.h`: `TEST_SENSOR_STREAM` defined, `SENSOR_ROLE_INITIATOR` commented out.
Run: `DOCKER_DEFAULT_PLATFORM=linux/amd64 make clean && DOCKER_DEFAULT_PLATFORM=linux/amd64 make build`
Then flash SoftDevice + app to the responder board (Task 1 Step 6 command).

- [ ] **Step 5: Verify exchanges now complete**

Leave the stock SS-TWR initiator running on the second board. On the Mac, read that board's RTT:
```bash
JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 /tmp/init.log &
sleep 20; pkill -f JLinkRTTLogger
strings /tmp/init.log | grep DIST
```
Expected: `DIST: 0.xx m` lines — the stock initiator only prints these when it receives a valid reply, so this proves our IRQ-driven responder works.
Also check the responder's own log shows `late=0` or a very small count.

- [ ] **Step 6: Commit**

```bash
git add firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c
git commit -m "feat(fw): IRQ-driven SS-TWR responder alongside BLE stream (M2b.1)"
```

---

### Task 3: Initiator exchange + real `uwb_mm` in the packet

**Files:**
- Modify: `firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c`
- Modify: `firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c`

**Interfaces:**
- Consumes: `ranging_init()` from Task 1; the reply frame layout from Task 2.
- Produces: a working `bool ranging_exchange(uint32_t *out_mm)`; `sensor_stream.c` emits real `uwb_mm` every fifth tick.

- [ ] **Step 1: Add initiator constants and the poll frame to `ranging.c`**

Place next to the responder's frame definitions:

```c
static uint8_t tx_poll_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'W', 'A', 'V', 'E', 0xE0, 0, 0 };
static const uint8_t rx_resp_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'V', 'E', 'W', 'A', 0xE1,
                                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

#define POLL_TX_TO_RESP_RX_DLY_UUS 240
#define RESP_RX_TIMEOUT_UUS        400
#define SPEED_OF_LIGHT             299702547.0f   /* m/s in air */
#define RANGE_MAX_MM               50000u         /* sanity ceiling, see spec §3 */
```

- [ ] **Step 2: Configure the initiator's RX window in `ranging_init()`**

Inside the `#if defined(SENSOR_ROLE_INITIATOR)` branch, **before** the `test_run_info` line:

```c
    dwt_setrxaftertxdelay(POLL_TX_TO_RESP_RX_DLY_UUS);
    dwt_setrxtimeout(RESP_RX_TIMEOUT_UUS);
```

- [ ] **Step 3: Implement `ranging_exchange()`**

Replace the Task 1 stub entirely:

```c
bool ranging_exchange(uint32_t *out_mm)
{
#if !defined(SENSOR_ROLE_INITIATOR)
    (void)out_mm;
    return false;
#else
    tx_poll_msg[ALL_MSG_SN_IDX] = frame_seq_nb;
    dwt_writesysstatuslo(DWT_INT_TXFRS_BIT_MASK);
    dwt_writetxdata(sizeof(tx_poll_msg), tx_poll_msg, 0);
    dwt_writetxfctrl(sizeof(tx_poll_msg), 0, 1);
    dwt_starttx(DWT_START_TX_IMMEDIATE | DWT_RESPONSE_EXPECTED);

    uint32_t status_reg = 0;
    waitforsysstatus(&status_reg, NULL,
                     (DWT_INT_RXFCG_BIT_MASK | SYS_STATUS_ALL_RX_TO | SYS_STATUS_ALL_RX_ERR), 0);
    frame_seq_nb++;

    if (!(status_reg & DWT_INT_RXFCG_BIT_MASK))
    {
        dwt_writesysstatuslo(SYS_STATUS_ALL_RX_TO | SYS_STATUS_ALL_RX_ERR);
        return false;                      /* timeout or error -> sentinel */
    }

    dwt_writesysstatuslo(DWT_INT_RXFCG_BIT_MASK);

    uint16_t frame_len = dwt_getframelength();
    if (frame_len > RX_BUF_LEN) return false;
    dwt_readrxdata(rx_buffer, frame_len, 0);

    rx_buffer[ALL_MSG_SN_IDX] = 0;
    if (memcmp(rx_buffer, rx_resp_msg, ALL_MSG_COMMON_LEN) != 0) return false;

    uint32_t poll_tx_ts = dwt_readtxtimestamplo32();
    uint32_t resp_rx_ts = dwt_readrxtimestamplo32();
    float clockOffsetRatio = ((float)dwt_readclockoffset()) / (uint32_t)(1 << 26);

    uint32_t poll_rx_ts, resp_tx_ts;
    resp_msg_get_ts(&rx_buffer[RESP_MSG_POLL_RX_TS_IDX], &poll_rx_ts);
    resp_msg_get_ts(&rx_buffer[RESP_MSG_RESP_TX_TS_IDX], &resp_tx_ts);

    int32_t rtd_init = resp_rx_ts - poll_tx_ts;
    int32_t rtd_resp = resp_tx_ts - poll_rx_ts;

    float tof      = ((rtd_init - rtd_resp * (1.0f - clockOffsetRatio)) / 2.0f) * DWT_TIME_UNITS;
    float distance = tof * SPEED_OF_LIGHT;

    /* Sanity check (spec §3). Rejects nonsense; does NOT catch NLOS bias. */
    if (distance < 0.0f) return false;
    float mm = distance * 1000.0f;
    if (mm > (float)RANGE_MAX_MM) return false;

    *out_mm = (uint32_t)mm;
    return true;
#endif
}
```

- [ ] **Step 4: Use it in `sensor_stream.c`**

Add a tick counter next to `m_seq`:

```c
static uint32_t m_tick = 0;
```

Replace the packet-building block inside `if (m_sample_due)` — the lines from `uint8_t pkt[16];` through `sensor_ble_notify(pkt);` — with:

```c
            uint32_t uwb_mm = SENSOR_UWB_SENTINEL;
            if ((++m_tick % 5) == 0)          /* 50 ms -> 20 Hz */
            {
                uint32_t mm;
                if (ranging_exchange(&mm))
                {
                    uwb_mm = mm;
                    char dbuf[40];
                    snprintf(dbuf, sizeof(dbuf), "DIST: %lu mm", (unsigned long)mm);
                    test_run_info((unsigned char *)dbuf);
                }
            }

            uint8_t pkt[16];
            pack_le16(&pkt[0],  m_seq++);
            pack_le32(&pkt[2],  m_board_time_ms);
            pack_le16(&pkt[6],  (uint16_t)x);
            pack_le16(&pkt[8],  (uint16_t)y);
            pack_le16(&pkt[10], (uint16_t)z);
            pack_le32(&pkt[12], uwb_mm);
            sensor_ble_notify(pkt);
```

Add `#include <stdio.h>` to the includes if not already present.

- [ ] **Step 5: Build and flash both boards with our firmware**

Initiator board: `example_selection.h` with `TEST_SENSOR_STREAM` **and** `SENSOR_ROLE_INITIATOR` defined → `make clean && make build` → verify `strings ... | grep '^DWM-INIT$'` → flash SoftDevice + app.

Responder board: comment out `SENSOR_ROLE_INITIATOR` → `make clean && make build` → verify `DWM-RESP` → flash SoftDevice + app to the second board (`-SelectEmuBySN`).

- [ ] **Step 6: Confirm distance over RTT**

Power-cycle the initiator, then:
```bash
JLinkRTTLogger -Device NRF52833_XXAA -if SWD -Speed 4000 -RTTChannel 0 /tmp/dist.log &
sleep 20; pkill -f JLinkRTTLogger
strings /tmp/dist.log | grep DIST | head -20
```
Expected: `DIST: <n> mm` lines at roughly 20 per second, values plausible for the boards' separation.

- [ ] **Step 7: Commit**

```bash
git add firmware/DWM3001C-starter-firmware/Src/uwb/ranging.c \
        firmware/DWM3001C-starter-firmware/Src/ble/sensor_stream.c
git commit -m "feat(fw): initiator SS-TWR exchange, real uwb_mm in stream (M2b.1)"
```

---

### Task 4: Bench verification and milestone close-out

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/architecture.drawio` (page 4 worksheet)
- Create: `firmware/hex/m2b1_init.hex`, `firmware/hex/m2b1_resp.hex`

**Interfaces:**
- Consumes: working firmware from Task 3.
- Produces: verified milestone, stashed images, updated roadmap.

- [ ] **Step 1: Scale test — the criterion that must pass**

Place the two boards at a tape-measured **1.0 m**, capture 20 s of RTT, and compute the mean of the `DIST:` values. Repeat at **2.0 m**.

```bash
strings /tmp/dist.log | grep -o 'DIST: [0-9]*' | awk '{s+=$2; n++} END {print "mean_mm:", s/n, "n:", n}'
```

Expected: `mean(2.0 m) − mean(1.0 m)` = 1000 mm ± 100 mm.

**This is the pass/fail criterion.** It proves the time-of-flight maths and the fixed-turnaround assumption.

- [ ] **Step 2: Record the absolute offset — do NOT fail on it**

Note `mean(1.0 m) − 1000 mm`. Any offset common to both distances is uncalibrated antenna delay (stock `16385`), deliberately deferred to M4 (spec §7). Record the figure; do not treat it as a defect.

- [ ] **Step 3: Confirm stability and rate**

From the same 1.0 m capture: the spread of values should be a few cm, not metres, and the count over 20 s should be roughly 400 (20 Hz), allowing for exchanges lost to SoftDevice preemption.

- [ ] **Step 4: Confirm the phone still sees everything**

In nRF Connect, connected to **both** tags with notifications enabled:
- `DWM-INIT` bytes 12–15 alternate between real little-endian values and `FF FF FF FF`
- `DWM-RESP` bytes 12–15 are always `FF FF FF FF`
- accel bytes (offsets 6–11) change on both tags when moved
- notifications keep arriving at ~100 Hz on both

- [ ] **Step 5: Stash working images**

```bash
cd firmware
cp DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex hex/m2b1_init.hex   # after an initiator build
# rebuild as responder, then:
cp DWM3001C-starter-firmware/Output/Common/Exe/dw3000_api.hex hex/m2b1_resp.hex
```
Leave `example_selection.h` with `SENSOR_ROLE_INITIATOR` **defined** as the committed default.

- [ ] **Step 6: Update the roadmap and decision log**

In `docs/architecture.md` §6, set M2b.1 to `✅ verified` and M2b.2 to `⬜ **next**`. Add a decision-log entry recording: the measured worst-case deadline margin, the measured absolute offset at 1.0 m, the observed measurement rate, and whether `POLL_RX_TO_RESP_TX_DLY_UUS` had to change.

Also fill the totals row on draw.io page 4 with the measured margin.

- [ ] **Step 7: Commit**

```bash
git add docs/architecture.md docs/architecture.drawio \
        firmware/hex/m2b1_init.hex firmware/hex/m2b1_resp.hex \
        firmware/DWM3001C-starter-firmware/Src/example_selection.h
git commit -m "chore(fw): M2b.1 verified — stash images, record measured margin and offset"
```

---

## Self-Review

**Spec coverage:**
- Real `uwb_mm` at 20 Hz, sentinel otherwise → Task 3 Steps 3–4. ✅
- Sanity check, reject < 0 or > 50 m → Task 3 Step 3 (`RANGE_MAX_MM`). ✅
- Responder IRQ-driven, meets 650 µs → Tasks 1–2. ✅
- Initiator bounded blocking, every fifth tick → Task 3 Steps 2–4. ✅
- Module boundary `ranging.{h,c}`, no `dwt_*` in `sensor_stream.c` → Task 1 Steps 1–2. ✅
- Latency budget measured **before** ranging logic → Task 1 is first and gates Task 2. ✅
- Escape hatch if budget fails → Task 1 Step 9. ✅
- Verification by RTT (numbers) + nRF Connect (transport) → Task 4 Steps 1–4. ✅
- Success = scale, not absolute accuracy; offset recorded → Task 4 Steps 1–2. ✅
- Contract unchanged, no iOS work → no iOS task exists. ✅
- NLOS explicitly out of scope → not implemented; noted in Task 3 Step 3 comment. ✅

**Placeholder scan:** No TBD/TODO. Every code step contains complete code. The only intentional stub (`ranging_exchange` in Task 1) is replaced wholesale in Task 3. ✅

**Type consistency:** `ranging_init()`/`ranging_exchange(uint32_t*)` identical across `ranging.h`, `ranging.c`, and the `sensor_stream.c` call site. `POLL_RX_TO_RESP_TX_DLY_UUS` is defined once in `ranging.c` and used by both roles. `frame_seq_nb`, `rx_buffer`, `RX_BUF_LEN`, `ALL_MSG_SN_IDX`, `ALL_MSG_COMMON_LEN`, and `resp_msg_get_ts`/`resp_msg_set_ts` are declared in Task 1/2 before Task 3 uses them. Packet stays 16 bytes throughout. ✅

**Known risk not eliminated by this plan:** if Task 1 shows a negative margin, Task 2 onward is blocked until `POLL_RX_TO_RESP_TX_DLY_UUS` is raised on both roles. That is the intended purpose of sequencing Task 1 first.

/* M2b.1: SS-TWR ranging alongside the BLE sensor stream.
 * Responder answers polls from the DW3000 IRQ (hard ~667 us deadline);
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
    5,                /* Channel number. */
    DWT_PLEN_128,     /* Preamble length. Used in TX only. */
    DWT_PAC8,         /* Preamble acquisition chunk size. Used in RX only. */
    9,                /* TX preamble code. Used in TX only. */
    9,                /* RX preamble code. Used in RX only. */
    1,                /* Non-standard 8 symbol SFD. */
    DWT_BR_6M8,       /* Data rate. */
    DWT_PHRMODE_STD,  /* PHY header mode. */
    DWT_PHRRATE_STD,  /* PHY header rate. */
    (129 + 8 - 8),    /* SFD timeout. */
    DWT_STS_MODE_OFF, /* STS disabled. */
    DWT_STS_LEN_64,   /* STS length. */
    DWT_PDOA_M0       /* PDOA mode off. */
};

#define TX_ANT_DLY 16385
#define RX_ANT_DLY 16385

/* Responder turnaround. BOTH roles must agree on this value.
 * NOTE on units: despite the _UUS suffix (inherited from the Qorvo examples),
 * UUS_TO_DWT_TIME is 63898 = 499.2 * 128, i.e. device-time units per PLAIN
 * microsecond (shared_defines.h:37). So this is a 650 us deadline, not 667 us. */
#define POLL_RX_TO_RESP_TX_DLY_UUS 650

#define ALL_MSG_COMMON_LEN 10
#define ALL_MSG_SN_IDX      2
#define RX_BUF_LEN         24

/* One DW3000 hi32 system-time tick = 256 * 15.65 ps ~= 4.0064 ns. */
#define HI32_TICK_NS 4.0064f

static const uint8_t rx_poll_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'W', 'A', 'V', 'E', 0xE0, 0, 0 };
static uint8_t rx_buffer[RX_BUF_LEN];

/* Reply frame. Layout must match what the initiator expects (ex_06a). */
static uint8_t tx_resp_msg[] = { 0x41, 0x88, 0, 0xCA, 0xDE, 'V', 'E', 'W', 'A', 0xE1,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
#define RESP_MSG_POLL_RX_TS_IDX 10
#define RESP_MSG_RESP_TX_TS_IDX 14
#define RESP_MSG_TS_LEN          4

static uint8_t frame_seq_nb = 0;

/* resp_msg_set_ts() / resp_msg_get_ts() come from shared_functions.h — do not
 * redefine them here. */

static volatile int32_t  m_worst_margin_ticks = INT32_MAX;
static volatile uint32_t m_poll_count         = 0;
static volatile uint32_t m_late_count         = 0;

/* ---- Responder RX callback (runs at GPIOTE priority 6) ---- */
static void rx_ok_cb(const dwt_cb_data_t *cb_data)
{
    if (cb_data->datalength > RX_BUF_LEN)
    {
        dwt_rxenable(DWT_START_RX_IMMEDIATE);
        return;
    }

    dwt_readrxdata(rx_buffer, cb_data->datalength, 0);
    rx_buffer[ALL_MSG_SN_IDX] = 0;
    if (memcmp(rx_buffer, rx_poll_msg, ALL_MSG_COMMON_LEN) != 0)
    {
        dwt_rxenable(DWT_START_RX_IMMEDIATE);
        return;
    }

    /* Deadline arithmetic, exactly as the reply path will do it in Task 2. */
    uint64_t poll_rx_ts   = get_rx_timestamp_u64();
    uint32_t resp_tx_time = (uint32_t)((poll_rx_ts + (POLL_RX_TO_RESP_TX_DLY_UUS * UUS_TO_DWT_TIME)) >> 8);

    /* MEASUREMENT: how much of the budget is left right now? Kept from Task 1 —
     * it remains useful as a regression check once the reply is live. */
    int32_t margin = (int32_t)(resp_tx_time - dwt_readsystimestamphi32());
    if (margin < m_worst_margin_ticks) { m_worst_margin_ticks = margin; }
    m_poll_count++;

    /* Arm the reply for the agreed instant. */
    dwt_setdelayedtrxtime(resp_tx_time);

    uint64_t resp_tx_ts = (((uint64_t)(resp_tx_time & 0xFFFFFFFEUL)) << 8) + TX_ANT_DLY;
    resp_msg_set_ts(&tx_resp_msg[RESP_MSG_POLL_RX_TS_IDX], poll_rx_ts);
    resp_msg_set_ts(&tx_resp_msg[RESP_MSG_RESP_TX_TS_IDX], resp_tx_ts);

    tx_resp_msg[ALL_MSG_SN_IDX] = frame_seq_nb++;
    dwt_writetxdata(sizeof(tx_resp_msg), tx_resp_msg, 0);
    dwt_writetxfctrl(sizeof(tx_resp_msg), 0, 1);

    /* DWT_RESPONSE_EXPECTED re-enables RX automatically once the reply is sent,
     * so the success path must NOT call dwt_rxenable() itself. */
    if (dwt_starttx(DWT_START_TX_DELAYED | DWT_RESPONSE_EXPECTED) != DWT_SUCCESS)
    {
        /* Deadline missed: the armed time is already past. Abandon this
         * exchange (the initiator will time out) and listen again. */
        m_late_count++;
        dwt_rxenable(DWT_START_RX_IMMEDIATE);
    }
}

static void rx_fail_cb(const dwt_cb_data_t *cb_data)
{
    (void)cb_data;
    dwt_rxenable(DWT_START_RX_IMMEDIATE);
}

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
        snprintf(buf, sizeof(buf), "RANGE: polls=%lu late=%lu worst margin=%ld us",
                 (unsigned long)m_poll_count, (unsigned long)m_late_count,
                 (long)(margin_ns / 1000));
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
        test_run_info((unsigned char *)"RANGE: probe FAILED");
        return false;
    }
    while (!dwt_checkidlerc()) { }

    if (dwt_initialise(DWT_DW_INIT) == DWT_ERROR)
    {
        test_run_info((unsigned char *)"RANGE: init FAILED");
        return false;
    }
    if (dwt_configure(&config))
    {
        test_run_info((unsigned char *)"RANGE: config FAILED");
        return false;
    }

    dwt_configuretxrf(&txconfig_options);
    dwt_setrxantennadelay(RX_ANT_DLY);
    dwt_settxantennadelay(TX_ANT_DLY);
    dwt_setlnapamode(DWT_LNA_ENABLE | DWT_PA_ENABLE);
    return true;
}

bool ranging_init(void)
{
    if (!dw_common_init()) { return false; }

#if defined(SENSOR_ROLE_INITIATOR)
    test_run_info((unsigned char *)"RANGE: initiator ready");
#else
    /* dw_irq_init() already ran in main(); we only attach the ISR and enable it. */
    port_set_dwic_isr(dwt_isr);
    dwt_setcallbacks(NULL, rx_ok_cb, rx_fail_cb, rx_fail_cb, NULL, NULL, NULL);
    dwt_setinterrupt(DWT_INT_RXFCG_BIT_MASK | DWT_INT_ARFE_BIT_MASK | DWT_INT_RXFSL_BIT_MASK
                     | DWT_INT_RXSTO_BIT_MASK | DWT_INT_RXPHE_BIT_MASK | DWT_INT_RXFCE_BIT_MASK,
                     0, DWT_ENABLE_INT);
    /* The reply uses DWT_RESPONSE_EXPECTED to re-arm RX automatically; make the
     * post-TX RX window explicit — no delay, no timeout, i.e. listen forever. */
    dwt_setrxaftertxdelay(0);
    dwt_setrxtimeout(0);

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

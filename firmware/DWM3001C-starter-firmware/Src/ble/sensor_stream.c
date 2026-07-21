/* Milestone 2a.2 entry point: sample the accelerometer at 100 Hz and stream the
 * 16-byte packet over BLE (uwb_mm = sentinel; live distance is M2b). */

#include "example_selection.h"

#if defined(TEST_SENSOR_STREAM)

#include <stdint.h>
#include <stdio.h>
#include "app_timer.h"
#include "app_error.h"
#include "nrf_soc.h"
#include "accel/accel.h"
#include "sensor_ble.h"
#include "uwb/ranging.h"

extern void test_run_info(unsigned char *data);

#define SENSOR_UWB_SENTINEL  0xFFFFFFFFu
#define SAMPLE_PERIOD_MS     10   /* 100 Hz */

APP_TIMER_DEF(m_sample_timer);
static volatile bool     m_sample_due    = false;
static volatile uint32_t m_board_time_ms = 0;
static uint16_t          m_seq           = 0;
static uint32_t          m_tick          = 0;

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
    if (!ranging_init())
    {
        test_run_info((unsigned char *)"SENSOR: ranging_init FAILED");
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

            /* Range on every 5th tick (50 ms -> 20 Hz). A real value goes only
             * into the packet carrying a just-succeeded exchange; every other
             * packet carries the sentinel (see firmware/ble-contract.md). */
            uint32_t uwb_mm = SENSOR_UWB_SENTINEL;
            if ((++m_tick % 5) == 0)
            {
                uint32_t mm;
                if (ranging_exchange(&mm))
                {
                    uwb_mm = mm;
#if defined(RANGING_DEBUG_RTT)
                    char dbuf[40];
                    snprintf(dbuf, sizeof(dbuf), "DIST: %lu mm", (unsigned long)mm);
                    test_run_info((unsigned char *)dbuf);
#endif
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

#if defined(RANGING_DEBUG_RTT)
            if ((m_seq % 100) == 0) { ranging_report_margin(); }
#endif
        }
        (void)sd_app_evt_wait();   /* sleep until the next SoftDevice/app_timer event */
    }
    return 0;
}

#endif /* TEST_SENSOR_STREAM */

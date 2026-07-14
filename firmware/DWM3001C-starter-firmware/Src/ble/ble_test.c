/*! BLE bring-up test (Milestone 2a.1): S112 SoftDevice + advertising only.
 *
 *  Enable with TEST_BLE in example_selection.h + the ble_test() dispatch in
 *  main.c. Success = the board advertises as "DWM-SENSOR" and is visible in the
 *  nRF Connect app. No GATT service yet (that's M2a.2). */

#include "example_selection.h"

#if defined(TEST_BLE)

#include <string.h>
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

extern void test_run_info(unsigned char *data);

/* The SoftDevice's NVIC wrapper requires exactly one definition of this. */
nrf_nvic_state_t nrf_nvic_state = {0};

#define DEVICE_NAME            "DWM-SENSOR"
#define APP_BLE_CONN_CFG_TAG   1
#define APP_BLE_OBSERVER_PRIO  3
#define APP_ADV_INTERVAL       64   /* 40 ms, in 0.625 ms units */
#define APP_ADV_DURATION       0    /* advertise forever */

NRF_BLE_GATT_DEF(m_gatt);
BLE_ADVERTISING_DEF(m_advertising);

static uint16_t m_conn_handle = BLE_CONN_HANDLE_INVALID;

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
            break;

        default:
            break;
    }
}

NRF_SDH_BLE_OBSERVER(m_ble_observer, APP_BLE_OBSERVER_PRIO, ble_evt_handler, NULL);

static void ble_stack_init(void)
{
    ret_code_t err_code = nrf_sdh_enable_request();
    APP_ERROR_CHECK(err_code);

    uint32_t ram_start = 0;
    err_code = nrf_sdh_ble_default_cfg_set(APP_BLE_CONN_CFG_TAG, &ram_start);
    APP_ERROR_CHECK(err_code);

    err_code = nrf_sdh_ble_enable(&ram_start);
    APP_ERROR_CHECK(err_code);
}

static void gap_params_init(void)
{
    ble_gap_conn_sec_mode_t sec_mode;
    BLE_GAP_CONN_SEC_MODE_SET_OPEN(&sec_mode);

    ret_code_t err_code = sd_ble_gap_device_name_set(
        &sec_mode, (const uint8_t *)DEVICE_NAME, strlen(DEVICE_NAME));
    APP_ERROR_CHECK(err_code);

    ble_gap_conn_params_t gap_conn_params;
    memset(&gap_conn_params, 0, sizeof(gap_conn_params));
    gap_conn_params.min_conn_interval = MSEC_TO_UNITS(20, UNIT_1_25_MS);
    gap_conn_params.max_conn_interval = MSEC_TO_UNITS(75, UNIT_1_25_MS);
    gap_conn_params.slave_latency     = 0;
    gap_conn_params.conn_sup_timeout  = MSEC_TO_UNITS(4000, UNIT_10_MS);

    err_code = sd_ble_gap_ppcp_set(&gap_conn_params);
    APP_ERROR_CHECK(err_code);
}

static void gatt_init(void)
{
    ret_code_t err_code = nrf_ble_gatt_init(&m_gatt, NULL);
    APP_ERROR_CHECK(err_code);
}

static void advertising_init(void)
{
    ble_advertising_init_t init;
    memset(&init, 0, sizeof(init));

    init.advdata.name_type          = BLE_ADVDATA_FULL_NAME;
    init.advdata.include_appearance = false;
    init.advdata.flags              = BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE;

    init.config.ble_adv_fast_enabled  = true;
    init.config.ble_adv_fast_interval = APP_ADV_INTERVAL;
    init.config.ble_adv_fast_timeout  = APP_ADV_DURATION;

    ret_code_t err_code = ble_advertising_init(&m_advertising, &init);
    APP_ERROR_CHECK(err_code);

    ble_advertising_conn_cfg_tag_set(&m_advertising, APP_BLE_CONN_CFG_TAG);
}

int ble_test(void)
{
    ret_code_t err_code = app_timer_init();
    APP_ERROR_CHECK(err_code);

    ble_stack_init();
    gap_params_init();
    gatt_init();
    advertising_init();

    err_code = ble_advertising_start(&m_advertising, BLE_ADV_MODE_FAST);
    APP_ERROR_CHECK(err_code);

    test_run_info((unsigned char *)"BLE: advertising as DWM-SENSOR");

    for (;;)
    {
        (void)sd_app_evt_wait();   /* sleep until the next SoftDevice event */
    }
    return 0;
}

#endif /* TEST_BLE */

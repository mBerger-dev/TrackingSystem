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

        case BLE_GAP_EVT_PHY_UPDATE_REQUEST:
        {
            /* Modern centrals request a PHY change right after connecting. The
             * peripheral MUST answer or the Link Layer procedure stalls and the
             * phone hangs on "Connecting". Let the SoftDevice pick the PHY. */
            ble_gap_phys_t const phys = {
                .rx_phys = BLE_GAP_PHY_AUTO,
                .tx_phys = BLE_GAP_PHY_AUTO,
            };
            dbg("phy_update", sd_ble_gap_phy_update(
                p_ble_evt->evt.gap_evt.conn_handle, &phys));
            break;
        }

        case BLE_GATTS_EVT_SYS_ATTR_MISSING:
            /* No bonding: hand the stack empty system attributes so enabling the
             * CCCD (notifications) succeeds instead of erroring. */
            (void)sd_ble_gatts_sys_attr_set(m_conn_handle, NULL, 0, 0);
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

# BLE / SoftDevice integration notes (Milestone 2)

The starter firmware is bare-metal (app at flash 0). Adding BLE means running the
**S112 SoftDevice** (peripheral-only, smallest) underneath the app.

## What was changed to bring up the SoftDevice
- **App relocation** (`dw3000_api.emProject` linker macros): `FLASH_START` 0 -> `0x19000`
  (above S112), `RAM_START` `0x20000000` -> `0x20002380`, `RAM_SIZE` -> `0x1dc80`.
- **Preprocessor** (emProject): added `SOFTDEVICE_PRESENT;S112;NRF_SD_BLE_API_VERSION=7;`
  `BLE_STACK_SUPPORT_REQD;NRF_BLE_GATT_ENABLED=1`; removed `NO_VTOR_CONFIG`
  (SoftDevice forwards interrupts to the app vector table via VTOR).
- **Removed** `components/drivers_nrf/nrf_soc_nosd` from includes — those are the
  *no-SoftDevice* stubs; with a real SoftDevice they clash with the real headers.
- **sdk_config.h**: enabled `NRF_SDH_ENABLED`, `NRF_SDH_BLE_ENABLED`,
  `NRF_SDH_SOC_ENABLED`, `BLE_ADVERTISING_ENABLED`, `NRF_BLE_GATT_ENABLED`,
  `NRF_BLE_CONN_PARAMS_ENABLED`; `NRF_SDH_BLE_PERIPHERAL_LINK_COUNT=1`,
  `NRF_SDH_BLE_VS_UUID_COUNT=1`.
- **Sources added**: nrf_sdh(.c/_ble/_soc), ble_advdata, ble_advertising,
  nrf_ble_gatt, ble_srv_common, ble_conn_params, ble_conn_state, nrf_atflags,
  app_timer, nrf_section_iter.
- **flash_placement.xml**: added the SoftDevice-handler linker sections
  (`.sdh_*_observers`, `.pwr_mgmt_data`, `.nrf_queue`). NOTE: `.nrf_balloc` is
  already a RAM section in the Qorvo layout — do NOT also add it to FLASH.
- **ble_test.c**: defines `nrf_nvic_state` (SoftDevice needs exactly one), inits
  the stack, advertises as `DWM-SENSOR` (M2a.1 = advertising only).

## Flashing (two images, from macOS host)
The app requires the SoftDevice present first. Flash order: erase, S112, app.
```bash
JLinkExe: loadfile hex/s112_softdevice.hex ; loadfile hex/ble_test.hex
```
Images: `firmware/hex/s112_softdevice.hex`, `firmware/hex/ble_test.hex`.

## Open item to watch at runtime
`RAM_START=0x20002380` is an estimate. If `sd_ble_enable` reports NRF_ERROR_NO_MEM
over RTT, it prints the required app RAM start — bump `RAM_START`/`RAM_SIZE` to match.

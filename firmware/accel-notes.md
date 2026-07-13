# LIS2DH12 accelerometer — integration notes

The starter firmware has **no** accelerometer support; only the DW3000 UWB (SPIM3).
So we bring the LIS2DH12 up from scratch.

## Bus & wiring (DWM3001C module internal)
- Interface: **I²C** (the module ties the sensor's CS high to select I²C).
- **SDA = P0.24**, **SCL = P1.04** (nRF52833). Source: LEAPS DWM3001C hardware docs.
- I²C address: **0x18 or 0x19** (7-bit). SA0 sets the LSB; unknown which on this
  module, so probe both and use whichever answers WHO_AM_I.
- Interrupt pins (INT1/INT2): not documented; not needed for polled 100 Hz reads.

## Key registers (ST LIS2DH12 datasheet)
- `WHO_AM_I` = 0x0F → must read **0x33**.
- `CTRL_REG1` = 0x20 → `0x57` = 100 Hz, normal mode, X/Y/Z enabled.
- `CTRL_REG4` = 0x23 → `0x00` = ±2 g, high-res off (10-bit). (±2 g is fine for gym.)
- Output regs 0x28..0x2D (XL,XH,YL,YH,ZL,ZH). Set bit7 of the sub-address
  (auto-increment, i.e. read from 0x28|0x80) to burst-read all 6 bytes.
- Data is left-justified 16-bit two's complement; for 10-bit normal mode the
  meaningful value is `(int16)>>6`.

## nRF5 SDK driver
- Use `nrf_drv_twi` (legacy TWI wrapper; SPI legacy wrappers are already in use).
- Pick a TWI instance that does NOT collide with SPIM3 (DW3000). TWIM0/TWIM1 are
  free — use **TWI instance 1** (TWIM1). Must enable `TWI_ENABLED` + `TWI1_ENABLED`
  in `sdk_config.h`.

## Build integration
- New source files must be added to `dw3000_api.emProject` (SEGGER project XML),
  or they won't compile. See how `Src/platform/*.c` are listed and mirror it.

## Build gotcha (resolved)
Using `nrfx_twim` directly failed with `NRFX_TWIM1_INST_IDX undeclared`. The
nRF5 SDK's `apply_old_config.h` remaps the legacy `TWI*` config onto nrfx and
overrides direct `NRFX_TWIM*` settings. Fix: set legacy `TWI1_USE_EASY_DMA = 1`
in `sdk_config.h` (with `TWI_ENABLED`/`TWI1_ENABLED` = 1) so TWI1 maps to the
EasyDMA driver (`nrfx_twim`). Then it builds.

## Test build
`#define TEST_ACCEL` in example_selection.h + `accel_test();` in main.c dispatch.
Prebuilt image: `firmware/hex/accel_test.hex`. Streams `ACC: x y z` over RTT.

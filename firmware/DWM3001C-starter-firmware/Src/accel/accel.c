/*! LIS2DH12 3-axis accelerometer driver for the DWM3001C module.
 *
 *  The sensor hangs off the nRF52833's I2C (module ties its CS high to select
 *  I2C mode). Wiring (per the DWM3001C hardware docs): SCL=P1.04, SDA=P0.24.
 *  We drive it with TWIM instance 1 in blocking mode (SPIM3 is used by the
 *  DW3000, so instance 1 is free). */

#include "accel.h"
#include "nrfx_twim.h"
#include "nrf_gpio.h"

#define ACCEL_SCL_PIN       NRF_GPIO_PIN_MAP(1, 4)
#define ACCEL_SDA_PIN       NRF_GPIO_PIN_MAP(0, 24)

/* LIS2DH12 registers */
#define REG_WHO_AM_I        0x0F
#define REG_CTRL_REG1       0x20
#define REG_CTRL_REG4       0x23
#define REG_OUT_X_L         0x28
#define WHO_AM_I_VALUE      0x33
#define SUB_ADDR_AUTO_INC   0x80   /* bit7 of sub-address => multi-byte read */

/* CTRL_REG1 = 0x57 : 100 Hz ODR, normal power, X/Y/Z enabled.
 * CTRL_REG4 = 0x00 : +-2 g, high-resolution off (10-bit). */
#define CTRL_REG1_100HZ_XYZ 0x57
#define CTRL_REG4_2G        0x00

static const nrfx_twim_t m_twim = NRFX_TWIM_INSTANCE(1);
static uint8_t m_addr  = 0x19;
static bool    m_ready = false;

static bool reg_write(uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = { reg, val };
    return nrfx_twim_tx(&m_twim, m_addr, buf, sizeof(buf), false) == NRFX_SUCCESS;
}

static bool reg_read(uint8_t reg, uint8_t *dst, uint8_t n)
{
    if (n > 1)
    {
        reg |= SUB_ADDR_AUTO_INC;
    }
    /* Repeated-start: write the sub-address (no stop), then read. */
    if (nrfx_twim_tx(&m_twim, m_addr, &reg, 1, true) != NRFX_SUCCESS)
    {
        return false;
    }
    return nrfx_twim_rx(&m_twim, m_addr, dst, n) == NRFX_SUCCESS;
}

bool accel_init(void)
{
    nrfx_twim_config_t cfg = {
        .scl                = ACCEL_SCL_PIN,
        .sda                = ACCEL_SDA_PIN,
        .frequency          = NRF_TWIM_FREQ_400K,
        .interrupt_priority = 6,
        .hold_bus_uninit    = false,
    };

    if (nrfx_twim_init(&m_twim, &cfg, NULL, NULL) != NRFX_SUCCESS)
    {
        return false;
    }
    nrfx_twim_enable(&m_twim);

    /* SA0 wiring is unknown on this module, so try both addresses. */
    uint8_t id = 0;
    m_addr = 0x19;
    if (!reg_read(REG_WHO_AM_I, &id, 1) || id != WHO_AM_I_VALUE)
    {
        m_addr = 0x18;
        if (!reg_read(REG_WHO_AM_I, &id, 1) || id != WHO_AM_I_VALUE)
        {
            return false;
        }
    }

    if (!reg_write(REG_CTRL_REG1, CTRL_REG1_100HZ_XYZ)) { return false; }
    if (!reg_write(REG_CTRL_REG4, CTRL_REG4_2G))        { return false; }

    m_ready = true;
    return true;
}

bool accel_read(int16_t *x, int16_t *y, int16_t *z)
{
    if (!m_ready)
    {
        return false;
    }

    uint8_t b[6];
    if (!reg_read(REG_OUT_X_L, b, sizeof(b)))
    {
        return false;
    }

    *x = (int16_t)((uint16_t)b[0] | ((uint16_t)b[1] << 8));
    *y = (int16_t)((uint16_t)b[2] | ((uint16_t)b[3] << 8));
    *z = (int16_t)((uint16_t)b[4] | ((uint16_t)b[5] << 8));
    return true;
}

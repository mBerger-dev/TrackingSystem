#ifndef ACCEL_H_
#define ACCEL_H_

#include <stdint.h>
#include <stdbool.h>

/*! Bring up the on-module LIS2DH12 3-axis accelerometer over I2C (TWIM1,
 *  SCL=P1.04, SDA=P0.24). Probes both possible I2C addresses (0x18/0x19),
 *  verifies WHO_AM_I, and configures 100 Hz / +-2 g.
 *  Returns true on success. */
bool accel_init(void);

/*! Read one 3-axis sample. Values are raw left-justified int16 (for +-2 g
 *  normal mode, the meaningful reading is value >> 6, i.e. 10-bit).
 *  Returns false on a bus error or if accel_init() has not succeeded. */
bool accel_read(int16_t *x, int16_t *y, int16_t *z);

#endif /* ACCEL_H_ */

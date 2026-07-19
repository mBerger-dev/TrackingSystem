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

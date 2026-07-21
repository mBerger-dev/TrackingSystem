# BLE contract — sensor stream (single source of truth)

Shared by the tag firmware (`Src/ble/sensor_ble.c`) and the iOS app
(`ios/SensorCore/Sources/SensorCore/SensorPacket.swift`). Do not change one side
without the other.

## GATT
- Service UUID (128-bit):         `6E40FE00-B5A3-F393-E0A9-E50E24DCCA9E`
- Sensor characteristic (notify): `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`
  - Properties: Notify. Contains a CCCD so the central can enable notifications.
  - Value length: 16 bytes, fixed.

## Packet (16 bytes, little-endian)
| offset | field          | type   | notes                                  |
|--------|----------------|--------|----------------------------------------|
| 0      | seq            | uint16 | +1 per packet, wraps at 65535          |
| 2      | board_time_ms  | uint32 | monotonic ms since boot                |
| 6      | ax             | int16  | raw left-justified LIS2DH12 X          |
| 8      | ay             | int16  | raw left-justified LIS2DH12 Y          |
| 10     | az             | int16  | raw left-justified LIS2DH12 Z          |
| 12     | uwb_mm         | uint32 | distance mm; 0xFFFFFFFF = none         |

- Accel raw counts: at rest the down axis reads ~±256 counts after `>>6` (1 g @ ±2 g),
  i.e. a raw value near `0x4000`.
- **Reading it by eye in nRF Connect:** the value is shown as 8 groups of 4 hex
  chars (2 bytes each); accel is groups 4/5/6. Because the data is left-justified
  *and* little-endian, the **last two hex chars of a group are the signal** and the
  first two are the noise floor, which churns constantly even at rest. A flat board
  shows one axis near `…40` (or `…C0`) and the others near `…00`/`…FF`. If the last
  two characters also jump wildly at rest, that is a genuine fault — the low byte
  scrambling is not.
- `uwb_mm = 0xFFFFFFFF` on the responder always, and on the initiator until live
  ranging exists (M2b). In M2a.2 both roles send the sentinel.

## Advertising
- Name by role: `DWM-INIT` / `DWM-RESP`.
- The 128-bit service UUID is included in the scan-response data (so the phone can
  scan by service UUID in M3).

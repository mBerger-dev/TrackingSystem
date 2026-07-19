#ifndef RANGING_H_
#define RANGING_H_

#include <stdint.h>
#include <stdbool.h>

/* Configure the DW3000 for the role compiled in (SENSOR_ROLE_INITIATOR).
 * The responder additionally arms IRQ-driven poll answering.
 * Returns false on any init failure (details printed over RTT). */
bool ranging_init(void);

/* Initiator only: run one bounded SS-TWR exchange.
 * Returns true and writes *out_mm on success; false on timeout, bad frame,
 * or a result failing the sanity check. Blocks for at most a few ms.
 * On the responder this always returns false. */
bool ranging_exchange(uint32_t *out_mm);

/* Print poll count and the worst deadline margin seen so far over RTT.
 * Call from thread mode only. */
void ranging_report_margin(void);

#endif /* RANGING_H_ */

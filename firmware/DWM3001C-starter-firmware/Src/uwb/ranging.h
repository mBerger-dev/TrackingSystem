#ifndef RANGING_H_
#define RANGING_H_

#include <stdint.h>
#include <stdbool.h>

/* Bench instrumentation over RTT (per-reading "DIST:" lines and the once-a-second
 * margin report). It formats and writes inside the 100 Hz sample loop, which costs
 * CPU and an RTT critical section — acceptable on a USB-tethered bench, not in a
 * worn capture where the tooling must not perturb what it measures. RTT itself is
 * NO_BLOCK_SKIP (SEGGER_RTT_Conf.h:73), so this can never block, only cost time.
 *
 * Comment this out for worn/untethered runs; leave it on for bench verification,
 * which reads the printed values (see the M2b.1 spec, section 6). */
#define RANGING_DEBUG_RTT

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

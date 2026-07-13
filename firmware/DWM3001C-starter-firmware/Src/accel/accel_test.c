/*! Standalone accelerometer bring-up test.
 *
 *  Enable by defining TEST_ACCEL in example_selection.h and uncommenting the
 *  accel_test() dispatch line in main.c. Streams the 3 axes over RTT so you
 *  can confirm the values respond to tilting/shaking the board. */

#include "example_selection.h"

#if defined(TEST_ACCEL)

#include <stdio.h>
#include "accel.h"
#include "nrf_delay.h"

extern void test_run_info(unsigned char *data);

int accel_test(void)
{
    if (!accel_init())
    {
        test_run_info((unsigned char *)"ACCEL: init FAILED (no WHO_AM_I 0x33)");
        while (1) { nrf_delay_ms(1000); }
    }

    test_run_info((unsigned char *)"ACCEL: init OK - streaming (raw 10-bit counts)");

    char line[48];
    while (1)
    {
        int16_t x, y, z;
        if (accel_read(&x, &y, &z))
        {
            /* >>6 converts the left-justified int16 to the 10-bit value.
             * At rest, the down axis reads ~ +-256 counts (1 g at +-2 g). */
            snprintf(line, sizeof(line), "ACC: %5d %5d %5d",
                     (int)(x >> 6), (int)(y >> 6), (int)(z >> 6));
            test_run_info((unsigned char *)line);
        }
        else
        {
            test_run_info((unsigned char *)"ACCEL: read error");
        }
        nrf_delay_ms(100); /* 10 Hz print (sensor ODR is 100 Hz) for readability */
    }
    return 0;
}

#endif /* TEST_ACCEL */

/*
 *------------------------------------------------------------
 *                                  ___ ___ _
 *  ___ ___ ___ ___ ___       _____|  _| . | |_
 * |  _| . |_ -|  _| . |     |     | . | . | '_|
 * |_| |___|___|___|___|_____|_|_|_|___|___|_,_|
 *                     |_____|       firmware v2
 * ------------------------------------------------------------
 * Copyright (c)2024 Ross Bamford and contributors
 * See top-level LICENSE.md for licence information.
 *
 * FDC (WD37C65) probe for stage 2 startup
 * ------------------------------------------------------------
 */

#include <stdbool.h>
#include <stdint.h>
#include "fd.h"
#include "machine.h"

bool fdc_probe_report(void) {
    if (!FD_check_support()) {
        FW_PRINT_C("Warning: No FDC support in ROM - This may indicate your ROMs are not built correctly!\r\n");
        return false;
    }

    FW_PRINT_C("FDC: WD37C65 floppy controller present\r\n");
    return false;   /* Phase 1: detect only, no boot from floppy yet */
}

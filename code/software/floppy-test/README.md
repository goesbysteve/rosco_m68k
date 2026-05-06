# WD37C65 Floppy Driver Test Program

This is a hardware test harness for the WD37C65-based floppy expansion
board on rosco_m68k.

It exercises the firmware floppy driver (built with `WITH_FDC=true`) by
running through init, media detect, geometry query, and sector read/write.
Motor auto-off is handled by `FD_motor_poll()` in the firmware TICK_HANDLER
(~3 seconds idle).

The TRAP #13 C-ABI wrappers and public header live in `../fdc/` (shared
source tree) rather than in this directory.

## Requirements

- Firmware built with `WITH_FDC=true`
- WD37C65 floppy expansion board connected

## Building

```
make clean all
```

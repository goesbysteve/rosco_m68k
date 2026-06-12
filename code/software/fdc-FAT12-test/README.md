# FAT12 Filesystem Test for rosco_m68k

High-level test program that demonstrates FAT12 filesystem access using Chan FatFs library.

## Purpose

This test demonstrates **file-level** operations on a FAT12 formatted floppy disk:
- Mounting the filesystem
- Listing directory contents
- Reading files
- Writing files
- Creating directories

Compare with `floppy-test/` which performs **low-level sector** operations.

## Building

From this directory:
```bash
make clean all
```

This will build `fdc-FAT12-test.bin` which can be loaded on rosco_m68k.

## Requirements

1. **Firmware**: rosco_m68k firmware with floppy disk support (TRAP #13)
2. **Hardware**: WD37C65 FDC board installed
3. **Media**: 3.5" floppy disk formatted as FAT12 (720K or 1.44M)

## Test Output

The program will:
1. Mount the FAT12 filesystem
2. List all files and directories in the root
3. Try to read `TEST.TXT` if it exists
4. Create `HELLO.TXT` with a test message (if write enabled)
5. Create directory `TESTDIR` (if write enabled)

## Architecture

```
kmain.c (this program)
    ↓ uses
ff.h (Chan FatFs API)
    ↓ implements via
diskio.c (bridge layer)
    ↓ calls
fdc.h (TRAP wrappers)
    ↓ invokes
TRAP #13 (firmware)
```

All components in `../fdc/` and `../fdc/fatfs/` are shared libraries.

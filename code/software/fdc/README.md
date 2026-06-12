# FDC Library for rosco_m68k

This directory contains the floppy disk controller (FDC) library for rosco_m68k, providing high-level filesystem access to WD37C65-based floppy drives.

# IMPORTANT!!! #

Currently, diskio.c hardcodes unit=0. I plan on adding multi-drive support after getting a second drive. Anyone want to donate a working drive in UK?

## Contents

- **fdc.h** - Public C interface for FDC driver (wrapper for firmware TRAP #13 calls)
- **fdc.asm** - Assembly wrappers for TRAP #13 FDC function calls (FC 20-25)
- **fatfs/** - Chan FatFs R0.16 library with rosco_m68k adaptations

## Chan FatFs Integration

This library uses [Chan FatFs](http://elm-chan.org/fsw/ff/00index_e.html) R0.16, a generic FAT filesystem module that supports FAT12, FAT16, and FAT32. The original code has been adapted for rosco_m68k's freestanding environment.

### Files

- **ff.c** / **ff.h** - Core FatFs implementation
- **diskio.c** / **diskio.h** - Low-level disk I/O bridge to rosco_m68k FDC driver
- **ffconf.h** - FatFs configuration
- **00readme.txt** / **00history.txt** / **LICENSE.txt** - Original FatFs documentation

## Modifications for rosco_m68k

The following changes were made to adapt Chan FatFs for rosco_m68k:

### 1. ff.c - Freestanding Environment Support

Since rosco_m68k applications use `-ffreestanding`, standard C library functions are not available. Added local implementations at the top of ff.c (lines 23-60):

```c
static int memcmp(const void* s1, const void* s2, size_t n);
static void* memcpy(void* dest, const void* src, size_t n);
static void* memset(void* s, int c, size_t n);
static char* strchr(const char* s, int c);
```

**Note:** These are simple byte-by-byte implementations. For performance-critical applications, consider optimizing for 68000 word/longword moves.

**Build note:** The Makefile uses `-Wno-error=overflow` when compiling ff.c to allow the original code's assignment of DDEM (0xE5) to signed char without treating the overflow warning as an error. This keeps ff.c unmodified from the Chan FatFs distribution.

### 2. diskio.c - FDC Bridge Implementation

Implemented complete disk I/O layer connecting Chan FatFs to rosco_m68k firmware:

**Key implementation details:**

- **disk_initialize()** - Calls `FD_init()` and `FD_media_detect()` with validation:
  - Checks `FD_check_support()` to verify FDC driver is compiled into firmware
  - Initializes `FDDevice` structure with unit=0, track=0xFF (unknown)

- **disk_read()** / **disk_write()** - Correctly interpret return values:
  - `FD_read_sectors()` and `FD_write_sectors()` return **sector count transferred**, not FRC_OK
  - Check: `if (FD_read_sectors(...) == count)` ✅ (NOT `== FRC_OK` ❌)

- **disk_ioctl()** - Implements required commands:
  - `GET_SECTOR_COUNT` - Validates geometry to prevent overflow
  - `GET_SECTOR_SIZE` - Returns 512 bytes
  - `GET_BLOCK_SIZE` - Returns 1 (single sector erase)
  - `CTRL_SYNC` - No-op (no write cache)

**Production fixes applied:**

1. **FD_check_support() validation** - Prevents crashes when firmware lacks FDC driver
2. **Geometry overflow checks** - Validates cyls/heads/secs are sane before multiplication
3. **Total sector overflow check** - Prevents arithmetic overflow in sector count calculation

### 3. ffconf.h - rosco_m68k Configuration

Key settings for rosco_m68k environment:

```c
#define FF_FS_READONLY   0     /* Write support enabled */
#define FF_USE_LFN       0     /* 8.3 filenames only (no long filename support) */
#define FF_CODE_PAGE     437   /* US (OEM) code page */
#define FF_FS_NORTC      1     /* No real-time clock */
#define FF_NORTC_YEAR    2026  /* Fixed timestamp year */
#define FF_MIN_SS        512   /* Fixed 512-byte sectors */
#define FF_MAX_SS        512
#define FF_FS_REENTRANT  0     /* Not thread-safe (single-threaded use only) */
#define FF_VOLUMES       1     /* Single logical drive */
```

## Usage

### In Your Makefile

```make
FDC_DIR = $(ROSCO_M68K_DEFAULT_DIR)/code/software/fdc
FF_DIR = $(FDC_DIR)/fatfs

EXTRA_CFLAGS += -I$(FDC_DIR) -I$(FF_DIR)

$(ELF): kmain.o fdc.o ff.o diskio.o
	$(LD) $(LDFLAGS) $^ $(LIBS) -o $@

fdc.o: $(FDC_DIR)/fdc.asm
	$(AS) $(ASFLAGS) -o $@ $<

ff.o: $(FF_DIR)/ff.c
	$(CC) $(CFLAGS) -c -o $@ $<

diskio.o: $(FF_DIR)/diskio.c
	$(CC) $(CFLAGS) -c -o $@ $<
```

### In Your Code

```c
#include "ff.h"

static FATFS fs;
static FIL file;
static BYTE buffer[512];

void kmain(void) {
    FRESULT res;
    UINT br;

    /* Mount filesystem */
    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        printf("Mount failed: %d\n", res);
        return;
    }

    /* Open and read file */
    res = f_open(&file, "TEST.TXT", FA_READ);
    if (res == FR_OK) {
        f_read(&file, buffer, sizeof(buffer), &br);
        f_close(&file);
    }

    /* Unmount before exit */
    f_mount(NULL, "", 0);
}
```

## Design Constraints

### Single Drive, Non-Concurrent

The current implementation supports:

- ✅ **Single default drive** - Hardcoded to unit 0 in diskio.c
- ✅ **Sequential operations only** - No concurrent access support
- ✅ **Not thread-safe** - Single-threaded applications only

This matches the RomWBW floppy driver architecture, where global command/result buffers prevent concurrent access.

**Rationale:** The firmware FDC driver uses shared global state (FCP_*, FRB_*, FCD_*) for command/result buffers. Concurrent operations would corrupt this state.

### Motor Management

Motor control is **fully automatic** via firmware:

- ✅ Firmware MFP Timer C ISR calls `FD_motor_poll()` at 100Hz
- ✅ 3-second idle timeout (300 ticks) after last I/O (configurable via `MOTOR_IDLE_TICKS`)
- ✅ Applications don't need to manage motors

**Do not** call `FD_motor_poll()` from application code - it's handled automatically.

## Multi-Drive Support (Future)

The firmware supports drive selection via the `FDDevice.unit` field (0 or 1), which sets the drive select bits in the FDC commands. Each drive can have different media types detected independently.

To support multiple drives in applications:

1. Modify diskio.c to use `static FDDevice g_drives[2];`
2. Initialize each drive with correct unit number:
   - `g_drives[0].unit = 0;` and `g_drives[1].unit = 1;`
3. Change `disk_initialize(BYTE pdrv)` to accept pdrv 0 or 1
4. Update all disk_* functions to use `&g_drives[pdrv]`
5. Set `FF_VOLUMES 2` in ffconf.h
6. Mount with volume prefix: `f_mount(&fs, "0:", 1)` or `f_mount(&fs, "1:", 1)`

**Important:** This is safe for sequential access only. Both drives share the same global firmware command/result buffers (FCP_*, FRB_*, FCD_*), so concurrent operations would corrupt state. Operations must be serialized at the application level.

## Supported Media Formats

- 720KB (3.5" DS/DD) - 80 cylinders, 2 heads, 9 sectors/track, 250 Kbps
- 1.44MB (3.5" DS/HD) - 80 cylinders, 2 heads, 18 sectors/track, 500 Kbps
- 360KB (5.25" DS/DD) - 40 cylinders, 2 heads, 9 sectors/track, 250 Kbps
- 1.2MB (5.25" DS/HD) - 80 cylinders, 2 heads, 15 sectors/track, 500 Kbps

### Media Auto-Detection

The firmware uses hardware probing via READID command at both data rates:

**Detection algorithm (when `FD_MEDIA_AUTO=1`, the default):**
1. Tries up to 5 times (retry loop)
2. Each retry tests **both** formats in sequence:
   - First: `FD_MEDIA_PRIMARY` (default: 1.44MB at 500 Kbps)
   - Then: `FD_MEDIA_ALT` (default: 720KB at 250 Kbps)
3. Returns the first format that succeeds with READID
4. If all retries fail, returns `FRC_NODATA` (no disk or FDC not responding)

**Firmware configuration (in `fd_config.inc`):**
- `FD_MEDIA_AUTO=1` - Enable hardware probing (default)
- `FD_MEDIA_AUTO=0` - Skip probing, use `FD_MEDIA_PRIMARY` unconditionally
- `FD_MEDIA_PRIMARY=FDM144` - Format tried first (default: 1.44MB)
- `FD_MEDIA_ALT=FDM720` - Fallback format (default: 720KB)

The higher-density format is tried first because 1.44MB disks are more common, minimizing detection time for the typical case.

**Drive selection:** The `FDDevice.unit` field (0 or 1) selects the physical drive. Each drive can have different media types detected independently.

## See Also

- **fdc-FAT12-test/** - Example application demonstrating filesystem usage
- **../../firmware/.../blockdev/fd.asm** - Low-level firmware FDC driver
- **../../firmware/rosco_m68k_firmware/stage1/blockdev/fd_config.inc** - Firmware configuration options (media detection, motor timeout)
- **Chan FatFs documentation:** http://elm-chan.org/fsw/ff/00index_e.html

## License

- **Chan FatFs** - See fatfs/LICENSE.txt (freely distributable, no warranty)
- **rosco_m68k adaptations** - MIT License (see top-level LICENSE)

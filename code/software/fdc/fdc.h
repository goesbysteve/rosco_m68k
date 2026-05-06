/*
 *------------------------------------------------------------
 *                                  ___ ___ _
 *  ___ ___ ___ ___ ___       _____|  _| . | |_
 * |  _| . |_ -|  _| . |     |     | . | . | '_|
 * |_| |___|___|___|___|_____|_|_|_|___|___|_,_|
 *                     |_____|       firmware v2
 * ------------------------------------------------------------
 * fdc.h -- public interface for the rosco_m68k WD37C65 floppy driver.
 *
 * Include this header in any application that uses the firmware floppy
 * blockdev (firmware built with WITH_FDC=true). Pair with fdc.asm for
 * the C-ABI TRAP #13 wrappers.
 *
 * Mirrors the ATA/markm-ide pattern: apps include this source tree
 * directly rather than linking a library.
 * ------------------------------------------------------------
 */

#ifndef ROSCO_M68K_FDC_H
#define ROSCO_M68K_FDC_H

#include <stdint.h>
#include <stdbool.h>

/*
 * Per-drive persistent state, allocated by the caller.
 * Pass a zero-initialised instance to FD_init() before first use.
 */
typedef struct {
    uint8_t unit;          /* 0 or 1                               */
    uint8_t current_track; /* 0xFF = unknown/needs recal           */
    uint8_t media_type;    /* FDM720/FDM144/FDM360/FDM120          */
    uint8_t flags;         /* bit0 = fdcrdy                        */
} FDDevice;

/* Media type constants */
#define FDM720           0U    /* 3.5"  DS/DD  720 KB  250 Kbps */
#define FDM144           1U    /* 3.5"  DS/HD 1.44 MB  500 Kbps */
#define FDM360           2U    /* 5.25" DS/DD  360 KB  250 Kbps */
#define FDM120           3U    /* 5.25" DS/HD  1.2 MB  500 Kbps */

#define FDD_FLAG_FDCRDY  0x01U

/* Result codes (fd.asm FRC_*) */
#define FRC_OK           0
#define FRC_ABORT        (-4)
#define FRC_ABTERM       (-8)
#define FRC_INVCMD       (-9)
#define FRC_DSKCHG       (-10)
#define FRC_ENDCYL       (-11)
#define FRC_DATAERR      (-12)
#define FRC_OVERRUN      (-13)
#define FRC_NODATA       (-14)
#define FRC_NOTWRIT      (-15)
#define FRC_MISADR       (-16)
#define FRC_TOFDCRDY     (-17)
#define FRC_TOSNDCMD     (-18)
#define FRC_TOGETRES     (-19)
#define FRC_TOEXEC       (-20)

/* Firmware register addresses (informational -- used internally by the driver) */
#define FD_REG_CCR_ADDR  0x00F800C8UL
#define FD_REG_MSR_ADDR  0x00F800CAUL
#define FD_REG_DATA_ADDR 0x00F800CCUL
#define FD_REG_DOR_ADDR  0x00F800CEUL
#define FD_REG_TC_ADDR   0x00F800CEUL

/*
 * TRAP #13 entry points (C-ABI wrappers in fdc.asm).
 * Firmware must have been built with WITH_FDC=true.
 */

/* FC=20: returns true if firmware has FDC support compiled in */
bool     FD_check_support(void);

/* FC=21: initialise drive; dev must be zero-initialised by caller */
uint32_t FD_init(uint32_t drive, FDDevice *dev);

/* FC=22/23: read/write sectors; returns number of sectors transferred */
uint32_t FD_read_sectors(uint8_t *buf, uint32_t lba, uint32_t count, FDDevice *dev);
uint32_t FD_write_sectors(uint8_t *buf, uint32_t lba, uint32_t count, FDDevice *dev);

/* FC=24: geometry packed as (NUMCYL<<16)|(NUMHD<<8)|NUMSEC */
uint32_t FD_geom(FDDevice *dev);
#define FD_GEOM_CYLS(r)   ((uint32_t)(r) >> 16)
#define FD_GEOM_HEADS(r)  (((uint32_t)(r) >> 8) & 0xFFU)
#define FD_GEOM_SECS(r)   ((uint32_t)(r) & 0xFFU)

/* FC=25: probe media; returns FDM144/FDM720 on success, FRC_NODATA if no disk */
int32_t  FD_media_detect(FDDevice *dev);

#endif /* ROSCO_M68K_FDC_H */

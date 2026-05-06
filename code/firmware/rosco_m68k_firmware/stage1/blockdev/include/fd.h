/*
 *------------------------------------------------------------
 *                                  ___ ___ _
 *  ___ ___ ___ ___ ___       _____|  _| . | |_
 * |  _| . |_ -|  _| . |     |     | . | . | '_|
 * |_| |___|___|___|___|_____|_|_|_|___|___|_,_|
 *                     |_____|       firmware v2
 * ------------------------------------------------------------
 * WD37C65 floppy driver public definitions
 * Translated from RomWBW fd.asm (FDMODE_SMB_WD).
 * Driver is implemented entirely in fd.asm.
 * ------------------------------------------------------------
 */

#ifndef __ROSCO_M68K_FD_H
#define __ROSCO_M68K_FD_H

#include <stdint.h>
#include <stdbool.h>

/*
 * Per-drive persistent state, allocated by the caller.
 * Matches ATADevice in minimalism: only fields that survive
 * across calls and that the caller owns.
 *
 * Passed as A1 to FD_init, FD_read_sectors, FD_write_sectors.
 */
typedef struct {
    uint8_t unit;          /* 0 or 1                               */
    uint8_t current_track; /* 0xFF = unknown/needs recal           */
    uint8_t media_type;    /* FDM720/FDM144/FDM360/FDM120          */
    uint8_t flags;         /* bit0 = fdcrdy                        */
} FDDevice;

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

/* Register addresses (informational -- driver uses these internally) */
#define FD_REG_CCR_ADDR  0x00F800C8UL
#define FD_REG_MSR_ADDR  0x00F800CAUL
#define FD_REG_DATA_ADDR 0x00F800CCUL
#define FD_REG_DOR_ADDR  0x00F800CEUL
#define FD_REG_TC_ADDR   0x00F800CEUL

/* Assembly entry points (C-callable) */
uint32_t FD_init(uint32_t drive, FDDevice *dev);
uint32_t FD_read_sectors(uint8_t *buf, uint32_t lba, uint32_t count, FDDevice *dev);
uint32_t FD_write_sectors(uint8_t *buf, uint32_t lba, uint32_t count, FDDevice *dev);
bool     FD_check_support(void);

/* FC=24: geometry packed as (NUMCYL<<16)|(NUMHD<<8)|NUMSEC */
uint32_t FD_geom(FDDevice *dev);
#define FD_GEOM_CYLS(r)   ((uint32_t)(r) >> 16)
#define FD_GEOM_HEADS(r)  (((uint32_t)(r) >> 8) & 0xFFU)
#define FD_GEOM_SECS(r)   ((uint32_t)(r) & 0xFFU)

/* FC=25: probe media; returns FDM144/FDM720 or FRC_NODATA */
int32_t  FD_media_detect(FDDevice *dev);

/*
 * FD_motor_poll -- idle motor-off countdown tick.
 * Must be called once per 100 Hz MFP Timer C tick (or from the
 * application idle loop at a similar rate).
 * Decrements the idle counter armed after each read/write;
 * cuts the motor when the counter reaches zero.
 * Safe to call from an ISR: saves and restores only D0.
 */
void FD_motor_poll(void);

#endif /* __ROSCO_M68K_FD_H */

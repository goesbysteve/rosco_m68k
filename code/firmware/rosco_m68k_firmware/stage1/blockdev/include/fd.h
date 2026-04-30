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
    uint8_t media_type;    /* 0 = 720K, 1 = 1.44M                 */
    uint8_t flags;         /* bit0 = fdcrdy                        */
} FDDevice;

#define FD_MEDIA_720K    0U
#define FD_MEDIA_1440K   1U

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

#endif /* __ROSCO_M68K_FD_H */

/*-----------------------------------------------------------------------*/
/* Low level disk I/O module for FatFs - rosco_m68k WD37C65 FDC         */
/*-----------------------------------------------------------------------*/

#include "ff.h"
#include "diskio.h"
#include "../fdc.h"

static FDDevice g_dev;

/*-----------------------------------------------------------------------*/
/* Get Drive Status                                                      */
/*-----------------------------------------------------------------------*/

DSTATUS disk_status (
	BYTE pdrv		/* Physical drive number (always 0) */
)
{
	if (pdrv != 0) return STA_NOINIT;

	/* Check if device is initialized */
	if (g_dev.flags == 0) {
		return STA_NOINIT;
	}

	return 0;  /* Status OK */
}

/*-----------------------------------------------------------------------*/
/* Initialize Disk Drive                                                 */
/*-----------------------------------------------------------------------*/

DSTATUS disk_initialize (
	BYTE pdrv		/* Physical drive number (always 0) */
)
{
	if (pdrv != 0) return STA_NOINIT;

	/* Verify FDC driver is present in firmware */
	if (!FD_check_support()) {
		return STA_NOINIT;
	}

	/* Initialize device structure */
	g_dev.unit = 0;
	g_dev.current_track = 0xFF;  /* 0xFF = unknown, forces recalibrate */
	g_dev.media_type = 0;
	g_dev.flags = 0;

	/* Initialize FDC and detect media */
	if (FD_init(0, &g_dev) == FRC_OK && FD_media_detect(&g_dev) >= 0) {
		return 0;  /* OK */
	}

	return STA_NOINIT;
}

/*-----------------------------------------------------------------------*/
/* Read Sector(s)                                                        */
/*-----------------------------------------------------------------------*/

DRESULT disk_read (
	BYTE pdrv,		/* Physical drive number (always 0) */
	BYTE *buff,		/* Data buffer to store read data */
	LBA_t sector,	/* Start sector in LBA */
	UINT count		/* Number of sectors to read */
)
{
	if (pdrv != 0 || !buff || count == 0) return RES_PARERR;

	/* FD_read_sectors returns sectors transferred, not FRC_OK */
	if (FD_read_sectors(buff, sector, count, &g_dev) == count) {
		return RES_OK;
	}

	return RES_ERROR;
}

/*-----------------------------------------------------------------------*/
/* Write Sector(s)                                                       */
/*-----------------------------------------------------------------------*/

#if FF_FS_READONLY == 0

DRESULT disk_write (
	BYTE pdrv,			/* Physical drive number (always 0) */
	const BYTE *buff,	/* Data to be written */
	LBA_t sector,		/* Start sector in LBA */
	UINT count			/* Number of sectors to write */
)
{
	if (pdrv != 0 || !buff || count == 0) return RES_PARERR;

	/* FD_write_sectors returns sectors transferred, not FRC_OK */
	if (FD_write_sectors((BYTE*)buff, sector, count, &g_dev) == count) {
		return RES_OK;
	}

	return RES_ERROR;
}

#endif

/*-----------------------------------------------------------------------*/
/* Miscellaneous Functions                                               */
/*-----------------------------------------------------------------------*/

DRESULT disk_ioctl (
	BYTE pdrv,		/* Physical drive number (always 0) */
	BYTE cmd,		/* Control code */
	void *buff		/* Buffer to send/receive control data */
)
{
	if (pdrv != 0) return RES_PARERR;

	switch (cmd) {
		case CTRL_SYNC:
			/* No write cache, nothing to flush */
			return RES_OK;

		case GET_SECTOR_COUNT:
			{
				uint32_t geom = FD_geom(&g_dev);
				uint32_t cyls = FD_GEOM_CYLS(geom);
				uint32_t heads = FD_GEOM_HEADS(geom);
				uint32_t secs = FD_GEOM_SECS(geom);

			/* Validate geometry is sane */
			if (cyls == 0 || heads == 0 || secs == 0 || cyls > 255) {
				return RES_ERROR;
			}

			uint32_t total = cyls * heads * secs;

			/* Check for overflow (typical floppy max: 2880 sectors for 1.44M) */
			if (total > 0xFFFFFFFF / 512) {
				return RES_ERROR;
			}

			*(LBA_t*)buff = (LBA_t)total;
			return RES_OK;
		}

		case GET_SECTOR_SIZE:
			*(WORD*)buff = 512;
			return RES_OK;

		case GET_BLOCK_SIZE:
			*(DWORD*)buff = 1;  /* Single sector erase */
			return RES_OK;
	}

	return RES_PARERR;
}


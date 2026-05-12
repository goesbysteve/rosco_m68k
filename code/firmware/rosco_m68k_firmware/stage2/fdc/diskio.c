/*-----------------------------------------------------------------------*/
/* Low level disk I/O module skeleton for Petit FatFs (C)ChaN, 2014      */
/*-----------------------------------------------------------------------*/

#include <string.h>
#include "./include/diskio.h"
#include "../../stage1/blockdev/include/fd.h"

static FDDevice g_dev;
static BYTE sector_buf[512];
static DWORD cached_sector = 0xFFFFFFFF;  /* sector currently in sector_buf; 0xFFFFFFFF = invalid */

/*-----------------------------------------------------------------------*/
/* Initialize Disk Drive                                                 */
/*-----------------------------------------------------------------------*/

DSTATUS disk_initialize (void)
{
	DSTATUS stat = STA_NOINIT;

	g_dev.unit          = 0;
    g_dev.current_track = 0xFF;   /* 0xFF = unknown, forces recalibrate on first seek */
    g_dev.media_type    = 0;
    g_dev.flags         = 0;

    if (FD_init(0, &g_dev) == FRC_OK && FD_media_detect(&g_dev) >= 0) {
        cached_sector = 0xFFFFFFFF;   /* invalidate cache after init */
        stat = 0;   /* STA_OK */
    }

	return stat;
}



/*-----------------------------------------------------------------------*/
/* Read Partial Sector                                                   */
/*-----------------------------------------------------------------------*/

DRESULT disk_readp (
	BYTE* buff,		/* Pointer to the destination object */
	DWORD sector,	/* Sector number (LBA) */
	UINT offset,	/* Offset in the sector */
	UINT count		/* Byte count (bit15:destination) */
)
{
	if (sector != cached_sector) {
		if (FD_read_sectors(sector_buf, sector, 1, &g_dev) != 1) {  /* returns sectors transferred, not FRC_OK */
			return RES_ERROR;
		}
		cached_sector = sector;
	}
	if (buff) {
		memcpy(buff, sector_buf + offset, count);
	}
	return RES_OK;
}



/*-----------------------------------------------------------------------*/
/* Write Partial Sector                                                  */
/* Not implented as bootloader is read-only */
/*-----------------------------------------------------------------------*/

DRESULT disk_writep (
	const BYTE* buff,	/* Pointer to the data to be written, NULL:Initiate/Finalize write operation */
	DWORD sc		/* Sector number (LBA) or Number of bytes to send */
)
{
	DRESULT res = RES_ERROR;

	return res;
}


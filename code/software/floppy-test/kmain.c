/*
 * Floppy test.
 */

#include <stdint.h>
#include <stdio.h>
#include <basicio.h>

#include "fd.h"

/* Memory-mapped register addresses */
#define FDC_MSR_ADDR    ((volatile uint8_t *)0x00F800CAU)
#define FDC_DOR_ADDR    ((volatile uint8_t *)0x00F800CEU)
#define FDC_DCRDY_ADDR  ((volatile uint8_t *)0x00F800D0U)

/* Register initialisation values */
#define FDC_DOR_INIT    0x0CU

static uint8_t sector_buf[512];
static uint8_t sector_buf2[512];

void kmain(void) {
    FDDevice dev = {0};
    uint8_t msr;

    printf("=== Floppy Phase 1 ===\r\n\r\n");

    printf("Step 1: FD_init(drive=0)...\r\n");
    uint32_t rc = FD_init(0U, &dev);
    printf("  rc=$%08lX  dev.flags=$%02X (fdcrdy=%d)\r\n",
           (unsigned long)rc, (unsigned)dev.flags, (int)(dev.flags & 1U));
    if (rc != 0U) {
        if (rc == 0xFFU) {
            printf("  FAIL: bad MSR -- chip not present or bus floating\r\n");
        } else {
            printf("  FAIL: FC_SPECIFY timeout (FST_RC=$%02lX)\r\n", (unsigned long)rc);
        }
        goto done;
    }
    printf("  FD_init ok\r\n\r\n");

    msr = *FDC_MSR_ADDR;
    printf("Step 2: raw MSR @ $F800CA = $%02X  (RQM=%d DIO=%d NDM=%d BSY=%d)\r\n",
           (unsigned)msr,
           (int)((msr >> 7) & 1U), (int)((msr >> 6) & 1U),
           (int)((msr >> 5) & 1U), (int)((msr >> 4) & 1U));
    if ((msr & 0xC0U) != 0x80U) {
        printf("  WARN: unexpected MSR state\r\n");
    }

    {
        uint8_t dcrdy_raw = *FDC_DCRDY_ADDR;
        uint8_t dcrdy = dcrdy_raw & 0x01U;
        printf("Step 2b: DC/RDY @ $F800D0 raw=$%02X  DC/RDY(D8)=%d\r\n",
               (unsigned)dcrdy_raw, (int)dcrdy);
        if (!dcrdy)
            printf("  WARN: DC/RDY low -- drive not ready\r\n");
    }

    printf("\r\nStep 3: FD_media_detect()...\r\n");
    printf("  (READID-based probe -- keep disk inserted)\r\n");
    {
        int32_t mtype = FD_media_detect(&dev);
        if (mtype < 0) {
            printf("  FAIL: no media detected (rc=%ld)\r\n", (long)mtype);
            goto done;
        }
        printf("  detected: %s (media_type=%ld)\r\n",
               mtype == FDM720 ? "720K" :
               mtype == FDM144 ? "1.44M" : "unknown",
               (long)mtype);
        printf("  dev.media_type=%u  dev.flags=$%02X (fdcrdy=%d -- 0 is normal after detect)\r\n",
               (unsigned)dev.media_type,
               (unsigned)dev.flags, (int)(dev.flags & 1U));
    }

    printf("\r\nStep 4: FD_geom()...\r\n");
    {
        uint32_t geom = FD_geom(&dev);
        printf("  raw=$%08lX  cyls=%lu heads=%lu secs=%lu\r\n",
               (unsigned long)geom,
               (unsigned long)FD_GEOM_CYLS(geom),
               (unsigned long)FD_GEOM_HEADS(geom),
               (unsigned long)FD_GEOM_SECS(geom));
    }

    printf("\r\n=== Floppy Phase 2 ===\r\n\r\n");
    printf("Step 5: FD_read_sectors(LBA=0, count=1)...\r\n");
    printf("  (motor on / RECAL / READ -- no output until done)\r\n");

    uint32_t nread = FD_read_sectors(sector_buf, 0U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d  track=%u\r\n",
           (unsigned long)nread, (int)(dev.flags & 1U),
           (unsigned)dev.current_track);

    if (nread != 1U) {
        printf("  FAIL\r\n");
        goto done;
    }

    printf("  Read ok.  Hex dump of LBA 0:\r\n\r\n");
    for (uint32_t row = 0U; row < 512U; row += 16U) {
        printf("  %04lX: ", (unsigned long)row);
        for (uint32_t col = 0U; col < 16U; col++)
            printf("%02X ", (unsigned)sector_buf[row + col]);
        printf(" ");
        for (uint32_t col = 0U; col < 16U; col++) {
            uint8_t c = sector_buf[row + col];
            printf("%c", (c >= 0x20U && c < 0x7FU) ? (char)c : '.');
        }
        printf("\r\n");
    }

    printf("\r\n=== Floppy Phase 3 ===\r\n\r\n");

    printf("Step 7a: pre-write read of LBA 5...\r\n");
    printf("  (READ in progress)\r\n");

    uint32_t npre = FD_read_sectors(sector_buf2, 5U, 1U, &dev);

    printf("  returned %lu sector(s)\r\n", (unsigned long)npre);
    if (npre == 1U) {
        printf("  LBA5 pre-write $000-$1FF:\r\n");
        for (uint32_t row = 0U; row < 512U; row += 16U) {
            printf("  %04lX: ", (unsigned long)row);
            for (uint32_t col = 0U; col < 16U; col++)
                printf("%02X ", (unsigned)sector_buf2[row + col]);
            printf("\r\n");
        }
    }

    for (uint32_t i = 0U; i < 512U; i++)
        sector_buf[i] = (uint8_t)(i & 0xFFU);
    printf("\r\nStep 7: FD_write_sectors(LBA=5, count=1)...\r\n");
    printf("  Scratch pattern: sector_buf[i] = i & 0xFF (0x00..0xFF repeating)\r\n");
    printf("  WARNING: LBA 5 on the inserted disk will be overwritten.\r\n");
    printf("  (WRITE in progress -- no output until done)\r\n");

    uint32_t nwritten = FD_write_sectors(sector_buf, 5U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d  track=%u\r\n",
           (unsigned long)nwritten, (int)(dev.flags & 1U),
           (unsigned)dev.current_track);

    if (nwritten != 1U) {
        printf("  FAIL\r\n");
        goto done;
    }
    printf("  Write ok.\r\n\r\n");

    printf("Step 8: FD_read_sectors(LBA=5, count=1) read-back...\r\n");
    printf("  (READ in progress -- no output until done)\r\n");

    uint32_t nverify = FD_read_sectors(sector_buf2, 5U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d\r\n",
           (unsigned long)nverify, (int)(dev.flags & 1U));

    if (nverify != 1U) {
        printf("  FAIL\r\n");
        goto done;
    }

    printf("  LBA5 read-back $000-$1FF:\r\n");
    for (uint32_t row = 0U; row < 512U; row += 16U) {
        printf("  %04lX: ", (unsigned long)row);
        for (uint32_t col = 0U; col < 16U; col++)
            printf("%02X ", (unsigned)sector_buf2[row + col]);
        printf("\r\n");
    }

    printf("\r\nStep 9: comparing write pattern vs read-back...\r\n");
    {
        uint32_t mismatches2 = 0U;
        for (uint32_t i = 0U; i < 512U; i++) {
            if (sector_buf[i] != sector_buf2[i]) {
                if (mismatches2 < 8U) {
                    printf("  MISMATCH @ $%03lX: wrote $%02X got $%02X\r\n",
                           (unsigned long)i,
                           (unsigned)sector_buf[i],
                           (unsigned)sector_buf2[i]);
                }
                mismatches2++;
            }
        }
        if (mismatches2 == 0U)
            printf("  Write verified -- 512/512 bytes match.\r\n");
        else
            printf("  FAIL: %lu byte(s) differ.\r\n", (unsigned long)mismatches2);
    }


done:
    /* Motor auto-off is handled by FD_motor_poll() in TICK_HANDLER (~3s).   */
    /* Hold here so the tick ISR has time to cut the motor before warm boot.  */
    printf("\r\nDone (motor will auto-off in ~3s).\r\n");
    printf("Press any key to exit...\r\n");
    inputchar();
}

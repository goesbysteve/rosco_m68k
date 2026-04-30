/*
 * Floppy test.
 */

#include <stdint.h>
#include <stdio.h>

#include "fd.h"

/* Memory-mapped register addresses */
#define FDC_MSR_ADDR    ((volatile uint8_t *)0x00F800CAU)
#define FDC_DOR_ADDR    ((volatile uint8_t *)0x00F800CEU)
#define FDC_DCRDY_ADDR  ((volatile uint8_t *)0x00F800D0U)

/* ROM firmware BSS addresses (stage1.elf WITH_FDC=true, stable across driver edits) */
#define FW_FST_RC       ((volatile uint8_t  *)0x00001843U)
#define FW_FRB_LEN      ((volatile uint8_t  *)0x00001845U)
#define FW_FRB_ST0      ((volatile uint8_t  *)0x00001846U)
#define FW_FRB_ST1      ((volatile uint8_t  *)0x00001847U)
#define FW_FRB_ST2      ((volatile uint8_t  *)0x00001848U)
#define FW_FRB_C        ((volatile uint8_t  *)0x00001849U)
#define FW_FRB_H        ((volatile uint8_t  *)0x0000184AU)
#define FW_FRB_R        ((volatile uint8_t  *)0x0000184BU)
#define FW_FRB_N        ((volatile uint8_t  *)0x0000184CU)
#define FW_FCD_W_SECSZ  ((volatile uint16_t *)0x00001856U)
#define FW_FD_DSKBUF    ((volatile uint32_t *)0x00001864U)
#define FW_FXR_WR_COUNT ((volatile uint32_t *)0x0000186AU)

/* Register initialisation values */
#define FDC_DOR_INIT    0x0CU

static void dump_fdc_state(void) {
    uint8_t rc  = *FW_FST_RC;
    uint8_t len = *FW_FRB_LEN;
    printf("  FST_RC=$%02X  FRB_LEN=%u  FCD_W_SECSZ=%u  FD_DSKBUF=$%08lX\r\n",
           (unsigned)rc, (unsigned)len,
           (unsigned)*FW_FCD_W_SECSZ,
           (unsigned long)*FW_FD_DSKBUF);
    if (len >= 1U) {
        uint8_t st0 = *FW_FRB_ST0;
        printf("  ST0=$%02X  IC=%u HD=%u DS=%u\r\n",
               (unsigned)st0,
               (unsigned)((st0 >> 6) & 0x3U),
               (unsigned)((st0 >> 2) & 0x1U),
               (unsigned)( st0       & 0x3U));
    }
    if (len >= 2U) {
        uint8_t st1 = *FW_FRB_ST1;
        printf("  ST1=$%02X  EN=%u DE=%u OR=%u ND=%u NW=%u MA=%u\r\n",
               (unsigned)st1,
               (unsigned)((st1 >> 7) & 1U),
               (unsigned)((st1 >> 5) & 1U),
               (unsigned)((st1 >> 4) & 1U),
               (unsigned)((st1 >> 2) & 1U),
               (unsigned)((st1 >> 1) & 1U),
               (unsigned)( st1       & 1U));
    }
    if (len >= 3U)
        printf("  ST2=$%02X\r\n", (unsigned)*FW_FRB_ST2);
    if (len >= 7U)
        printf("  C=%u H=%u R=%u N=%u\r\n",
               (unsigned)*FW_FRB_C,
               (unsigned)*FW_FRB_H,
               (unsigned)*FW_FRB_R,
               (unsigned)*FW_FRB_N);
}

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

    printf("\r\n=== Floppy Phase 2 ===\r\n\r\n");
    printf("Step 3: FD_read_sectors(LBA=0, count=1)...\r\n");
    printf("  media_type=%u (%s)\r\n",
           (unsigned)dev.media_type,
           dev.media_type == 0U ? "720K" : "1.44M");
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

    printf("\r\nStep 4: re-read LBA 0 for consistency check...\r\n");

    uint32_t nread2 = FD_read_sectors(sector_buf2, 0U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d\r\n",
           (unsigned long)nread2, (int)(dev.flags & 1U));

    if (nread2 != 1U) {
        printf("  FAIL\r\n");
        goto done;
    }

    {
        uint32_t mismatches = 0U;
        for (uint32_t i = 0U; i < 512U; i++) {
            if (sector_buf[i] != sector_buf2[i]) {
                if (mismatches < 8U) {
                    printf("  MISMATCH @ $%03lX: $%02X vs $%02X\r\n",
                           (unsigned long)i,
                           (unsigned)sector_buf[i],
                           (unsigned)sector_buf2[i]);
                }
                mismatches++;
            }
        }
        if (mismatches == 0U)
            printf("  Both reads identical -- 512/512 bytes match.\r\n");
        else
            printf("  FAIL: %lu byte(s) differ.\r\n", (unsigned long)mismatches);
    }

    printf("\r\n=== Floppy Phase 3 ===\r\n\r\n");

    printf("Step 5a: pre-write read of LBA 5...\r\n");
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
    printf("\r\nStep 5: FD_write_sectors(LBA=5, count=1)...\r\n");
    printf("  Scratch pattern: sector_buf[i] = i & 0xFF (0x00..0xFF repeating)\r\n");
    printf("  WARNING: LBA 5 on the inserted disk will be overwritten.\r\n");
    printf("  (WRITE in progress -- no output until done)\r\n");

    uint32_t nwritten = FD_write_sectors(sector_buf, 5U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d  track=%u\r\n",
           (unsigned long)nwritten, (int)(dev.flags & 1U),
           (unsigned)dev.current_track);
    dump_fdc_state();
    printf("  FXR_WR_COUNT=%lu\r\n", (unsigned long)*FW_FXR_WR_COUNT);

    if (nwritten != 1U) {
        printf("  FAIL\r\n");
        goto done;
    }
    printf("  Write ok.\r\n\r\n");

    printf("Step 6: FD_read_sectors(LBA=5, count=1) read-back...\r\n");
    printf("  (READ in progress -- no output until done)\r\n");

    uint32_t nverify = FD_read_sectors(sector_buf2, 5U, 1U, &dev);

    printf("  returned %lu sector(s)  fdcrdy=%d\r\n",
           (unsigned long)nverify, (int)(dev.flags & 1U));
    dump_fdc_state();

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

    printf("\r\nStep 7: comparing write pattern vs read-back...\r\n");
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
    *FDC_DOR_ADDR = FDC_DOR_INIT;
    printf("\r\nMotor off.\r\n");
}
; TRAP wrappers for firmware floppy blockdev functions.

FD_check_support::
    move.l  #20,D0
    trap    #13
    cmp.l   #$1234FEDC,D0
    beq.s   .ok
    move.l  #0,D0
    bra.s   .done
.ok
    move.l  #1,D0
.done
    rts

; uint32_t FD_init(uint32_t drive, void *dev)
FD_init::
    movem.l A0-A1/D1,-(A7)
    move.l  (16,A7),D1
    move.l  (20,A7),A1
    move.l  #21,D0
    trap    #13
    movem.l (A7)+,A0-A1/D1
    rts

; uint32_t FD_read_sectors(uint8_t *buf, uint32_t lba, uint32_t count, void *dev)
FD_read_sectors::
    movem.l A0-A2/D1-D2,-(A7)
    move.l  (24,A7),A2
    move.l  (28,A7),D1
    move.l  (32,A7),D2
    move.l  (36,A7),A1
    move.l  #22,D0
    trap    #13
    movem.l (A7)+,A0-A2/D1-D2
    rts

; uint32_t FD_write_sectors(uint8_t *buf, uint32_t lba, uint32_t count, void *dev)
FD_write_sectors::
    movem.l A0-A2/D1-D2,-(A7)
    move.l  (24,A7),A2
    move.l  (28,A7),D1
    move.l  (32,A7),D2
    move.l  (36,A7),A1
    move.l  #23,D0
    trap    #13
    movem.l (A7)+,A0-A2/D1-D2
    rts
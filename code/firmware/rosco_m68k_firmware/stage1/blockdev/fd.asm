;------------------------------------------------------------
;                                  ___ ___ _
;  ___ ___ ___ ___ ___       _____|  _| . | |_
; |  _| . |_ -|  _| . |     |     | . | . | '_|
; |_| |___|___|___|___|_____|_|_|_|___|___|_,_|
;                     |_____|       firmware v2
;------------------------------------------------------------
; Copyright (c) 2026 Steve Jordan & Contributors
; MIT License
;
; WD37C65 floppy driver -- pure 68000 assembly
; Translated from RomWBW fd.asm (FDMODE_SMB_WD) to 68000.
; No C code, no debug prints during FDC interaction.
;
; Exported symbols:
;   FD_init          (D1=drive 0/1, A1=FDDevice*)  -> D0=0 ok
;   FD_read_sectors  (A2=buf, D1=LBA, D2=count, A1=FDDevice*) -> D0=count
;   FD_write_sectors (A2=buf, D1=LBA, D2=count, A1=FDDevice*) -> D0=count
;
; FDDevice struct offsets (4 bytes, defined in fd.h):
;   FDD_UNIT   equ 0   ; uint8 -- drive number 0 or 1
;   FDD_TRACK  equ 1   ; uint8 -- current track, $FF=unknown/needs recal
;   FDD_MEDIA  equ 2   ; uint8 -- media type: 0=720K, 1=1.44M
;   FDD_FLAGS  equ 3   ; uint8 -- bit0=fdcrdy
;
; Register map (from PLD / fd.h):
;   $F800C8  CCR write  (LDCR -- data rate control)
;   $F800CA  MSR read
;   $F800CC  DATA read/write
;   $F800CE  DOR write (LDOR) / TC read (DACK) -- SAME address
;
;------------------------------------------------------------

                include "../../../shared/rosco_m68k_public.asm"
                include "fd_config.inc"

; ============================================================
; Hardware register addresses
; ============================================================
FDC_CCR         equ     $00F800C8       ; LDCR -- write data rate
FDC_MSR         equ     $00F800CA       ; main status register (read)
FDC_DATA        equ     $00F800CC       ; data register (read/write)
FDC_DOR         equ     $00F800CE       ; DOR write / TC read

; ============================================================
; MSR bit patterns (upper nibble masks)
; ============================================================
MSR_RQM_DIO     equ     $C0             ; mask: RQM + DIO
MSR_CMD_READY   equ     $80             ; RQM=1, DIO=0 -- ready for cmd byte
MSR_RES_READY   equ     $C0             ; RQM=1, DIO=1, NDM=0 -- result byte / idle
MSR_EXEC_RD     equ     $F0             ; RQM=1,DIO=1,NDM=1,CB=1 -- read exec byte ready
MSR_EXEC_WR     equ     $B0             ; RQM=1,DIO=0,NDM=1,CB=1 -- write exec byte ready
MSR_RESULT_CB   equ     $D0             ; RQM=1,DIO=1,CB=1,NDM=0 -- result ready

; ============================================================
; DOR bits (PC AT mode)
; ============================================================
DOR_NRESET      equ     $04             ; soft reset inactive
DOR_DMAEN       equ     $08             ; DMA enable (required for PC AT)
DOR_MOTOR0      equ     $10             ; motor on drive 0
DOR_MOTOR1      equ     $20             ; motor on drive 1
DOR_INIT        equ     DOR_NRESET|DOR_DMAEN    ; $0C

; ============================================================
; FDC command codes (fd.asm CFD_*)
; ============================================================
CFD_READ        equ     $06
CFD_WRITE       equ     $05
CFD_READID      equ     $0A

DOP_READ        equ     0
DOP_WRITE       equ     1
DOP_READID      equ     3
CFD_RECAL       equ     $07
CFD_SENSEINT    equ     $08
CFD_SPECIFY     equ     $03
CFD_SEEK        equ     $0F
CFD_DRVSTAT     equ     $04             ; drive status -> ST3

; Modifiers OR'd into byte 0
CFD_MFM         equ     $40             ; MFM mode
CFD_MT          equ     $80             ; multitrack (we don't use)
CFD_SK          equ     $20             ; skip deleted (we don't use)

; ============================================================
; Result codes (fd.asm FRC_*)
; ============================================================
FRC_OK          equ     0
FRC_ABORT       equ     -4
FRC_ABTERM      equ     -8
FRC_INVCMD      equ     -9
FRC_DSKCHG      equ     -10
FRC_ENDCYL      equ     -11
FRC_DATAERR     equ     -12
FRC_OVERRUN     equ     -13
FRC_NODATA      equ     -14
FRC_NOTWRIT     equ     -15
FRC_MISADR      equ     -16
FRC_TOFDCRDY    equ     -17
FRC_TOSNDCMD    equ     -18
FRC_TOGETRES    equ     -19
FRC_TOEXEC      equ     -20

; ============================================================
; FDDevice struct field offsets (matches fd.h)
; ============================================================
FDD_UNIT        equ     0
FDD_TRACK       equ     1
FDD_MEDIA       equ     2
FDD_FLAGS       equ     3

FDD_FLAG_FDCRDY equ     $01

; ============================================================
; Fixed media parameters
; N=2 -> 512 bytes/sector, DTL=FF (unused when N!=0)
; ============================================================
FCD_N           equ     2
FCD_DTL         equ     $FF

; ============================================================
; Time-based delay constants -- all derived from FD_CPU_MHZ
; (set in fd_config.inc, default 10).
;
; FDC_DELAY inner loop: DBRA, ~4 cycles/iter effective with ROM
; wait states.  Target ~12us.  count = 3*MHz - 1 = 29 @ 10MHz.
FDC_DELAY_COUNT equ     (3*FD_CPU_MHZ)-1
;
; Motor spinup: 500ms. SUBQ.L+BNE.S ~10 cycles/iter = 1us @ 10MHz.
MOTOR_SPINUP    equ     (500000*FD_CPU_MHZ/10)
;
; FC_RESETFDC: DOR reset pulse width ~2ms (minimum is nanoseconds; 2ms is ample).
FDC_RESET_WIDTH equ     (2000*FD_CPU_MHZ/10)
;
; FC_RESETFDC: post-reset FDC settling ~4ms (spec ~1.5ms; 4ms is safe).
FDC_RESET_SETTLE equ    (4000*FD_CPU_MHZ/10)
;
; FC_MOTORON: CCR (data-rate) PLL settle ~15ms (VCO typically locks in 1-5ms).
FDC_CCR_SETTLE  equ     (15000*FD_CPU_MHZ/10)

; ============================================================
; Timeout loop counts (fd.asm patterns)
; B = 256 inner iterations for MSR poll
; Outer loops match fd.asm $1000 for FD_WTSEEK
; ============================================================
; FD_WTSEEK poll budget: must cover worst-case RECAL (80 tracks, SRT=13 -> 3ms/step)
; 80 x 3ms = 240ms. FDC_DELAY ~12us per iteration (constant regardless of MHz).
; 240ms / 12us = 20000; use 25000 for margin.
WTSEEK_OUTER    equ     25000

; ============================================================
; section .rodata -- media configuration ROM tables
; Layout matches fd.asm FCD block: NUMCYL,NUMHD,NUMSEC,SOT,
; SC,SECSZ(word),GPL,GPLF,SRTHUT,HLTND,DOR,DCR
; FCD_LEN = 14 bytes (all fields through DCR)
; ============================================================

                section .rodata

; FCD_TBL -- indexed by media type (0=720K, 1=1.44M, 2=360K, 3=1.2M)
; Each entry is 4 bytes: dc.l address
; Accessed as: RLCA/RLCA in fd.asm -> A = media*4 -> index FCD_TBL
FCD_TBL:
                dc.l    FCD_PC720
                dc.l    FCD_PC144
                dc.l    FCD_PC360
                dc.l    FCD_PC120

; 720K 3.5" DS/DD  250Kbps (CCR=01)
; fd.asm FCD_PC720:
;   SOT=1, NUMSEC=SC=9, SECSZ=512, GPL=0x2A, GPLF=0x50
;   SRTHUT=(13<<4)|0=0xD0, HLTND=(4<<1)|1=0x09
;   DOR=DOR_INIT=$0C, DCR=0x01 (250K)
FCD_PC720:
                dc.b    80          ; NUMCYL
                dc.b    2           ; NUMHD
                dc.b    9           ; NUMSEC
                dc.b    1           ; SOT (start of track, first sector number)
                dc.b    9           ; SC (sector count = EOT)
                dc.b    0           ; pad (align SECSZ to even offset 6)
                dc.w    512         ; SECSZ
                dc.b    $2A         ; GPL (gap length R/W)
                dc.b    $50         ; GPLF (gap length format)
                dc.b    $D0         ; SRTHUT: SRT=(13<<4)|HUT=0
                dc.b    $09         ; HLTND: HLT=(4<<1)|ND=1
                dc.b    DOR_INIT    ; DOR value
                dc.b    $01         ; DCR (CCR) value: 250Kbps

; 1.44M 3.5" DS/HD  500Kbps (CCR=00)
; fd.asm FCD_PC144:
;   NUMSEC=SC=18, GPL=0x1B, GPLF=0x6C
;   SRTHUT=(13<<4)|0=0xD0, HLTND=(8<<1)|1=0x11
;   DOR=DOR_INIT=$0C, DCR=0x00 (500K)
FCD_PC144:
                dc.b    80          ; NUMCYL
                dc.b    2           ; NUMHD
                dc.b    18          ; NUMSEC
                dc.b    1           ; SOT
                dc.b    18          ; SC
                dc.b    0           ; pad
                dc.w    512         ; SECSZ
                dc.b    $1B         ; GPL
                dc.b    $6C         ; GPLF
                dc.b    $D0         ; SRTHUT
                dc.b    $11         ; HLTND: HLT=(8<<1)|ND=1
                dc.b    DOR_INIT    ; DOR value
                dc.b    $00         ; DCR (CCR) value: 500Kbps

; 360K 5.25" DS/DD  250Kbps (CCR=01)
; FCD_PC360:
;   SOT=1, NUMSEC=SC=9, SECSZ=512, GPL=0x2A, GPLF=0x50
;   SRTHUT=(13<<4)|0=0xD0, HLTND=(4<<1)|1=0x09
;   DOR=DOR_INIT=$0C, DCR=0x01 (250K)
FCD_PC360:
                dc.b    40          ; NUMCYL
                dc.b    2           ; NUMHD
                dc.b    9           ; NUMSEC
                dc.b    1           ; SOT
                dc.b    9           ; SC
                dc.b    0           ; pad
                dc.w    512         ; SECSZ
                dc.b    $2A         ; GPL
                dc.b    $50         ; GPLF
                dc.b    $D0         ; SRTHUT: SRT=(13<<4)|HUT=0
                dc.b    $09         ; HLTND: HLT=(4<<1)|ND=1
                dc.b    DOR_INIT    ; DOR value
                dc.b    $01         ; DCR (CCR) value: 250Kbps

; 1.2M 5.25" DS/HD  500Kbps (CCR=00)
; FCD_PC120:
;   NUMSEC=SC=15, GPL=0x1B, GPLF=0x54
;   SRTHUT=(10<<4)|0=0xA0, HLTND=(8<<1)|1=0x11
;   DOR=DOR_INIT=$0C, DCR=0x00 (500K)
FCD_PC120:
                dc.b    80          ; NUMCYL
                dc.b    2           ; NUMHD
                dc.b    15          ; NUMSEC
                dc.b    1           ; SOT
                dc.b    15          ; SC
                dc.b    0           ; pad
                dc.w    512         ; SECSZ
                dc.b    $1B         ; GPL
                dc.b    $54         ; GPLF
                dc.b    $A0         ; SRTHUT: SRT=(10<<4)|HUT=0
                dc.b    $11         ; HLTND: HLT=(8<<1)|ND=1
                dc.b    DOR_INIT    ; DOR value
                dc.b    $00         ; DCR (CCR) value: 500Kbps

; FCD_LEN must be 14 -- checked implicitly by layout

; ============================================================
; FCD field offsets within media config block (fd.asm FCD_*)
; ============================================================
FCD_NUMCYL      equ     0
FCD_NUMHD       equ     1
FCD_NUMSEC      equ     2
FCD_SOT         equ     3
FCD_SC          equ     4           ; also FCD_EOT
                                    ; byte 5 = pad
FCD_SECSZ       equ     6           ; word (at even offset)
FCD_GPL         equ     8
FCD_GPLF        equ     9
FCD_SRTHUT      equ     10
FCD_HLTND       equ     11
FCD_DOR_VAL     equ     12
FCD_DCR_VAL     equ     13
FCD_LEN         equ     14

; ============================================================
; section .bss -- driver working state
; All transient/working state is global
; Per-unit persistent state is in the caller-allocated FDDevice struct
; ============================================================

                section .bss

; ----- Command phase buffer (fd.asm FCP_*) ---
FCP_CMD:        ds.b    1           ; command code (without modifier bits)
FCP_LEN:        ds.b    1           ; number of bytes in FCP_BUF
FCP_BUF:                            ; the 9 command bytes
FCP_CMDX:       ds.b    1           ; byte 0: cmd | MFM etc.
FCP_HDSDS:      ds.b    1           ; byte 1: HDS|DS
FCP_C:          ds.b    1           ; byte 2: cylinder
FCP_H:          ds.b    1           ; byte 3: head
FCP_R:          ds.b    1           ; byte 4: record (sector)
FCP_N:          ds.b    1           ; byte 5: sector size code
FCP_EOT:        ds.b    1           ; byte 6: end of track
FCP_GPL:        ds.b    1           ; byte 7: gap length
FCP_DTL:        ds.b    1           ; byte 8: data length

; ----- FDC status (fd.asm FST_*) ---
FST_RC:         ds.b    1           ; result code
FST_DOR:        ds.b    1           ; shadow of DOR register
FST_IDLECNT:    ds.w    1           ; idle countdown (ticks); 0 = disabled/off

; ----- Results buffer (fd.asm FRB_*) -- 7 bytes max ---
FRB_LEN:        ds.b    1           ; number of result bytes received
FRB:                                ; result buffer start
FRB_ST0:        ds.b    1
FRB_ST3         equ     FRB_ST0         ; alias: DRVSTAT result lands here
FRB_ST1:        ds.b    1
FRB_ST2:        ds.b    1
FRB_C:          ds.b    1
FRB_H:          ds.b    1
FRB_R:          ds.b    1
FRB_N:          ds.b    1
FRB_SIZ        equ     7

; ----- FDC working copy of media config (fd.asm FCD) ---
; Copied from ROM table before each operation.
; Must be word-aligned so FCD_W_SECSZ (ds.w at offset +6) and
; the dynamic byte fields accessed as word operands stay on even addresses.
                align   2
FCD:
FCD_W_NUMCYL:   ds.b    1
FCD_W_NUMHD:    ds.b    1
FCD_W_NUMSEC:   ds.b    1
FCD_W_SOT:      ds.b    1
FCD_W_SC:       ds.b    1
FCD_W_PAD:      ds.b    1           ; pad to align SECSZ
FCD_W_SECSZ:    ds.w    1
FCD_W_GPL:      ds.b    1
FCD_W_GPLF:     ds.b    1
FCD_W_SRTHUT:   ds.b    1
FCD_W_HLTND:    ds.b    1
FCD_W_DOR:      ds.b    1
FCD_W_DCR:      ds.b    1

; ----- Dynamic FCD fields (fd.asm: after FCD_LEN) ---
FCD_DS:         ds.b    1           ; drive select (0 or 1)
FCD_C_PARAM:    ds.b    1           ; cylinder parameter
FCD_H_PARAM:    ds.b    1           ; head parameter
FCD_R_PARAM:    ds.b    1           ; record (sector) parameter
FCD_DOP:        ds.b    1           ; current operation: 0=read,1=write,3=readid

; ----- Disk buffer pointer (fd.asm FD_DSKBUF) ---
FD_DSKBUF:      ds.l    1           ; pointer to sector data buffer

; ----- Receive-byte counter (temp in FOP_RES) ---
FOP_RESCNT:     ds.b    1

; ----- Write byte counter (diagnostic: bytes sent to FDC in FXR_WRITE) ---
FXR_WR_COUNT:   ds.l    1

; ============================================================
; section .text -- driver code
; ============================================================

                section .text

;------------------------------------------------------------
; Delay ~12us between MSR reads (fd.asm DELAY macro).
; Loop count = FDC_DELAY_COUNT = 3*FD_CPU_MHZ-1 (29 @ 10MHz).
; Trashes nothing (D0 saved/restored).
;------------------------------------------------------------
FDC_DELAY:
                move.l  D0,-(sp)
                move.w  #FDC_DELAY_COUNT,D0
.dly:           dbra    D0,.dly
                move.l  (sp)+,D0
                rts

;------------------------------------------------------------
; FC_RESETFDC -- hardware reset
; Pulses DOR reset low then restores the previous DOR value,
; preserving motor state across probe attempts.
; Trashes D0.
;------------------------------------------------------------
FC_RESETFDC:
                ; Save current DOR (including motor-on bits) on stack
                move.b  FST_DOR,D0
                move.l  D0,-(sp)

                ; Assert reset: write 0x00 to DOR
                clr.b   FST_DOR
                move.b  #0,$F800CE

                ; Reset pulse width ~2ms (FDC_RESET_WIDTH)
                move.l  #FDC_RESET_WIDTH,D0
.rst_dly:       subq.l  #1,D0
                bne.s   .rst_dly

                ; Deassert reset: restore PREVIOUS DOR (motor state preserved)
                move.l  (sp)+,D0
                move.b  D0,FST_DOR
                move.b  D0,$F800CE

                ; Post-reset FDC settling ~4ms (FDC_RESET_SETTLE)
                move.l  #FDC_RESET_SETTLE,D0
.rst_dly2:      subq.l  #1,D0
                bne.s   .rst_dly2

                rts

;------------------------------------------------------------
; FC_PULSETC -- pulse Terminal Count (fd.asm FC_PULSETC)
; In SMB_WD mode: IN A,(FDC_TC) -- read from TC address.
; Trashes D0.
;------------------------------------------------------------
FC_PULSETC:
                move.b  $F800CE,D0      ; read DOR/TC address = pulse DACK
                rts

;------------------------------------------------------------
; FC_MOTORON -- enable motor and select drive (fd.asm FC_MOTORON)
; On entry: FCD_DS holds drive number (0 or 1).
; Writes DCR (CCR), then builds and writes DOR with motor bit.
; If motor was previously off: 500ms spinup delay.
; Arms FST_IDLECNT unconditionally -- every motor-on resets the idle
; timer, so back-to-back operations naturally extend the timeout.
; Trashes D0/D1.
;------------------------------------------------------------
FC_MOTORON:
                ; Arm idle motor-off countdown. Done here (not at operation
                ; completion) so every motor-on path is covered, including
                ; FD_media_detect probe calls.
                move.w  #MOTOR_IDLE_TICKS,FST_IDLECNT
                ; Write data rate to CCR (FDC_DCR = FDC_CCR = $F800C8)
                move.b  FCD_W_DCR,D0
                move.b  D0,$F800C8

                ; PLL settle delay after CCR rate change (~15ms, FDC_CCR_SETTLE).
                ; The WD37C65 data separator needs time to switch bit-cell
                ; windows; without this the first command at the new rate
                ; can time out or mis-clock on the first probe attempt.
                movem.l D0,-(sp)
                move.l  #FDC_CCR_SETTLE,D0
.moton_ccr_dly: subq.l  #1,D0
                bne.s   .moton_ccr_dly
                movem.l (sp)+,D0

                ; Build new DOR: DOR_INIT | motor bit | drive select
                move.b  #DOR_INIT,D1        ; base: NRESET|DMAEN
                move.b  FCD_DS,D0           ; drive select (0 or 1)
                and.b   #$03,D0
                or.b    D0,D1               ; DS bits
                ; motor bit: drive 0 = bit4, drive 1 = bit5
                move.b  FCD_DS,D0
                tst.b   D0
                bne.s   .moton_d1
                or.b    #DOR_MOTOR0,D1
                bra.s   .moton_write
.moton_d1:
                or.b    #DOR_MOTOR1,D1

.moton_write:
                ; Check if motor was already on
                move.b  FST_DOR,D0
                cmp.b   D1,D0
                beq.s   .moton_done         ; motor was on -- no spinup needed

                ; Motor was off -- write DOR and spinup delay
                move.b  D1,FST_DOR
                move.b  D1,$F800CE

                ; 500ms spinup delay (MOTOR_SPINUP)
                move.l  #MOTOR_SPINUP,D0
.spinup:        subq.l  #1,D0
                bne.s   .spinup

.moton_done:
                rts

;------------------------------------------------------------
; FC_MOTOROFF -- cut motor (fd.asm FC_MOTOROFF)
; Trashes D0.
;------------------------------------------------------------
FC_MOTOROFF:
                move.b  #DOR_INIT,FST_DOR
                move.b  #DOR_INIT,$F800CE
                clr.w   FST_IDLECNT         ; stop idle countdown
                rts

;------------------------------------------------------------
; FD_motor_poll -- idle motor-off countdown tick
; Call once per tick (100 Hz) from the MFP Timer C ISR chain
; or from a main-loop idle handler.
; Decrements FST_IDLECNT; cuts the motor when it reaches zero.
; ISR-safe: saves and restores D0; trashes nothing else.
;------------------------------------------------------------
FD_motor_poll::
                move.l  D0,-(sp)
                move.w  FST_IDLECNT,D0
                beq.s   .mpoll_done         ; 0 = disabled or already off
                subq.w  #1,D0
                move.w  D0,FST_IDLECNT
                bne.s   .mpoll_done         ; not yet expired
                bsr     FC_MOTOROFF         ; expired -- cut motor
.mpoll_done:
                move.l  (sp)+,D0
                rts

;------------------------------------------------------------
; FC_SETUPCMD -- fill FCP_BUF byte 0 (cmd) and byte 1 (HDS|DS)
; On entry: D0 = raw cmd byte (command | desired modifier bits
;           in the upper 3 bits, as per fd.asm FC_SETUPCMD).
; fd.asm: AND 5FH masks MT=0,MFM=1,SK=0 with cmd bits.
; Trashes D0/D1, A0.
; On exit: A0 points to FCP_BUF+2 (ready for FC_SETUPIO etc.)
;------------------------------------------------------------
FC_SETUPCMD:
                lea.l   FCP_BUF,A0
                and.b   #$5F,D0             ; MT=0, MFM=1, SK=0, keep low 5 cmd bits
                move.b  D0,(A0)+            ; FCP_CMDX
                and.b   #$1F,D0
                move.b  D0,FCP_CMD          ; save clean command code

                ; byte 1: (HDS<<2) | DS
                move.b  FCD_H_PARAM,D0
                and.b   #$01,D0
                lsl.b   #2,D0               ; shift head to bit2
                move.b  FCD_DS,D1
                and.b   #$03,D1
                or.b    D1,D0
                move.b  D0,(A0)+            ; FCP_HDSDS

                move.b  #2,FCP_LEN
                rts

;------------------------------------------------------------
; FC_SETUPIO -- fill all 9 command bytes for READ/WRITE
; Calls FC_SETUPCMD first, then appends C,H,R,N,EOT,GPL,DTL.
; On entry: D0 = cmd byte (as for FC_SETUPCMD).
; Trashes D0/D1, A0.
;------------------------------------------------------------
FC_SETUPIO:
                bsr   FC_SETUPCMD         ; sets A0 = FCP_BUF+2

                move.b  FCD_C_PARAM,D0
                move.b  D0,(A0)+            ; C

                move.b  FCD_H_PARAM,D0
                move.b  D0,(A0)+            ; H

                move.b  FCD_R_PARAM,D0
                move.b  D0,(A0)+            ; R

                move.b  #FCD_N,D0
                move.b  D0,(A0)+            ; N = 2 (512 bytes)

                move.b  FCD_W_SC,D0
                move.b  D0,(A0)+            ; EOT = SC (last sector)

                move.b  FCD_W_GPL,D0
                move.b  D0,(A0)+            ; GPL

                move.b  #FCD_DTL,D0
                move.b  D0,(A0)+            ; DTL = $FF

                move.b  #9,FCP_LEN
                rts

;------------------------------------------------------------
; FC_SETUPSPECIFY -- build SPECIFY command bytes
; fd.asm FC_SETUPSPECIFY: calls FC_SETUPCMD then backs up 1
; byte, overwrites with SRTHUT, then writes HLTND.
; Result is 3 bytes: [CFD_SPECIFY, SRTHUT, HLTND]
; Trashes D0/D1, A0.
;------------------------------------------------------------
FC_SETUPSPECIFY:
                move.b  #CFD_SPECIFY,D0
                bsr   FC_SETUPCMD         ; A0 = FCP_BUF+2

                ; Back up: overwrite HDSDS slot with SRTHUT
                subq.l  #1,A0               ; A0 = FCP_BUF+1
                move.b  FCD_W_SRTHUT,(A0)+  ; byte 1 = SRTHUT
                move.b  FCD_W_HLTND,(A0)+   ; byte 2 = HLTND

                move.b  #3,FCP_LEN
                rts

;------------------------------------------------------------
; FC_SETUPSEEK -- build SEEK command bytes (3 bytes)
; fd.asm FC_SETUPSEEK: FC_SETUPCMD + NCN byte.
; Trashes D0/D1, A0.
;------------------------------------------------------------
FC_SETUPSEEK:
                move.b  #CFD_SEEK,D0
                bsr   FC_SETUPCMD         ; A0 = FCP_BUF+2

                move.b  FCD_C_PARAM,(A0)+   ; NCN = desired cylinder

                move.b  #3,FCP_LEN
                rts

;============================================================
; FOP -- main FDC state machine (fd.asm FOP)
;
; Performs: CLR phase -> CMD phase -> EXEC phase -> RESULT phase
;            -> EVAL phase -> return via FST_RC
;
; On entry: FCP_BUF and FCP_LEN are already set up.
; Returns nothing; caller reads FST_RC.
;============================================================
FOP:
                clr.b   FRB_LEN
                move.b  #FRC_OK,FST_RC

;------------------------------------------------------------
; FOP_CLR1 -- drain any stale result bytes (fd.asm FOP_CLR1)
; AND 0xC0 / CP 0xC0: both RQM and DIO set = FDC wants to push bytes.
;------------------------------------------------------------
FOP_CLR1:
                move.w  #255,D1             ; D1 = loop counter (B in fd.asm)
.clr_loop:
                bsr     FDC_DELAY
                move.b  $F800CA,D0          ; read MSR
                and.b   #$C0,D0
                cmp.b   #$C0,D0
                bne.s   FOP_CMD1            ; no pending byte -> go to command phase
                move.b  $F800CC,D0          ; read and discard
                dbra    D1,.clr_loop
                ; loop exhausted -- timeout
                move.b  #FRC_TOFDCRDY,FST_RC
                bra     FOP_EXIT

;------------------------------------------------------------
; FOP_CMD1/CMD2 -- send command bytes (fd.asm FOP_CMD1/CMD2/CMD4/CMD6)
;------------------------------------------------------------
FOP_CMD1:
                lea.l   FCP_BUF,A0
                move.b  FCP_LEN,D2          ; D2 = bytes left to send

FOP_CMD2:
                move.w  #255,D1             ; B = 256 inner iterations

FOP_CMD4:
                bsr     FDC_DELAY
                move.b  $F800CA,D0          ; MSR
                and.b   #$C0,D0
                cmp.b   #$80,D0             ; RQM=1,DIO=0 -- ready for byte?
                beq.s   FOP_CMD6
                cmp.b   #$C0,D0             ; RQM=1,DIO=1 -- premature results?
                beq.s   FOP_RES
                dbra    D1,FOP_CMD4
                move.b  #FRC_TOSNDCMD,FST_RC
                bra     FOP_EXIT

FOP_CMD6:
                move.b  (A0)+,$F800CC       ; write command byte
                subq.b  #1,D2
                bne.s   FOP_CMD2

;------------------------------------------------------------
; FOP_X1 -- execution phase dispatch (fd.asm FOP_X1)
;------------------------------------------------------------
FOP_X1:
                ; Push return address to FOP_RES so exec routines
                ; fall through to result phase on completion.
                lea.l   FOP_RES,A0
                move.l  A0,-(sp)

                move.b  FCP_CMD,D0
                cmp.b   #CFD_READ,D0
                beq.s   .do_read
                cmp.b   #CFD_WRITE,D0
                beq.s   .do_write
                cmp.b   #CFD_READID,D0
                beq.s   .do_readid
                ; all other commands (SPECIFY,RECAL,SEEK,SENSEINT)
                ; have no execution phase -- fall straight to FOP_RES
                rts                         ; RET pops FOP_RES off stack

.do_read:
                bsr     FXR_READ
                rts

.do_write:
                bsr     FXR_WRITE
                rts

.do_readid:
                bsr     FXR_NULL
                rts

;------------------------------------------------------------
; FOP_RES -- collect result bytes (fd.asm FOP_RES/RES0/RES1/RES2)
; Reads until MSR = $80 (nothing left) or buffer full.
;------------------------------------------------------------
FOP_RES:
                lea.l   FRB,A0
                clr.b   FOP_RESCNT          ; D counts bytes received

FOP_RES0:
                move.w  #255,D1             ; B = 256 iterations

FOP_RES1:
                bsr     FDC_DELAY
                move.b  $F800CA,D0          ; MSR
                and.b   #$C0,D0             ; mask to RQM|DIO only
                cmp.b   #$C0,D0             ; RQM=1,DIO=1 -- result byte ready (CB=1 or CB=0)
                beq.s   FOP_RES2
                cmp.b   #$80,D0             ; RQM=1,DIO=0 -- done, no more result bytes
                beq.s   FOP_EVAL
                dbra    D1,FOP_RES1
                move.b  #FRC_TOGETRES,FST_RC
                bra     FOP_EXIT

FOP_RES2:
                ; Buffer full check (max 7 bytes)
                move.b  FOP_RESCNT,D0
                cmp.b   #FRB_SIZ,D0
                blt.s   .res_read
                ; buffer overrun -- still eval what we have
                bra.s   FOP_EVAL
.res_read:
                move.b  $F800CC,(A0)+       ; read result byte into FRB
                move.b  FOP_RESCNT,D0
                addq.b  #1,D0
                move.b  D0,FOP_RESCNT
                move.b  D0,FRB_LEN          ; keep FRB_LEN updated
                bra.s   FOP_RES0

;------------------------------------------------------------
; FOP_EVAL -- decode ST0/ST1 into FST_RC (fd.asm FOP_EVAL/EVALST0/EVALST1)
;------------------------------------------------------------
FOP_EVAL:
                ; Commands with no ST0 (e.g. SPECIFY, SEEK) -- exit clean
                move.b  FCP_CMD,D0
                cmp.b   #CFD_SPECIFY,D0
                beq     FOP_EXIT
                cmp.b   #CFD_SEEK,D0
                beq     FOP_EXIT
                cmp.b   #CFD_RECAL,D0
                beq     FOP_EXIT
                ; DRVSTAT returns ST3 only -- not ST0; skip IC-field evaluation
                cmp.b   #CFD_DRVSTAT,D0
                beq     FOP_EXIT

                ; If no result bytes received, nothing to check
                move.b  FRB_LEN,D0
                tst.b   D0
                beq     FOP_EXIT

FOP_EVALST0:
                move.b  FRB_ST0,D0
                and.b   #$C0,D0             ; isolate IC field
                cmp.b   #$40,D0             ; IC=01 -- abnormal termination
                beq.s   FOP_ABTERM
                cmp.b   #$80,D0             ; IC=10 -- invalid command
                beq.s   FOP_INVCMD
                cmp.b   #$C0,D0             ; IC=11 -- disk changed / not ready
                beq.s   FOP_DSKCHG
                bra     FOP_EXIT            ; IC=00 -- normal

FOP_ABTERM:
                ; SENSEINT only has PCN, no ST1
                move.b  FCP_CMD,D0
                cmp.b   #CFD_SENSEINT,D0
                beq.s   .at_no_st1
                ; Do we have ST1?
                move.b  FRB_LEN,D0
                cmp.b   #2,D0
                blt.s   .at_no_st1
                bra.s   FOP_EVALST1
.at_no_st1:
                move.b  #FRC_ABTERM,FST_RC
                bra.s   FOP_EXIT

FOP_INVCMD:
                move.b  #FRC_INVCMD,FST_RC
                bra.s   FOP_EXIT

FOP_DSKCHG:
                move.b  #FRC_DSKCHG,FST_RC
                bra.s   FOP_EXIT

FOP_EVALST1:
                move.b  FRB_ST1,D0

                btst    #7,D0
                bne.s   .st1_endcyl
                btst    #5,D0
                bne.s   .st1_dataerr
                btst    #4,D0
                bne.s   .st1_overrun
                btst    #2,D0
                bne.s   .st1_nodata
                btst    #1,D0
                bne.s   .st1_notwrit
                btst    #0,D0
                bne.s   .st1_misadr
                ; No ST1 errors -- check if IC=01 in PIO mode is normal ABTERM
                ; In PIO mode: ABTERM (IC=01) occurs at TC; treat as OK when
                ; ST1 has no error bits set. This matches fd.asm behavior.
                bra.s   FOP_EXIT

.st1_endcyl:    move.b  #FRC_ENDCYL,FST_RC
                bra.s   FOP_EXIT
.st1_dataerr:   move.b  #FRC_DATAERR,FST_RC
                bra.s   FOP_EXIT
.st1_overrun:   move.b  #FRC_OVERRUN,FST_RC
                bra.s   FOP_EXIT
.st1_nodata:    move.b  #FRC_NODATA,FST_RC
                bra.s   FOP_EXIT
.st1_notwrit:   move.b  #FRC_NOTWRIT,FST_RC
                bra.s   FOP_EXIT
.st1_misadr:    move.b  #FRC_MISADR,FST_RC

FOP_EXIT:
                rts

;============================================================
; Execution phase routines (translate fd.asm FXR_READ/FXR_WRITE/FXR_NULL)
; These are the timing-critical loops: NO calls, minimal overhead.
; Interrupts disabled for duration (fd.asm HB_DI / HB_EI).
;============================================================

;------------------------------------------------------------
; FXR_READ -- read one sector from FDC into FD_DSKBUF
; fd.asm FXR_READ: 3-level timeout, poll MSR for $F0, read DATA.
; After all bytes: FC_PULSETC.
;------------------------------------------------------------
FXR_READ:
                movem.l D1-D5/A0-A2,-(sp)

                move.l  FD_DSKBUF,A0        ; destination buffer
                move.w  FCD_W_SECSZ,D5      ; byte count
                subq.w  #1,D5               ; DBRA count

                lea.l   $F800CA,A1          ; MSR
                lea.l   $F800CC,A2          ; DATA

                ; Disable interrupts (fd.asm HB_DI)
                move.w  SR,D4
                ori.w   #$0700,SR

                move.b  #10,D3              ; outer3: outermost timeout

.rd_outer3:
                move.w  #255,D2             ; outer2: outer timeout (C in fd.asm)

.rd_outer2:
                move.w  #255,D1             ; inner: B = 256 iterations

; Inner poll loop -- must be tight (≤32µs/byte at 250Kbps)
.rd_inner:
                move.b  (A1),D0             ; read MSR
                cmp.b   #MSR_EXEC_RD,D0     ; $F0: RQM|DIO|NDM|CB
                beq.s   .rd_got
                dbra    D1,.rd_inner

                ; Inner expired -- check for abort condition
                move.b  (A1),D0
                and.b   #$F0,D0
                cmp.b   #$C0,D0             ; $C0 = exec aborted
                beq.s   .rd_abort
                cmp.b   #$D0,D0             ; $D0 = result phase started
                beq.s   .rd_abort

                ; Not aborted, just slow: decrement outer2
                dbra    D2,.rd_outer2
                dbra    D3,.rd_outer3

                ; All timeouts exhausted
                move.l  #FRC_TOEXEC,D0
                bra.s   .rd_done

.rd_abort:
                move.l  #FRC_ABORT,D0
                bra.s   .rd_done

.rd_got:
                move.b  (A2),(A0)+          ; read DATA -> buf++
                dbra    D5,.rd_outer2       ; next byte (reuse outer2 fresh inner)

                ; All bytes received -- pulse TC (fd.asm FXR_END)
                move.b  $F800CE,D0          ; read TC address = DACK pulse
                moveq.l #FRC_OK,D0

.rd_done:
                ; Restore interrupts (fd.asm HB_EI)
                move.w  D4,SR

                ; Store error code in FST_RC if non-zero
                tst.l   D0
                beq.s   .rd_ret
                move.b  D0,FST_RC

.rd_ret:
                movem.l (sp)+,D1-D5/A0-A2
                rts

;------------------------------------------------------------
; FXR_WRITE -- write one sector from FD_DSKBUF into FDC
; fd.asm FXR_WRITE: same structure as FXR_READ, poll for $B0.
;------------------------------------------------------------
FXR_WRITE:
                movem.l D1-D5/A0-A2,-(sp)
                clr.l   FXR_WR_COUNT

                move.l  FD_DSKBUF,A0        ; source buffer
                move.w  FCD_W_SECSZ,D5
                subq.w  #1,D5

                lea.l   $F800CA,A1          ; MSR
                lea.l   $F800CC,A2          ; DATA

                move.w  SR,D4
                ori.w   #$0700,SR

                move.b  #10,D3              ; outer3

.wr_outer3:
                move.w  #255,D2             ; outer2

.wr_outer2:
                move.w  #255,D1             ; inner

.wr_inner:
                move.b  (A1),D0
                cmp.b   #MSR_EXEC_WR,D0     ; $B0: RQM|NDM|CB (DIO=0)
                beq.s   .wr_got
                dbra    D1,.wr_inner

                move.b  (A1),D0
                and.b   #$F0,D0
                cmp.b   #$C0,D0
                beq.s   .wr_abort
                cmp.b   #$D0,D0
                beq.s   .wr_abort

                dbra    D2,.wr_outer2
                dbra    D3,.wr_outer3

                move.l  #FRC_TOEXEC,D0
                bra.s   .wr_done

.wr_abort:
                move.l  #FRC_ABORT,D0
                bra.s   .wr_done

.wr_got:
                move.b  (A0)+,(A2)          ; buf++ -> DATA
                addq.l  #1,FXR_WR_COUNT
                dbra    D5,.wr_outer2

                move.b  $F800CE,D0          ; TC pulse
                moveq.l #FRC_OK,D0

.wr_done:
                move.w  D4,SR

                tst.l   D0
                beq.s   .wr_ret
                move.b  D0,FST_RC

.wr_ret:
                movem.l (sp)+,D1-D5/A0-A2
                rts

;------------------------------------------------------------
; FXR_NULL -- null execution (used by READID, fd.asm FXR_NULL)
; Wait for FDC to finish (MSR=$C0) with 2-rotation timeout.
; $4000 iterations at ~25us each = ~410ms (matches fd.asm).
; No TC pulse on exit.
;------------------------------------------------------------
FXR_NULL:
                move.l  #$4000,D1           ; 16-bit inner + outer = total $4000
.null_loop:
                bsr     FDC_DELAY
                move.b  $F800CA,D0
                and.b   #$E0,D0
                cmp.b   #$C0,D0             ; RQM=1,DIO=1,NDM=0 -- exec done
                beq.s   .null_ok
                subq.l  #1,D1
                bne.s   .null_loop
                ; Timeout
                move.b  #FRC_TOEXEC,FST_RC
                rts
.null_ok:
                rts

;============================================================
; FC_SPECIFY -- send SPECIFY command (fd.asm FC_SPECIFY)
;============================================================
FC_SPECIFY:
                move.b  #CFD_SPECIFY,D0
                bsr     FC_SETUPSPECIFY
                bra     FOP

;============================================================
; FC_RECAL -- send RECALIBRATE command (fd.asm FC_RECAL)
;============================================================
FC_RECAL:
                move.b  #CFD_RECAL,D0
                bsr     FC_SETUPCMD
                ; RECAL has no results phase, FCP_LEN=2 is correct
                bra     FOP

;============================================================
; FC_SENSEINT -- send SENSE INTERRUPT STATUS (fd.asm FC_SENSEINT)
; 1-byte command only; results: ST0, PCN.
;============================================================
FC_SENSEINT:
                move.b  #CFD_SENSEINT,D0
                bsr     FC_SETUPCMD
                move.b  #1,FCP_LEN          ; only 1 byte (no HDS/DS)
                bra     FOP

;============================================================
; FC_DRVSTAT -- DRIVE STATUS (fd.asm FC_DRVSTAT)
; Sends CFD_DRVSTAT ($04): 2-byte cmd [cmd, HDS|DS] -> 1 result byte: ST3.
; FOP_EVAL bypasses ST0 checking for this command (result is ST3, not ST0).
;============================================================
FC_DRVSTAT:
                move.b  #CFD_DRVSTAT,D0
                bsr     FC_SETUPCMD          ; 2-byte cmd: [$04, HDS|DS]
                bra     FOP                  ; result byte lands at FRB_ST3

;============================================================
; FC_SEEK -- send SEEK command (fd.asm FC_SEEK)
;============================================================
FC_SEEK:
                move.b  #CFD_SEEK,D0
                bsr     FC_SETUPSEEK
                bra     FOP

;============================================================
; FC_READ -- setup and run READ DATA (fd.asm FC_READ)
; fd.asm: CFD_READ | 11100000B = $06 | $E0 = $E6
;============================================================
FC_READ:
                move.b  #CFD_READ|$E0,D0    ; MT|MFM|SK mask -> AND $5F -> MFM only
                bsr     FC_SETUPIO
                bra     FOP

;============================================================
; FC_WRITE -- setup and run WRITE DATA (fd.asm FC_WRITE)
; fd.asm: CFD_WRITE | 11000000B = $05 | $C0 = $C5
;============================================================
FC_WRITE:
                move.b  #CFD_WRITE|$C0,D0   ; MFM mask -> AND $5F -> MFM only
                bsr     FC_SETUPIO
                bra     FOP

;============================================================
; FC_READID -- send READ ID command (fd.asm FC_READID)
; CFD_READID ($0A) | $40 (MFM) = $4A.
; 2-byte command: [cmd, HDS|DS]. No data-transfer phase (FXR_NULL).
; Result: 7 bytes (ST0, ST1, ST2, C, H, R, N).
; FST_RC=0 means a valid address mark was found at the current data rate.
; Used by FD_media_detect to identify media type without a data buffer.
;============================================================
FC_READID:
                move.b  #CFD_READID|$40,D0  ; MFM bit; FC_SETUPCMD strips MT/SK
                bsr     FC_SETUPCMD          ; 2-byte cmd: [CFD_READID|$40, HDS|DS]
                bra     FOP

;============================================================
; FD_CLRDSKCHG -- drain IC=3 poll interrupts (fd.asm FD_CLRDSKCHG)
; Call SENSEINT up to 5 times; stop when FST_RC != FRC_DSKCHG.
; Trashes D0.
;============================================================
FD_CLRDSKCHG:
                move.w  #4,D0               ; 5 iterations: DBRA 4..0
.clr_loop:
                movem.l D0,-(sp)
                bsr     FC_SENSEINT
                movem.l (sp)+,D0
                move.b  FST_RC,D1
                cmp.b   #FRC_DSKCHG,D1
                bne.s   .clr_done
                dbra    D0,.clr_loop
.clr_done:
                ; Reset FST_RC to OK regardless (drain is advisory)
                move.b  #FRC_OK,FST_RC
                rts

;============================================================
; FD_WTSEEK -- wait for seek/recal to complete (fd.asm FD_WTSEEK)
; Loop calling SENSEINT until FST_RC = FRC_OK or FRC_ABTERM.
; Counter WTSEEK_OUTER ($1000) prevents infinite spin.
; Returns FST_RC in D0.
;============================================================
FD_WTSEEK:
                move.l  #WTSEEK_OUTER,D1
.wt_loop:
                movem.l D1,-(sp)
                bsr     FC_SENSEINT
                movem.l (sp)+,D1
                move.b  FST_RC,D0
                cmp.b   #FRC_ABTERM,D0
                beq.s   .wt_done
                cmp.b   #FRC_OK,D0
                beq.s   .wt_done
                subq.l  #1,D1
                bne.s   .wt_loop
                ; Timeout -- D0 holds last FST_RC
.wt_done:
                rts

;============================================================
; FD_DRIVERESET -- full drive reset: SPECIFY + RECAL (fd.asm FD_DRIVERESET)
; Returns D0=0 on success, nonzero on failure.
;============================================================
FD_DRIVERESET:
                bsr     FC_SPECIFY
                move.b  FST_RC,D0
                tst.b   D0
                bne.s   .dr_fail

                bsr     FC_RECAL
                move.b  FST_RC,D0
                tst.b   D0
                bne.s   .dr_fail

                ; First recal: FRC_ABTERM is the expected normal completion.
                ; Only do a second recal for other non-zero results (e.g. timeout).
                bsr     FD_WTSEEK
                tst.b   D0
                beq.s   .dr_ok              ; FRC_OK: done
                cmp.b   #FRC_ABTERM,D0      ; FRC_ABTERM: normal recal completion
                beq.s   .dr_ok

                ; Second attempt (only for unexpected errors)
                bsr     FC_RECAL
                move.b  FST_RC,D0
                tst.b   D0
                bne.s   .dr_fail

                bsr     FD_WTSEEK
.dr_ok:
                moveq.l #0,D0
                rts
.dr_fail:
                moveq.l #-1,D0
                rts

;============================================================
; FD_START -- execute one read or write operation (fd.asm FD_START)
; FCD_DS, FCD_C_PARAM, FCD_H_PARAM, FCD_R_PARAM, FCD_DOP must
; be set by caller. A1 = FDDevice*.
; Returns D0=0 on success, nonzero on error (also in FST_RC).
;============================================================
FD_START:
                movem.l D1/A1,-(sp)

                ; Check fdcrdy flag in FDDevice
                move.b  FDD_FLAGS(A1),D0
                btst    #0,D0               ; FDD_FLAG_FDCRDY
                bne.s   .st_noreset
                ; FDC not ready -- full reset
                bsr     FC_RESETFDC
                bsr     FD_CLRDSKCHG
                ; Set fdcrdy
                move.b  FDD_FLAGS(A1),D0
                or.b    #FDD_FLAG_FDCRDY,D0
                move.b  D0,FDD_FLAGS(A1)
.st_noreset:

                ; Copy media config from ROM into FCD working copy
                move.b  FDD_MEDIA(A1),D0    ; media type (0=720K, 1=1.44M)
                lsl.w   #2,D0               ; *4 for FCD_TBL index
                lea.l   FCD_TBL,A0
                move.l  0(A0,D0.w),A0       ; A0 = pointer to FCD_PCxxx ROM table
                lea.l   FCD,A2              ; destination: working copy
                move.b  (A0)+,(A2)+         ; NUMCYL
                move.b  (A0)+,(A2)+         ; NUMHD
                move.b  (A0)+,(A2)+         ; NUMSEC
                move.b  (A0)+,(A2)+         ; SOT
                move.b  (A0)+,(A2)+         ; SC
                move.b  (A0)+,(A2)+         ; pad
                move.b  (A0)+,(A2)+         ; SECSZhi
                move.b  (A0)+,(A2)+         ; SECSZlo
                move.b  (A0)+,(A2)+         ; GPL
                move.b  (A0)+,(A2)+         ; GPLF
                move.b  (A0)+,(A2)+         ; SRTHUT
                move.b  (A0)+,(A2)+         ; HLTND
                move.b  (A0)+,(A2)+         ; DOR_VAL
                move.b  (A0)+,(A2)+         ; DCR_VAL

                ; Motor on
                bsr     FC_MOTORON

                ; Check if recalibrate is needed (track == $FE or $FF)
                move.b  FDD_TRACK(A1),D0
                cmp.b   #$FE,D0
                blt.s   .st_check_seek      ; track < $FE: no reset needed

                bsr     FD_DRIVERESET
                tst.l   D0
                bne.s   .st_err

                ; Mark track as 0 after successful recal
                move.b  #0,FDD_TRACK(A1)

.st_check_seek:
                ; Compare current track with requested cylinder
                move.b  FDD_TRACK(A1),D0
                cmp.b   FCD_C_PARAM,D0
                beq.s   .st_dispatch         ; already on correct track

                ; Seek to new track
                bsr     FC_SEEK
                move.b  FST_RC,D0
                tst.b   D0
                bne.s   .st_err

                bsr     FD_WTSEEK
                ; FD_WTSEEK returns FRC_ABTERM (-8) on a normal seek completion:
                ; the 8272A/WD37C65 SENSEINT result has IC=01 after any completed
                ; seek or recal. FRC_OK (0) can occur if the poll sees IC=00.
                ; Treat both as success; any other non-zero code is a real error.
                tst.b   D0
                beq.s   .st_track_ok        ; FRC_OK: accept
                cmp.b   #FRC_ABTERM,D0      ; FRC_ABTERM: normal seek completion
                bne.s   .st_err
.st_track_ok:
                ; Update current track in FDDevice
                move.b  FCD_C_PARAM,D0
                move.b  D0,FDD_TRACK(A1)

.st_dispatch:
                ; Dispatch READ, WRITE, or READID
                move.b  FCD_DOP,D0
                cmp.b   #DOP_READID,D0
                beq.s   .st_do_readid
                tst.b   D0
                beq.s   .st_do_read
                bsr     FC_WRITE
                bra.s   .st_check_rc

.st_do_readid:
                bsr     FC_READID
                bra.s   .st_check_rc

.st_do_read:
                bsr     FC_READ

.st_check_rc:
                move.b  FST_RC,D0
                ext.l   D0
                tst.l   D0
                beq.s   .st_ok

.st_err:
                ; On error: clear fdcrdy and mark track unknown
                move.b  FDD_FLAGS(A1),D0
                and.b   #$FE,D0             ; clear FDD_FLAG_FDCRDY (bit 0)
                move.b  D0,FDD_FLAGS(A1)
                move.b  #$FF,FDD_TRACK(A1)
                move.b  FST_RC,D0
                ext.l   D0
                movem.l (sp)+,D1/A1
                rts

.st_ok:
                moveq.l #0,D0
                movem.l (sp)+,D1/A1
                rts

;============================================================
; FD_init -- TRAP13 FC=21 entry point (fd.asm FD_INIT)
; Args: D1.L = drive number (0 or 1)
;       A1   = pointer to caller-allocated FDDevice struct
; Returns: D0.L = 0 on success, nonzero on failure
;============================================================
FD_init::
                movem.l D1-D2/A0-A2,-(sp)      ; save all but D0 (D0 = return value)

                ; Init FDDevice fields
                move.b  D1,FDD_UNIT(A1)
                move.b  #$FF,FDD_TRACK(A1)     ; unknown track -> needs recal
                ; media_type stays as caller set it (default 0 = 720K)
                clr.b   FDD_FLAGS(A1)           ; fdcrdy=0 initially

                ; Init driver globals
                move.b  #DOR_INIT,FST_DOR
                clr.w   FST_IDLECNT         ; idle disabled until first transfer

                ; Load default media config into FCD working copy.
                ; FDD_MEDIA(A1) selects the config block (0=720K, 1=1.44M).
                ; Must happen before FC_RESETFDC so SRTHUT/HLTND are
                ; populated when FC_SPECIFY runs.
                move.b  FDD_MEDIA(A1),D0
                ext.w   D0
                ext.l   D0
                lsl.l   #2,D0               ; * 4 -> FCD_TBL entry offset
                lea.l   FCD_TBL,A0
                move.l  (A0,D0.l),A0        ; A0 -> ROM media config block
                lea.l   FCD,A2
                move.w  #FCD_LEN-1,D0       ; DBRA count
.fcd_copy:
                move.b  (A0)+,(A2)+
                dbra    D0,.fcd_copy

                ; Hardware reset
                bsr     FC_RESETFDC

                ; Drain post-reset IC=3 interrupts
                bsr     FD_CLRDSKCHG

                ; Send SPECIFY using the loaded SRTHUT/HLTND values.
                ; A timeout here means the FDC is not accepting commands.
                bsr     FC_SPECIFY
                tst.b   FST_RC
                beq.s   .specify_ok
                ; SPECIFY failed -- return FST_RC as error, fdcrdy stays 0
                move.b  FST_RC,D0
                ext.w   D0
                ext.l   D0
                movem.l (sp)+,D1-D2/A0-A2
                rts
.specify_ok:

                ; MSR sanity check: $FF = bus floating, $00 = chip stuck.
                ; Either means no FDC present; do not set fdcrdy.
                move.b  FDC_MSR,D0
                cmp.b   #$FF,D0
                beq.s   .msr_bad
                cmp.b   #$00,D0
                bne.s   .msr_ok
.msr_bad:
                move.l  #$FF,D0             ; bad MSR sentinel
                movem.l (sp)+,D1-D2/A0-A2
                rts
.msr_ok:

                ; Mark FDC as ready
                or.b    #FDD_FLAG_FDCRDY,FDD_FLAGS(A1)

                moveq.l #0,D0
                movem.l (sp)+,D1-D2/A0-A2
                rts

;============================================================
; FD_read_sectors -- TRAP13 FC=22 entry point
; Args: A2=buf, D1=LBA, D2=count, A1=FDDevice*
; Returns: D0=sectors successfully read
;============================================================
FD_read_sectors::
                movem.l D1-D7/A0-A6,-(sp)
                move.b  #DOP_READ,FCD_DOP
                bsr     FD_XFER
                movem.l (sp)+,D1-D7/A0-A6
                ; D0 = count set by FD_XFER
                rts

;============================================================
; FD_write_sectors -- TRAP13 FC=23 entry point
; Args: A2=buf, D1=LBA, D2=count, A1=FDDevice*
; Returns: D0=sectors successfully written
;============================================================
FD_write_sectors::
                movem.l D1-D7/A0-A6,-(sp)
                move.b  #DOP_WRITE,FCD_DOP
                bsr     FD_XFER
                movem.l (sp)+,D1-D7/A0-A6
                rts

;============================================================
; FD_XFER -- common transfer loop (fd.asm FD_RUN / FD_RETRY)
; On entry: FCD_DOP set, D1=LBA, D2=count, A1=FDDevice*, A2=buf
; Returns: D0 = sectors transferred
;============================================================
FD_XFER:
                movem.l D1-D6/A1-A3,-(sp)

                ; Preserve A1 (FDDevice*) in A3 across the loop
                move.l  A1,A3
                move.l  A2,A0               ; A0 = buffer pointer
                move.l  D2,D6               ; D6 = remaining sector count
                clr.l   D5                  ; D5 = sectors transferred

                ; LBA -> CHS conversion
                ; media geometry from FDDevice media type
                ; Get secs/track and heads from working copy (must copy first)
                ; Actually: copy media config now so we have geometry
                move.b  FDD_MEDIA(A3),D0
                lsl.w   #2,D0
                lea.l   FCD_TBL,A1
                move.l  0(A1,D0.w),A1       ; A1 = ROM config pointer
                moveq.l #0,D3
                move.b  FCD_NUMSEC(A1),D3   ; D3 = sectors/track (zero-extended)
                moveq.l #0,D4
                move.b  FCD_NUMHD(A1),D4    ; D4 = heads (zero-extended)

.xfer_sector:
                tst.l   D6
                beq.s   .xfer_done

                ; LBA -> C/H/R
                ; R = (LBA % secs) + 1
                ; head_tmp = LBA / secs
                ; C = head_tmp / heads
                ; H = head_tmp % heads
                move.l  D1,D0               ; D0 = LBA (32-bit dividend)
                divu.w  D3,D0               ; D0.hi = LBA%secs, D0.lo = LBA/secs
                move.w  D0,D2               ; D2 = LBA/secs (head_tmp)
                swap    D0
                move.b  D0,FCD_R_PARAM      ; R = LBA%secs low byte (0-based so far)
                add.b   #1,FCD_R_PARAM      ; +1 -> 1-based

                moveq.l #0,D0
                move.w  D2,D0               ; D0 = head_tmp (zero-extended, clear div garbage)
                divu.w  D4,D0               ; D0.hi = head_tmp%heads, D0.lo = head_tmp/heads
                move.w  D0,D2               ; D2 = cylinder
                swap    D0
                move.b  D0,FCD_H_PARAM      ; H = head_tmp%heads
                move.b  D2,FCD_C_PARAM      ; C = cylinder

                move.b  FDD_UNIT(A3),D0
                move.b  D0,FCD_DS           ; drive select

                ; Save buffer pointer into FD_DSKBUF
                move.l  A0,FD_DSKBUF

                ; Retry loop (fd.asm FD_RETRY DJNZ 5)
                move.l  A3,A1               ; FD_START needs A1=FDDevice*
                move.w  #4,D2               ; 5 attempts: DBRA 4..0
.retry:
                movem.l D1-D6/A0/A3,-(sp)
                movem.l D2,-(sp)
                bsr     FD_START
                movem.l (sp)+,D2
                movem.l (sp)+,D1-D6/A0/A3
                tst.l   D0
                beq.s   .sector_ok
                dbra    D2,.retry
                ; All retries exhausted -- stop
                bra.s   .xfer_done

.sector_ok:
                ; Advance buffer by sector size (512)
                add.l   #512,A0
                addq.l  #1,D1               ; next LBA
                addq.l  #1,D5               ; transferred++
                subq.l  #1,D6               ; remaining--
                bra.s   .xfer_sector

.xfer_done:
                move.l  D5,D0               ; return count in D0
                movem.l (sp)+,D1-D6/A1-A3
                rts

;============================================================
; FD_geom -- return geometry for current media type (TRAP13 FC=24)
; Input:  A1 = FDDevice*
; Output: D0 = (NUMCYL<<16) | (NUMHD<<8) | NUMSEC
;         Unpack with FD_GEOM_CYLS/HEADS/SECS macros in fd.h
; Pure ROM table lookup -- no FDC commands issued.
;============================================================
FD_geom::
                movem.l A0,-(sp)

                move.b  FDD_MEDIA(A1),D0
                ext.w   D0
                ext.l   D0
                lsl.l   #2,D0               ; *4 -> FCD_TBL index
                lea.l   FCD_TBL,A0
                move.l  (A0,D0.l),A0        ; A0 = ROM media config block

                ; Pack D0 = (NUMCYL<<16) | (NUMHD<<8) | NUMSEC
                clr.l   D0
                move.b  FCD_NUMCYL(A0),D0
                lsl.l   #8,D0
                move.b  FCD_NUMHD(A0),D0
                lsl.l   #8,D0
                move.b  FCD_NUMSEC(A0),D0

                movem.l (sp)+,A0
                rts

;============================================================
; FD_media_detect -- detect media via READID command (TRAP13 FC=25)
; Input:  A1 = FDDevice* (FDD_UNIT must be set)
; Output: D0 = FDM144 or FDM720 on success,
;              FRC_NODATA (-14) if no disk or FDC not responding.
;         On success: FDD_MEDIA, FDD_TRACK, FDD_FLAGS updated.
;
; Controlled by fd_config.inc:
;   FD_MEDIA_AUTO=1 (default): READID probe at both data rates
;   FD_MEDIA_AUTO=0:           report FD_MEDIA_PRIMARY immediately
;   FD_MEDIA_PRIMARY/ALT:      which type to probe first/second
;============================================================
FD_media_detect::
    ifne FD_MEDIA_AUTO
                movem.l D1-D3/A0-A3,-(sp)  ; D3 = retry counter
                move.l  A1,A3               ; A3 = FDDevice* (preserved)

                ; Drive select + head 0 for READID command byte
                move.b  FDD_UNIT(A3),D0
                move.b  D0,FCD_DS
                clr.b   FCD_H_PARAM

                ; Retry loop: 5 attempts
                moveq.l #4,D3               ; DBRA 4..0 = 5 attempts

.probe_retry:
                ; --- Try FD_MEDIA_PRIMARY ---
                moveq.l #FD_MEDIA_PRIMARY,D2  ; D2 = media type being tried
                bsr     .do_probe
                tst.l   D0
                bpl.s   .md_ok

                ; --- Try FD_MEDIA_ALT ---
                moveq.l #FD_MEDIA_ALT,D2
                bsr     .do_probe
                tst.l   D0
                bpl.s   .md_ok

                ; Both failed this attempt -- retry
                dbra    D3,.probe_retry

                ; All retries exhausted
                bsr     FC_MOTOROFF
                and.b   #$FE,FDD_FLAGS(A3)  ; clear FDD_FLAG_FDCRDY
                move.l  #FRC_NODATA,D0
                bra.s   .md_done

.md_ok:
                ; D2 = successful media type; D0 already = D2 (set by .do_probe)
                move.b  D2,FDD_MEDIA(A3)
                ; Leave fdcrdy=0 so FD_START runs a clean reset before the
                ; first real read -- the probe may have left the FDC at a
                ; different data rate than the confirmed media type requires.
                and.b   #$FE,FDD_FLAGS(A3)  ; ensure fdcrdy=0
                move.b  #$FF,FDD_TRACK(A3)  ; force RECAL on first operation
                bra.s   .md_done

; .do_probe -- attempt a READID at the data rate for media type in D2.
; FD_START handles motor-on, SPECIFY, RECAL and the READID command.
; READID (CFD_READID $0A) sends a 2-byte command, has no data-transfer
; phase (FXR_NULL), and returns 7 result bytes: ST0,ST1,ST2,C,H,R,N.
; FST_RC=0 means the FDC found a valid address mark at this data rate.
; The probe order (FDM144 first) is the discriminator.
; Returns D0 = D2 (media type) on success, D0 = FRC_NODATA on failure.
; Trashes D0. D2 and A3 preserved by outer movem.l.
.do_probe:
                ; Clear fdcrdy so FD_START runs a full reset sequence
                ; (FC_RESETFDC + FD_CLRDSKCHG + SPECIFY + RECAL) for each probe.
                and.b   #$FE,FDD_FLAGS(A3)  ; clear FDD_FLAG_FDCRDY

                ; Tell FD_START which media config (data rate) to load
                move.b  D2,FDD_MEDIA(A3)

                ; Force track unknown so FD_START always runs SPECIFY+RECAL
                move.b  #$FF,FDD_TRACK(A3)

                ; READID operates on whichever track the head is on after RECAL
                ; (cylinder 0, head 0).  No CHS parameters needed.
                move.b  #DOP_READID,FCD_DOP

                ; FD_START: motor-on, SPECIFY+RECAL, READID.
                ; FOP_CMD1 uses D2 as its command-byte countdown and leaves it
                ; at 0 on return, so preserve D2 across the call.
                move.l  A3,A1
                move.l  D2,-(sp)
                bsr     FD_START
                move.l  (sp)+,D2
                tst.l   D0
                bne.s   .dp_fail

                tst.b   FST_RC
                bne.s   .dp_fail

                move.l  D2,D0               ; return media type
                rts

.dp_fail:       move.l  #FRC_NODATA,D0
                rts

.md_done:
                movem.l (sp)+,D1-D3/A0-A3
                rts

    else
                ; FD_MEDIA_AUTO=0: no hardware probe, use compile-time primary
                move.b  #FD_MEDIA_PRIMARY,FDD_MEDIA(A1)
                or.b    #FDD_FLAG_FDCRDY,FDD_FLAGS(A1)
                moveq.l #FD_MEDIA_PRIMARY,D0
                rts
    endc



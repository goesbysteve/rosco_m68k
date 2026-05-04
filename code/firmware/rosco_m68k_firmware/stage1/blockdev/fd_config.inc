;------------------------------------------------------------
; fd_config.inc -- compile-time WD37C65 floppy configuration
;
; Included by fd.asm. Only assembled when WITH_FDC=true.
; Any symbol can be overridden from the Makefile, e.g.:
;
;   DEFINES += -DFD_MEDIA_PRIMARY=0   ; force 720K-only build
;   DEFINES += -DFD_MEDIA_AUTO=0      ; skip auto-detect at boot
;   DEFINES += -DFD_CPU_MHZ=20        ; 20MHz system clock
;------------------------------------------------------------

; CPU clock frequency in MHz. All time-based delay loop counts
; are derived from this value so timings stay correct if the
; system clock changes. Default matches the standard rosco_m68k
; 10 MHz build. Override via -DFD_CPU_MHZ=N in DEFINES.
    ifnd FD_CPU_MHZ
FD_CPU_MHZ      equ 10
    endc

; Media type indices -- must match FCD_TBL order in fd.asm
FDM720          equ 0           ; 3.5"  DS/DD  720 KB  250 Kbps
FDM144          equ 1           ; 3.5"  DS/HD 1.44 MB  500 Kbps
FDM360          equ 2           ; 5.25" DS/DD  360 KB  250 Kbps
FDM120          equ 3           ; 5.25" DS/HD  1.2 MB  500 Kbps

; Media type tried first by FD_media_detect.
; Detection uses a real sector READ at the target data rate:
;   FDM144 (500 Kbps) succeeds on a 1.44M disk, fails on 720K.
;   FDM720 (250 Kbps) succeeds on a 720K disk, fails on 1.44M.
; Try the higher-density format first so the slower fallback is
; only reached when a 1.44M read genuinely cannot complete.
    ifnd FD_MEDIA_PRIMARY
FD_MEDIA_PRIMARY equ FDM144
    endc

; Media type tried if the primary READ fails.
    ifnd FD_MEDIA_ALT
FD_MEDIA_ALT    equ FDM720
    endc

; Set to 1 to probe hardware on every FD_media_detect call.
; Set to 0 to skip probing and use FD_MEDIA_PRIMARY unconditionally.
    ifnd FD_MEDIA_AUTO
FD_MEDIA_AUTO   equ 1
    endc

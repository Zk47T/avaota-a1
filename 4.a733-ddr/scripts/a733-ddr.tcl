# OpenOCD helpers: read the A733 DDR PHY (Synopsys LPDDR5/4X PHY) over the
# AHB MEM-AP while the CPU runs boot0 / the FEL init_dram app. UNTESTED on hardware.
#
#   openocd -f interface/ch347.cfg \
#           -f src/syterkit/scripts/openocd/allwinner_a733.cfg \
#           -f scripts/a733-ddr.tcl
#   needs OpenOCD master (CH347 driver + ADIv6; the A733 DAPs are CoreSight-600)
#
# Map: PHY CSR n (16 bit) at 0x0A900000 + 2*n.  APBONLY block 0xd0000:
#   0xd0000 MicroContMuxSel  0 = APB owns the CSRs, 1 = PMU owns them
#   0xd0099 MicroReset       9 -> 1 -> 0 starts the PMU; 1 = stalled
#   0xd0004 UctShadowRegs    bit0 = 0: a mailbox message is waiting
#   0xd0032/0xd0034          message low / high 16 bits
#   0xd0031 DctWriteProt     0 = ack, wait for bit0 = 1, then 1
# DMEM (message block) at CSR 0x58000, IMEM at 0x50000 (same as i.MX95).

set A733_PHY 0x0A900000
if {![info exists A733_AP]} { set A733_AP a733.ahb1 }   ;# AHB-AP of the little-core DAP

proc phy_addr {csr} { global A733_PHY; return [expr {$A733_PHY + 2 * $csr}] }
proc phy_rd {csr} {
    global A733_AP
    return [lindex [$A733_AP read_memory [phy_addr $csr] 16 1] 0]
}
proc phy_wr {csr val} {
    global A733_AP
    $A733_AP write_memory [phy_addr $csr] 16 [list $val]
}

# ---- mailbox -------------------------------------------------------------
set A733_MAJOR [dict create \
    0x00 "end of initialization"          0x01 "end of fine write leveling" \
    0x02 "end of read enable training"    0x03 "end of read delay center" \
    0x04 "end of write delay center"      0x05 "end of 2D read delay/voltage center" \
    0x06 "end of 2D write delay/voltage center" 0x07 "TRAINING PASSED" \
    0x08 "streaming message"              0x09 "end of max read latency training" \
    0x0a "end of read DQ deskew"          0x0d "end of CA training" \
    0xfd "end of MPR read delay center"   0xfe "end of write leveling coarse delay" \
    0xff "TRAINING FAILED"]

proc mb_wait {{timeout_ms 20000}} {
    set t [clock milliseconds]
    while {([phy_rd 0xd0004] & 1) != 0} {
        if {[clock milliseconds] - $t > $timeout_ms} { error "mailbox: no message in $timeout_ms ms" }
    }
}
proc mb_ack {} {
    phy_wr 0xd0031 0
    while {([phy_rd 0xd0004] & 1) == 0} {}
    phy_wr 0xd0031 1
}

# Set the PMU debug-message level before G_execFW starts the PMU.
# Allwinner writes 0xff (only pass/fail); NXP uses 0xc8; 0xfe = stage ends,
# 0x05/0x04 = detailed streaming. Low byte of DMEM word 0x58009 [?].
proc a733_hdtctrl {val} {
    phy_wr 0xd0000 0
    set w [phy_rd 0x58009]
    phy_wr 0x58009 [expr {($w & 0xff00) | ($val & 0xff)}]
    echo [format "HdtCtrl: 0x58009 0x%04x -> 0x%04x" $w [phy_rd 0x58009]]
}

proc a733_pmu_start {} {
    phy_wr 0xd0000 1
    phy_wr 0xd0099 9; phy_wr 0xd0099 1; phy_wr 0xd0099 0
}

# Read messages until pass/fail. "freeze" = return WITHOUT acking a major
# message listed in $stop_at: the PMU waits in its mailbox loop while you look
# around (mailbox regs only; see a733_freeze for CSRs). Call again to continue.
proc a733_train_trace {{stop_at {}}} {
    global A733_MAJOR
    if {[info exists ::a733_pending] && $::a733_pending} { mb_ack; set ::a733_pending 0 }
    while {1} {
        mb_wait
        set lo [phy_rd 0xd0032]
        set key [format "0x%02x" [expr {$lo & 0xff}]]
        set txt [expr {[dict exists $A733_MAJOR $key] ? [dict get $A733_MAJOR $key] : "?"}]
        if {$key eq "0x08"} {
            mb_ack
            mb_wait
            set idx [expr {([phy_rd 0xd0034] << 16) | [phy_rd 0xd0032]}]
            mb_ack
            set args {}
            for {set i 0} {$i < ($idx & 0xffff)} {incr i} {
                mb_wait
                lappend args [format 0x%08x [expr {([phy_rd 0xd0034] << 16) | [phy_rd 0xd0032]}]]
                mb_ack
            }
            echo [format "stream id 0x%08x args %s" $idx $args]
            continue
        }
        echo [format "major %s: %s" $key $txt]
        if {[lsearch -exact $stop_at $key] >= 0} { set ::a733_pending 1; return $key }
        mb_ack
        if {$key eq "0x07" || $key eq "0xff"} { return $key }
    }
}

# EXPERIMENTAL: stall the PMU and take the CSRs to read trained state mid-run.
# Synopsys does not document switching MicroContMuxSel while the PMU is active;
# expect to rerun training. The safe snapshot is after 0x07 (a733_dump_trained).
proc a733_freeze {} { phy_wr 0xd0099 1; phy_wr 0xd0000 0 }
proc a733_thaw   {} { phy_wr 0xd0000 1; phy_wr 0xd0099 0 }

# ---- snapshots -----------------------------------------------------------
proc a733_dmem_dump {{file a733_dmem.txt} {words 0x200}} {
    phy_wr 0xd0000 0
    set f [open $file w]
    for {set i 0} {$i < $words} {incr i} {
        puts $f [format "0x%05x 0x%04x" [expr {0x58000 + $i}] [phy_rd [expr {0x58000 + $i}]]]
    }
    close $f; echo "DMEM 0x58000..+$words -> $file"
}

# Full trained-state snapshot: the 5717 CSRs Allwinner's ARISC firmware saves
# for LPDDR5 retention (out/lpddr5_retention_csrs.txt from analyze.py --csv-out).
proc a733_dump_trained {listfile {outfile a733_trained_csrs.txt}} {
    phy_wr 0xd0000 0
    set in [open $listfile r]; set out [open $outfile w]; set n 0
    while {[gets $in line] >= 0} {
        set c [string trim $line]
        if {$c eq ""} continue
        puts $out [format "%s 0x%04x" $c [phy_rd $c]]
        incr n
    }
    close $in; close $out
    echo "$n CSRs -> $outfile"
}

# Linear dump of one PHY block, e.g. a733_dump_block 0x10000 0x400 (DBYTE0)
proc a733_dump_block {start count {file ""}} {
    phy_wr 0xd0000 0
    set lines {}
    for {set i 0} {$i < $count} {incr i} {
        lappend lines [format "0x%05x 0x%04x" [expr {$start + $i}] [phy_rd [expr {$start + $i}]]]
    }
    if {$file eq ""} { echo [join $lines "\n"] } else {
        set f [open $file w]; puts $f [join $lines "\n"]; close $f
    }
}

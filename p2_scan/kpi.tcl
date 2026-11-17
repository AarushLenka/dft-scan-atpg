# ---------------------------------------------------------------------------
# kpi.tcl -- key/value output for scripts/collect_results.py.
#
# Sourced by baseline.tcl and dft.tcl. The point is that a wrong attribute
# spelling for *your* Genus release degrades to "NA" (and a note in the run
# log), instead of aborting a 3-minute synthesis run. The reports are the real
# deliverable; these numbers only feed results_table.md.
#
# Genus CUI object paths are spelled design:/top on current releases; older
# builds used design:top. get_db on the wrong spelling reports
# "Error : <Start> word is not recognized. [TUI-182]" -- which looks fatal but
# is only this file's query being rejected. Both spellings are tried below.
# ---------------------------------------------------------------------------

# Call once, at the top of the script: a re-run of the same chain count must not
# leave a stale "NA" from an earlier attempt behind.
proc kpi_init {} {
    file mkdir $::OUT
    set fh [open [file join $::OUT kpi.txt] w]
    close $fh
}

proc kpi {name value} {
    if {![string length $value]} { set value NA }
    set fh [open [file join $::OUT kpi.txt] a]
    puts $fh "$name $value"
    close $fh
}

# Decimal only. Tcl's `string is double` accepts 0x55f3a2, and a Genus collection
# handle looks exactly like that -- accepting one would quietly put a pointer in
# the results table.
proc kpi_is_num {tok} {
    return [regexp {^-?[0-9]+(\.[0-9]*)?([eE][-+]?[0-9]+)?$} $tok]
}

# Try each command in turn and return the first result that is a plain number.
# A collection handle is not a number, so it is skipped and the next spelling is
# tried; if every command misses, the caller falls back to parsing a report.
proc kpi_first_num args {
    foreach cmd $args {
        if {[catch {uplevel 1 $cmd} v]} { continue }
        foreach tok $v {
            if {[kpi_is_num $tok]} { return $tok }
        }
    }
    return ""
}

# Scrape the area off the first line matching $tag (case-insensitive regexp),
# e.g. tag {total.*area}. This is the version-proof path -- report_area has
# printed some version of this line for a decade -- but the tag has to handle
# two layouts:
#
#   Total cell area: 1234.56                    <- label and number on one line
#   ... Cell Area  Net Area  Total Area ...     <- column header, number below
#   top  522  5054.578  0.000  5054.578
#
# Genus 21.14 uses the second layout, so when the label line carries no number
# the column underneath is read, picking the right-aligned number closest to the
# label's right edge.
proc kpi_report_num {file tag} {
    if {![file isfile $file]} { return "" }
    set fh [open $file r]
    set txt [read $fh]
    close $fh

    set lines [split $txt \n]
    set n [llength $lines]
    for {set i 0} {$i < $n} {incr i} {
        set line [string map {, ""} [lindex $lines $i]]
        if {![regexp -nocase -indices -- $tag $line m]} { continue }

        set cands [regexp -indices -all -inline {[0-9]+\.?[0-9]*} $line]
        if {[llength $cands]} {
            lassign [lindex $cands 0] s e
            return [string range $line $s $e]
        }

        # Column header: the right edge of the label tells us which of the
        # numbers below it belongs to this column.
        set want [lindex $m 1]
        for {set j [expr {$i + 1}]} {$j < $n && $j <= $i + 8} {incr j} {
            set row [string map {, ""} [lindex $lines $j]]
            if {[string trim $row] eq ""} { break }
            set best ""
            set bestd 1e9
            foreach cand [regexp -indices -all -inline {[0-9]+\.?[0-9]*} $row] {
                lassign $cand s e
                set d [expr {abs($e - $want)}]
                if {$d < $bestd} { set bestd $d; set best [string range $row $s $e] }
            }
            if {$best ne ""} { return $best }
        }
    }
    return ""
}

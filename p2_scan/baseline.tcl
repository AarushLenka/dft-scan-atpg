# -----------------------------------------------------------------------------
# baseline.tcl -- plain synthesis, no DFT. Produces the "before" area number
# that the scan-overhead calculation in the README divides by.
#
#   cd p2_scan
#   mkdir -p runs/baseline
#   genus -f baseline.tcl -log runs/baseline/baseline.log
# -----------------------------------------------------------------------------
set ::OUT runs/baseline
file mkdir $::OUT

# -- machine-readable KPIs for scripts/collect_results.py ----------------------
source [file join [file dirname [info script]] kpi.tcl]
kpi_init

set_db init_lib_search_path ../lib
set_db library cells.lib

read_hdl ../rtl/top.v
elaborate top
read_sdc top.sdc

set_db syn_generic_effort medium
set_db syn_map_effort medium
syn_generic
syn_map
syn_opt

report_area   > $::OUT/baseline_area.rpt
report_timing > $::OUT/baseline_timing.rpt
report_qor    > $::OUT/baseline_qor.rpt

write_hdl > $::OUT/top_nodft.v
write_sdc > $::OUT/top_nodft.sdc

# Every query below has fallbacks: attribute names and CUI object-path spelling
# differ between Genus releases, and a rejected query here must not abort the
# run. If all of them miss, the value comes out "NA" and the number is read
# off the report instead (see docs/STEP_BY_STEP.md).
set area [kpi_first_num {get_db design:/top .area} {get_db designs .area}]
if {$area eq ""} { set area [kpi_report_num $::OUT/baseline_area.rpt {total.*area}] }
kpi AREA_CELL $area

# Never `llength` a collection: on a collection handle it returns 1, not the size.
# get_object_name expands the collection first; sizeof_collection is the direct
# query; the get_db fallback asks the netlist for sequential instances.
set flops [kpi_first_num {llength [get_object_name [all_registers]]} \
                       {sizeof_collection [all_registers]} \
                       {llength [get_db insts * -if {.is_sequential == true}]}]
kpi NUM_FLIPFLOPS $flops

exit

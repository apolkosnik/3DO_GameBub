# Timing summary of a routed checkpoint in a fresh Vivado session.
#   vivado -mode batch -source tools/recheck_timing.tcl -tclargs <dcp> <report>
# Used by build_vivado2018.sh (see there).
open_checkpoint [lindex $argv 0]
report_timing_summary -no_header -max_paths 10 -file [lindex $argv 1]

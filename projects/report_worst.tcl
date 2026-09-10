# Worst setup paths on the machine clock. Run against a completed compile:
#   docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build \
#       raetro/quartus:pocket quartus_sta -t projects/report_worst.tcl
# Writes output_files/worst_paths.txt next to the other reports.
cd projects
if {[catch {project_open gaia_pocket -revision gaia_pocket} err]} {
    puts "PROJECT OPEN FAILED: $err"; exit 1
}
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set n [report_timing -setup -npaths 200 -detail full_path \
        -file output_files/worst_paths.txt]
# the SDRAM interface on its own: its paths never make the top 40 but the
# summary's dram_clk corner can still be negative
set nd [report_timing -setup -npaths 10 -detail full_path -to_clock dram_clk \
        -file output_files/worst_dram.txt]
puts "dram_clk paths returned: $nd"
puts "report_timing returned: $n"
report_clocks -file output_files/clocks.txt
report_sdc    -file output_files/sdc_applied.txt
set nh [report_timing -hold -npaths 10 -detail full_path \
        -file output_files/worst_hold.txt]
puts "hold returned: $nh"
delete_timing_netlist
project_close

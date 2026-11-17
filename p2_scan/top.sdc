create_clock -name clk -period 10 [get_ports clk]

set_input_delay  2 -clock clk [remove_from_collection [all_inputs]  [get_ports clk]]
set_output_delay 2 -clock clk [all_outputs]

# Light output load so the mapped netlist is realistic without a full PDK flow.
set_load 0.05 [all_outputs]

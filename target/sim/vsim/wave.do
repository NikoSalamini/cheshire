onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -expand {/tb_cheshire_soc/fix/dut/i_axi_xbar/slv_ports_req_i[6]}
add wave -noupdate -expand {/tb_cheshire_soc/fix/dut/i_axi_xbar/slv_ports_req_i[0]}
add wave -noupdate {/tb_cheshire_soc/fix/dut/i_axi_xbar/mst_ports_req_o[2]}
add wave -noupdate {/tb_cheshire_soc/fix/dut/i_axi_xbar/slv_ports_req_i[6].aw_valid}
add wave -noupdate {/tb_cheshire_soc/fix/dut/i_axi_xbar/slv_ports_req_i[0].ar_valid}
add wave -noupdate {/tb_cheshire_soc/fix/dut/i_axi_xbar/mst_ports_req_o[2].aw_valid}
add wave -noupdate {/tb_cheshire_soc/fix/dut/i_axi_xbar/mst_ports_req_o[2].ar_valid}
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {36143075000 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 502
configure wave -valuecolwidth 39
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {36141897719 ps} {36146258544 ps}

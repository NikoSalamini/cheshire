
module axi_traffic_generator_wrapper #(
    // Maximum number of AXI read bursts outstanding at the same time
    parameter integer MaxReadTxns   = 32'd32,
    // Maximum number of AXI write bursts outstanding at the same time
    parameter integer MaxWriteTxns  = 32'd32,

    /// AXI
    /// Address width of all AXI4+ATOP ports
    parameter integer AddrWidth = 'd48,
    /// Data width of all AXI4+ATOP ports
    parameter integer DataWidth = 'd64,
    /// ID width of all AXI4+ATOP ports
    parameter integer IdWidth   = 'd4,
    /// User signal width of all AXI4+ATOP ports
    parameter integer UserWidth = 'd4
) (
    input clk,
    input resetn,

    // input ports
    input ext_start,
    input ext_stop,
    input [AddrWidth-1:0] start_address_i,

    // master ports
    output [IdWidth-1:0] m_axi_atg_0_awid,
    output [AddrWidth-1:0] m_axi_atg_0_awaddr,
    output [7:0] m_axi_atg_0_awlen,
    output [2:0] m_axi_atg_0_awsize,
    output [1:0] m_axi_atg_0_awburst,
    output m_axi_atg_0_awlock,
    output [3:0] m_axi_atg_0_awcache,
    output [2:0] m_axi_atg_0_awprot,
    output [3:0] m_axi_atg_0_awqos,
    output [UserWidth-1:0] m_axi_atg_0_awuser,
    output m_axi_atg_0_awvalid,
    input m_axi_atg_0_awready,
    output [DataWidth-1:0] m_axi_atg_0_wdata,
    output [DataWidth/8-1:0] m_axi_atg_0_wstrb,
    output m_axi_atg_0_wlast,
    output m_axi_atg_0_wvalid,
    input m_axi_atg_0_wready,
    input [IdWidth-1:0] m_axi_atg_0_bid,
    input [1:0] m_axi_atg_0_bresp,
    input m_axi_atg_0_bvalid,
    output m_axi_atg_0_bready,
    output [IdWidth-1:0] m_axi_atg_0_arid,
    output [AddrWidth-1:0] m_axi_atg_0_araddr,
    output [7:0] m_axi_atg_0_arlen,
    output [2:0] m_axi_atg_0_arsize,
    output [1:0] m_axi_atg_0_arburst,
    output m_axi_atg_0_arlock,
    output [3:0] m_axi_atg_0_arcache,
    output [2:0] m_axi_atg_0_arprot,
    output [3:0] m_axi_atg_0_arqos,
    output [UserWidth-1:0] m_axi_atg_0_aruser,
    output m_axi_atg_0_arvalid,
    input m_axi_atg_0_arready,
    input [IdWidth-1:0] m_axi_atg_0_rid,
    input [DataWidth-1:0] m_axi_atg_0_rdata,
    input [1:0] m_axi_atg_0_rresp,
    input m_axi_atg_0_rlast,
    input m_axi_atg_0_rvalid,
    output m_axi_atg_0_rready
);

    axi_traffic_generator_flat # (
        .MaxReadTxns  (32),             
        .MaxWriteTxns (32),             
        .AddrWidth    (AddrWidth),
        .DataWidth    (DataWidth),
        .IdWidth      (IdWidth),
        .UserWidth    (UserWidth)
    ) i_axi_traffic_generator_flat (
        .clk_i (clk),
        .rst_ni(resetn),

        // input ports
        .ext_start(ext_start),
        .ext_stop(ext_stop),
        .start_address_i(start_address_i),

        // master
        .m_axi_atg_awid_o({m_axi_atg_0_awid}),
        .m_axi_atg_awaddr_o({m_axi_atg_0_awaddr}),
        .m_axi_atg_awlen_o({m_axi_atg_0_awlen}),
        .m_axi_atg_awsize_o({m_axi_atg_0_awsize}),
        .m_axi_atg_awburst_o({m_axi_atg_0_awburst}),
        .m_axi_atg_awlock_o({m_axi_atg_0_awlock}),
        .m_axi_atg_awcache_o({m_axi_atg_0_awcache}),
        .m_axi_atg_awprot_o({m_axi_atg_0_awprot}),
        .m_axi_atg_awqos_o({m_axi_atg_0_awqos}),
        .m_axi_atg_awuser_o({m_axi_atg_0_awuser}),
        .m_axi_atg_awvalid_o({m_axi_atg_0_awvalid}),
        .m_axi_atg_awready_i({m_axi_atg_0_awready}),
        .m_axi_atg_wdata_o({m_axi_atg_0_wdata}),
        .m_axi_atg_wstrb_o({m_axi_atg_0_wstrb}),
        .m_axi_atg_wlast_o({m_axi_atg_0_wlast}),
        .m_axi_atg_wvalid_o({m_axi_atg_0_wvalid}),
        .m_axi_atg_wready_i({m_axi_atg_0_wready}),
        .m_axi_atg_bid_i({m_axi_atg_0_bid}),
        .m_axi_atg_bresp_i({m_axi_atg_0_bresp}),
        .m_axi_atg_bvalid_i({m_axi_atg_0_bvalid}),
        .m_axi_atg_bready_o({m_axi_atg_0_bready}),
        .m_axi_atg_arid_o({m_axi_atg_0_arid}),
        .m_axi_atg_araddr_o({m_axi_atg_0_araddr}),
        .m_axi_atg_arlen_o({m_axi_atg_0_arlen}),
        .m_axi_atg_arsize_o({m_axi_atg_0_arsize}),
        .m_axi_atg_arburst_o({m_axi_atg_0_arburst}),
        .m_axi_atg_arlock_o({m_axi_atg_0_arlock}),
        .m_axi_atg_arcache_o({m_axi_atg_0_arcache}),
        .m_axi_atg_arprot_o({m_axi_atg_0_arprot}),
        .m_axi_atg_arqos_o({m_axi_atg_0_arqos}),
        .m_axi_atg_aruser_o({m_axi_atg_0_aruser}),
        .m_axi_atg_arvalid_o({m_axi_atg_0_arvalid}),
        .m_axi_atg_arready_i({m_axi_atg_0_arready}),
        .m_axi_atg_rid_i({m_axi_atg_0_rid}),
        .m_axi_atg_rdata_i({m_axi_atg_0_rdata}),
        .m_axi_atg_rresp_i({m_axi_atg_0_rresp}),
        .m_axi_atg_rlast_i({m_axi_atg_0_rlast}),
        .m_axi_atg_rvalid_i({m_axi_atg_0_rvalid}),
        .m_axi_atg_rready_o({m_axi_atg_0_rready})
    );

endmodule
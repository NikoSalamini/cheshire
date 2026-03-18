`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "axi/assign_addon.svh"
`include "axi/port_addon.svh"

module axi_traffic_generator_flat #(
    /// Maximum number of AXI read bursts outstanding at the same time
    parameter int unsigned MaxReadTxns   = 32'd32,
    /// Maximum number of AXI write bursts outstanding at the same time
    parameter int unsigned MaxWriteTxns  = 32'd32,
    /// Number of bursts beats to be generated
    parameter int unsigned NumBurstBeats = 32'd256,
    // AXI Bus Types
    parameter int unsigned AddrWidth     = 32'd48,
    parameter int unsigned DataWidth     = 32'd64,
    parameter int unsigned IdWidth       = 32'd4,
    parameter int unsigned UserWidth     = 32'd4,
    // derived types for AXI interface
    parameter type axi_addr_t = logic [AddrWidth-1  :0],
    parameter type axi_data_t = logic [DataWidth-1  :0],
    parameter type axi_id_t   = logic [IdWidth-1    :0],
    parameter type axi_strb_t = logic [DataWidth/8-1:0],
    parameter type axi_user_t = logic [UserWidth-1  :0]
) (
    input  logic  clk_i,  // clock
    input  logic  rst_ni, // active low

    // AXI manager port (with array to keep _i/_o suffixes)
    output [0:0][  IdWidth-1 : 0] m_axi_atg_awid_o,
    output [0:0][  AddrWidth-1:0] m_axi_atg_awaddr_o,
    output [0:0][            7:0] m_axi_atg_awlen_o,
    output [0:0][            2:0] m_axi_atg_awsize_o,
    output [0:0][            1:0] m_axi_atg_awburst_o,
    output [0:0]                  m_axi_atg_awlock_o,
    output [0:0][            3:0] m_axi_atg_awcache_o,
    output [0:0][            2:0] m_axi_atg_awprot_o,
    output [0:0][            3:0] m_axi_atg_awqos_o,
    output [0:0][UserWidth-1 : 0] m_axi_atg_awuser_o,
    output [0:0]                  m_axi_atg_awvalid_o,
    input  [0:0]                  m_axi_atg_awready_i,
    output [0:0][  DataWidth-1:0] m_axi_atg_wdata_o,
    output [0:0][DataWidth/8-1:0] m_axi_atg_wstrb_o,
    output [0:0]                  m_axi_atg_wlast_o,
    output [0:0]                  m_axi_atg_wvalid_o,
    input  [0:0]                  m_axi_atg_wready_i,
    input  [0:0][  IdWidth-1 : 0] m_axi_atg_bid_i,
    input  [0:0][            1:0] m_axi_atg_bresp_i,
    input  [0:0]                  m_axi_atg_bvalid_i,
    output [0:0]                  m_axi_atg_bready_o,
    output [0:0][  IdWidth-1 : 0] m_axi_atg_arid_o,
    output [0:0][  AddrWidth-1:0] m_axi_atg_araddr_o,
    output [0:0][            7:0] m_axi_atg_arlen_o,
    output [0:0][            2:0] m_axi_atg_arsize_o,
    output [0:0][            1:0] m_axi_atg_arburst_o,
    output [0:0]                  m_axi_atg_arlock_o,
    output [0:0][            3:0] m_axi_atg_arcache_o,
    output [0:0][            2:0] m_axi_atg_arprot_o,
    output [0:0][            3:0] m_axi_atg_arqos_o,
    output [0:0][UserWidth-1 : 0] m_axi_atg_aruser_o,
    output [0:0]                  m_axi_atg_arvalid_o,
    input  [0:0]                  m_axi_atg_arready_i,
    input  [0:0][  IdWidth-1 : 0] m_axi_atg_rid_i,
    input  [0:0][  DataWidth-1:0] m_axi_atg_rdata_i,
    input  [0:0][            1:0] m_axi_atg_rresp_i,
    input  [0:0]                  m_axi_atg_rlast_i,
    input  [0:0]                  m_axi_atg_rvalid_i,
    output [0:0]                  m_axi_atg_rready_o,

    // subordinate ports
    input ext_start,      
    input ext_stop,
    input logic [AddrWidth-1:0] start_address_i
);

    // Define unused AXI signals for FPGA wrapper
    axi_pkg::region_t
        m_axi_atg_awregion_o, m_axi_atg_arregion_o;
    axi_user_t
        m_axi_atg_wuser_o,
        m_axi_atg_buser_i,
        m_axi_atg_ruser_i;
    
    // Tie unused inputs to 0, leave output floating
    assign m_axi_atg_buser_i = '0;
    assign m_axi_atg_ruser_i = '0;

    // Define AXI struct channels types
    `AXI_TYPEDEF_ALL(axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

    axi_req_t [0:0] m_req;
    axi_resp_t [0:0] m_rsp;

    // Connect AXI structs to flatten in/out AXI ports (m_axi_atg)
    `AXI_ASSIGN_MASTER_TO_FLAT_ARRAY(atg, 1, m_req, m_rsp)

    //-----------------------------------
    // DUT
    //-----------------------------------
    axi_traffic_generator # (
        .MaxReadTxns    (MaxReadTxns),
        .MaxWriteTxns   (MaxWriteTxns),
        .AddrWidth      (AddrWidth),
        .DataWidth      (DataWidth),
        .IdWidth        (IdWidth),
        .UserWidth      (UserWidth),
        .axi_req_t      (axi_req_t),
        .axi_resp_t     (axi_resp_t),
        .axi_aw_chan_t  (axi_aw_chan_t),
        .axi_w_chan_t   (axi_w_chan_t ),
        .axi_b_chan_t   (axi_b_chan_t ),
        .axi_ar_chan_t  (axi_ar_chan_t),
        .axi_r_chan_t   (axi_r_chan_t )
    ) i_axi_traffic_generator (
        .clk_i,
        .rst_ni,
        .mst_req_o (m_req[0]),
        .mst_resp_i(m_rsp[0]),
        .ext_start,
        .ext_stop,
        .start_address_i
    );

endmodule

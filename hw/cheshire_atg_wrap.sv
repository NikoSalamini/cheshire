// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Niko Salamini <nikosalamini@gmail.com>

/// DMA core wrapper for the integration into Cheshire.
module cheshire_atg_wrap #(
  /// Maximum number of AXI read bursts outstanding at the same time
  parameter int unsigned MaxReadTxns   = 32'd32,
  /// Maximum number of AXI write bursts outstanding at the same time
  parameter int unsigned MaxWriteTxns  = 32'd32,
  /// Number of bursts beats to be generated
  parameter int unsigned NumBurstBeats = 32'd256,
  // AXI Bus Types
  parameter int unsigned AddrWidth      = 32'd48,
  parameter int unsigned DataWidth      = 32'd64,
  parameter int unsigned IdWidth        = 32'd4,
  parameter int unsigned UserWidth      = 32'd4,
  parameter type         axi_mst_req_t  = logic,
  parameter type         axi_mst_rsp_t  = logic
) (
  input   logic           clk_i,
  input   logic           rst_ni,
  input   logic           ext_start,      
  input   logic           ext_stop,
  output  axi_mst_req_t   axi_mst_req_o,
  input   axi_mst_rsp_t   axi_mst_rsp_i
);

  /* NEW */
  axi_traffic_generator # (
    .MaxReadTxns    (MaxReadTxns),
    .MaxWriteTxns   (MaxWriteTxns),
    .AddrWidth      (AddrWidth),
    .DataWidth      (DataWidth),
    .IdWidth        (IdWidth),
    .UserWidth      (UserWidth),
    .axi_req_t      (axi_mst_req_t),
    .axi_resp_t     (axi_mst_rsp_t)
  ) i_axi_traffic_generator (
    .clk_i,
    .rst_ni,
    .mst_req_o (axi_mst_req_o),
    .mst_resp_i(axi_mst_rsp_i),
    .ext_start,
    .ext_stop
  );
endmodule

// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Niko Salamini <nikosalamini@gmail.com>

`include "common_cells/registers.svh"
`include "axi/typedef.svh"

module axi_traffic_generator #(
  /// Maximum number of AXI read bursts outstanding at the same time
  parameter int unsigned MaxReadTxns   = 32'd0,
  /// Maximum number of AXI write bursts outstanding at the same time
  parameter int unsigned MaxWriteTxns  = 32'd0,
  /// Number of bursts beats to be generated
  parameter int unsigned NumBurstBeats = 32'd256,
  // AXI Bus Types
  parameter int unsigned AddrWidth     = 32'd0,
  parameter int unsigned DataWidth     = 32'd0,
  parameter int unsigned IdWidth       = 32'd0,
  parameter int unsigned UserWidth     = 32'd0,
  parameter type         axi_req_t     = logic,
  parameter type         axi_resp_t    = logic
)(
  input  logic  clk_i,  // clock
  input  logic  rst_ni, // active low

  // Input control signals
  input ext_start,      
  input ext_stop,

  // Output / Master Port
  output axi_req_t  mst_req_o,
  input  axi_resp_t mst_resp_i
);

/* FSM state */
typedef enum logic [1:0] {IDLE, INIT_ADDR, SEND_UNTIL_LAST} state_e;
state_e state_d, state_q;

/* Burst's beats counter */
localparam int unsigned CntBeatsWidth = (NumBurstBeats > 1) ? $clog2(NumBurstBeats) : 32'd1;
typedef logic [CntBeatsWidth-1:0] cnt_beats_t;
cnt_beats_t cnt_beats_d, cnt_beats_q;

// Outstanding Bursts (TODO)
// localparam int unsigned CntIdxWidth = (MaxWriteTxns > 1) ? $clog2(MaxWriteTxns) : 32'd1;
// typedef logic [CntIdxWidth-1:0]         cnt_idx_t;
// cnt_idx_t cnt_burst_id_d, cnt_burst_id_q;

/* logic to catch the pulses */
logic start_req_d, start_req_q;
logic stop_req_d,  stop_req_q;

// next state logic
always_comb begin

  // sticky pulse regs
  start_req_d = start_req_q;
  stop_req_d  = stop_req_q;

  // capture start pulse
  if (ext_start)
    start_req_d = 1'b1;

  // capture stop pulse
  if (ext_stop)
    stop_req_d = 1'b1;

  // sticky state assignment
  state_d = state_q;

  // default AXI signal values
  mst_req_o.aw_valid  = '0;
  mst_req_o.aw.addr   = '0;
  mst_req_o.aw.id     = '0;
  mst_req_o.w_valid   = '0;
  mst_req_o.w.data    = '0;
  mst_req_o.w.last    = '0;
  mst_req_o.w.strb    = '1; // always configure all the bytes as valid
  mst_req_o.b_ready   = '1; // always equal to 1

  // other aw signals
  mst_req_o.aw.cache  = 4'b1010; // configured WA [3] bit and cacheable [0] bit (TODO: ask how should i configure this)
  mst_req_o.aw.prot   = '0;
  mst_req_o.aw.user   = '1; // TODO: TAG?
  mst_req_o.aw.lock   = '0; // (unused) AxLOCK is used to raise an error if someone writes the region of memory while this transaction is running
  mst_req_o.aw.qos    = '0; // not used

  /* Set the read channel to 0s to have AXI4 compliancy. It cannot be X */
  mst_req_o.ar_valid  = '0;
  mst_req_o.ar.addr   = '0;
  mst_req_o.ar.id     = '0;
  mst_req_o.r_ready   = '1; // always ready to receive reads (unused but it's for compliancy)

  // other ar signals
  mst_req_o.ar.cache  = '0;
  mst_req_o.ar.prot   = '0;
  mst_req_o.ar.user   = '1; // TODO: TAG?
  mst_req_o.ar.lock   = '0; // (unused) AxLOCK is used to raise an error if someone writes the region of memory while this transaction is running
  mst_req_o.ar.qos    = '0; // not used

  // burst parameters. TODO: fixed parameters for now
  mst_req_o.aw.burst  = axi_pkg::BURST_INCR;  // INCR burst: the slave increases the addresses according to AxSIZE
  mst_req_o.aw.len    = NumBurstBeats - 1;    // awlen + 1 = num_beats_burst --> 255 + 1 = 256 beats
  mst_req_o.aw.size   = $clog2(DataWidth/8);  // bytes per beat = 2^size. Set to the max size according to DataWidth. 
  mst_req_o.ar.burst  = axi_pkg::BURST_INCR;
  mst_req_o.ar.len    = NumBurstBeats - 1;
  mst_req_o.ar.size   = $clog2(DataWidth/8);

  /* NB: DataWidth = 64 (8 bytes), We cover a range of addresses from 0-0x800 */

  // burst counter assignment
  cnt_beats_d = cnt_beats_q;

  // switch case 
  case (state_q)

    // pulse received, init parameters, starting sending data
    IDLE: begin
      /* wait for start pulse and aw_ready == 1*/
      if (start_req_q == '1) begin 
          start_req_d = '0;         // clear start request
          state_d     = INIT_ADDR;  // init address   
      end
    end

    // init address
    INIT_ADDR: begin
      /* set aw.addr */
      mst_req_o.aw_valid   = '1; // set aw_valid
      mst_req_o.aw.addr    = '0; // TODO: configurable address range
      if (mst_resp_i.aw_ready) begin
        cnt_beats_d         = '0;               // reset the counter
        state_d             = SEND_UNTIL_LAST;  // next state 
      end
    end

    SEND_UNTIL_LAST: begin
      // w_valid set to 1
      mst_req_o.w_valid = 1'b1;

      // data is the current beat (incremental)
      mst_req_o.w.data = cnt_beats_q;

      // last beat generation
      if (cnt_beats_q == NumBurstBeats - 1)
        mst_req_o.w.last = 1'b1;

      // new beat correctly sent
      if (mst_resp_i.w_ready) begin
        cnt_beats_d = cnt_beats_q + 1;  // Update the counter. It cannot overflow since it perfectly fit the length of the burst.

        // check for the last beat
        if (cnt_beats_q == NumBurstBeats - 1) begin
          if (stop_req_q) begin
            stop_req_d = '0;      // clean stop sticky reg
            state_d    = IDLE;    // back to IDLE
          end else begin
            state_d = INIT_ADDR;  // init the address for the next burst
          end
        end
      end
    end

    default: ; /* nothing */

  endcase
end

// Regs
`FFARN(state_q, state_d, IDLE, clk_i, rst_ni)
`FFARN(cnt_beats_q, cnt_beats_d, '0, clk_i, rst_ni)
`FFARN(start_req_q, start_req_d, '0, clk_i, rst_ni)
`FFARN(stop_req_q,  stop_req_d,  '0, clk_i, rst_ni)

endmodule
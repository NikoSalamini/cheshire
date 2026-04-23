// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Niko Salamini <nikosalamini@gmail.com>

`include "common_cells/registers.svh"
`include "axi/typedef.svh"

module axi_traffic_generator #(
  /// Maximum number of AXI read bursts outstanding at the same time
  parameter int unsigned MaxReadTxns        = 32'd0,
  /// Maximum number of AXI write bursts outstanding at the same time
  parameter int unsigned MaxWriteTxns       = 32'd0,
  /// Number of bursts beats to be generated
  parameter int unsigned NumBurstBeats      = 32'd1,
  /// TAG = [47:14], CACHELINE_IDX = [13:6], BLOCK = [5:3], BLOCK OFFSET = [2:0] (defult)
  /// NumLines
  parameter int unsigned NumLines			      = 32'd256, 
  /// Number of ways of the LLC
  parameter int unsigned SetAssociativity	  = 32'd256, // modified to match the actual use-case
  /// Block Width   
  parameter int unsigned NumBlocks          = 32'd8,
  /// Skip Cycles Width
  parameter integer SkipCyclesWidth = 'd8,
  // AXI Bus Types
  parameter int unsigned AddrWidth     = 32'd0,
  parameter int unsigned DataWidth     = 32'd0,
  parameter int unsigned IdWidth       = 32'd0,
  parameter int unsigned UserWidth     = 32'd0,
  parameter type         axi_req_t     = logic,
  parameter type         axi_resp_t    = logic,
  parameter type         axi_aw_chan_t = logic,
  parameter type         axi_w_chan_t  = logic,
  parameter type         axi_b_chan_t  = logic,
  parameter type         axi_ar_chan_t = logic,
  parameter type         axi_r_chan_t  = logic
)(
  input  logic  clk_i,  // clock
  input  logic  rst_ni, // active low

  // Input control signals
  input ext_start,      
  input ext_stop,

  // Input Address
  input logic [AddrWidth-1:0] start_address_i,

  // Bandwidth control by skipping cycles
  input logic [SkipCyclesWidth-1:0] skip_cycles_i,

  // Output / Master Port
  output axi_req_t  mst_req_o,
  input  axi_resp_t mst_resp_i
);

/* FSM state */
typedef enum logic [2:0] {
  IDLE,
  INIT_START_ADDR,
  SET_NEXT_ADDRESS,
  SEND_BURSTS
} state_e;
state_e state_d, state_q;

// Outstanding Bursts (TODO)
// localparam int unsigned CntIdxWidth = (MaxWriteTxns > 1) ? $clog2(MaxWriteTxns) : 32'd1;
// typedef logic [CntIdxWidth-1:0]         cnt_idx_t;
// cnt_idx_t cnt_burst_id_d, cnt_burst_id_q;

/* Burst's beats counter */
localparam int unsigned CntBeatsWidth = (NumBurstBeats > 1) ? $clog2(NumBurstBeats) : 32'd1;
localparam int unsigned BeatBytes     = DataWidth/8;
typedef logic [CntBeatsWidth-1:0] cnt_beats_t;
cnt_beats_t cnt_beats_d, cnt_beats_q;

/* logic to catch the pulses */
logic start_req_d, start_req_q;
logic stop_req_d,  stop_req_q;

/* logic to configure the start addr and end addr */
logic [AddrWidth-1:0] start_address_d, start_address_q;
logic [AddrWidth-1:0] end_address_d, end_address_q;		// UNUSED (TODO)

/* logic to configure bandwidth control using skip cycles */
logic [SkipCyclesWidth-1:0] skip_cycles_d, skip_cycles_q;

/* Counter for the number of ways already covered */
typedef logic [$clog2(SetAssociativity)-1:0] cnt_ways_t;
cnt_ways_t cnt_ways_d, cnt_ways_q;

/* Counter for the cycles to skip */
logic [SkipCyclesWidth-1:0] cnt_skip_cycles_d, cnt_skip_cycles_q;

/* logic to keep the address to be used for the transaction */
// cacheline idx upper and lower
localparam int unsigned CachelineIdxLower = $clog2(NumBlocks) + $clog2(DataWidth/8);
localparam int unsigned CachelineIdxUpper = ($clog2(NumLines) + CachelineIdxLower) - 1;
// tag idx upper and lower to have different tags on all the ways
localparam int unsigned TagIdxLower	= CachelineIdxUpper + 1;
localparam int unsigned TagIdxUpper	= ($clog2(SetAssociativity) + TagIdxLower) - 1;
// logic for the burst address
logic [AddrWidth-1:0] burst_address_d, burst_address_q;

// next state logic
always_comb begin

  // sticky pulse regs
  start_req_d = start_req_q;
  stop_req_d  = stop_req_q;

  // start and end address, burst address
  start_address_d = start_address_q;
  end_address_d   = end_address_q;
  burst_address_d = burst_address_q;

  // bandwidth control using skip cycles
  skip_cycles_d = skip_cycles_q;

  // counters assignment
  cnt_ways_d        = cnt_ways_q;
  cnt_beats_d       = cnt_beats_q;
  cnt_skip_cycles_d = cnt_skip_cycles_q;

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
  mst_req_o.aw.cache  = 4'b1010;    // configured WA [3] bit and cacheable [0] bit (TODO: ask how should i configure this)
  mst_req_o.aw.prot   = '0;         // prot not used
  mst_req_o.aw.user   = '0;         // TODO: TAG?
  mst_req_o.aw.lock   = '0;         // (unused) AxLOCK is used to raise an error if someone writes the region of memory while this transaction is running
  mst_req_o.aw.qos    = '0;         // not used

  /* Set the read channel to 0s to have AXI4 compliancy. It cannot be X */
  mst_req_o.ar_valid  = '0;
  mst_req_o.ar.addr   = '0;
  mst_req_o.ar.id     = '0;
  mst_req_o.r_ready   = '1; // always ready to receive reads (unused but it's for compliancy)

  // other ar signals
  mst_req_o.ar.cache  = '0; // caching channel not used
  mst_req_o.ar.prot   = '0; // prot not used
  mst_req_o.ar.user   = '0; // TODO: TAG?
  mst_req_o.ar.lock   = '0; // (unused) AxLOCK is used to raise an error if someone writes the region of memory while this transaction is running
  mst_req_o.ar.qos    = '0; // not used

  // burst parameters 
  mst_req_o.aw.burst  = axi_pkg::BURST_INCR;  // INCR burst: the slave increases the addresses according to AxSIZE
  mst_req_o.aw.len    = NumBurstBeats - 1;    // awlen + 1 = num_beats_burst --> 1 - 1 = 0 --> 1 beat
  mst_req_o.aw.size   = $clog2(DataWidth/8);  // bytes per beat = 2^size. Set to the max size according to DataWidth. 
  mst_req_o.ar.burst  = axi_pkg::BURST_INCR;  // just one address
  mst_req_o.ar.len    = NumBurstBeats - 1;    // same for arlen
  mst_req_o.ar.size   = $clog2(DataWidth/8);

  // switch case 
  case (state_q)

    // pulse received, init parameters, starting sending data
    IDLE: begin
      /* wait for start pulse, setting start_address and cnt_skip_cycles */
      if (start_req_q == '1) begin 
        start_address_d = start_address_i;        // init start
        skip_cycles_d   = skip_cycles_i;          // init skip_cycles
        start_req_d     = '0;                     // clear start request
        state_d         = INIT_START_ADDR;        // init address   
      end
    end

    // init start address for the interference
    INIT_START_ADDR: begin
      burst_address_d	  = start_address_q;	// init burst start address
      cnt_skip_cycles_d = skip_cycles_q;    // init skip cycles counter
      state_d = SET_NEXT_ADDRESS;           // setting the next address for the burst
    end

    // set next address for the burst
    SET_NEXT_ADDRESS: begin
      if (cnt_skip_cycles_q == '0) begin
        // set aw.addr 
        mst_req_o.aw_valid  = '1;					      // set aw_valid
        mst_req_o.aw.addr   = burst_address_q;  // start address to be used
        if (mst_resp_i.aw_ready) begin
          // set state and counters
          state_d     = SEND_BURSTS;            // next state 
          cnt_beats_d = '0;					            // reset the counter
          cnt_ways_d	= cnt_ways_q + 1;	        // increase the number of ways that has been targeted
          cnt_skip_cycles_d = skip_cycles_q;    // reset the counter for skip cycles

          /* set the address for the next transaction */
          if (cnt_ways_q == SetAssociativity - 1) begin 
            // move to next cache line
            burst_address_d = burst_address_q;                          // keep all the other bits the same
            burst_address_d[CachelineIdxUpper:CachelineIdxLower] =
              burst_address_q[CachelineIdxUpper:CachelineIdxLower] + 1; // modify the bits involving the cachelines

            // reset the tag for the ways
            burst_address_d[TagIdxUpper:TagIdxLower] = '0;              
            cnt_ways_d = '0;
          end
          else begin
              // move to the next tag
              burst_address_d = burst_address_q;
              burst_address_d[TagIdxUpper:TagIdxLower] = burst_address_q[TagIdxUpper:TagIdxLower] + 1;
          end 
        end
      end
      else begin
        cnt_skip_cycles_d = cnt_skip_cycles_q - 1;
      end
    end

    // send bursts until stop
    SEND_BURSTS: begin
      // w_valid set to 1
      mst_req_o.w_valid = 1'b1;

      // data is all '1
      mst_req_o.w.data = '1;

      // last beat generation
      if (cnt_beats_q == NumBurstBeats - 1) begin
        mst_req_o.w.last = 1'b1;
      end

      // wait until slave is ready
      if (mst_resp_i.w_ready) begin
        // update beat counters
        cnt_beats_d = cnt_beats_q + 1; // on the last beat -> wrapping to 0 

        // check for the last beat of the burst
        if (cnt_beats_q == NumBurstBeats - 1) begin
          if (stop_req_q) begin
            stop_req_d = '0;      // clean stop sticky reg  
            state_d    = IDLE;    // back to IDLE
          end else begin
            state_d = SET_NEXT_ADDRESS;  // init the address for the next burst
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
`FFARN(cnt_ways_q, cnt_ways_d, '0, clk_i, rst_ni)
`FFARN(cnt_skip_cycles_q, cnt_skip_cycles_d, '0, clk_i, rst_ni)
`FFARN(start_req_q, start_req_d, '0, clk_i, rst_ni)
`FFARN(stop_req_q,  stop_req_d, '0, clk_i, rst_ni)
`FFARN(start_address_q,  start_address_d, '0, clk_i, rst_ni)
`FFARN(end_address_q,  end_address_d, '0, clk_i, rst_ni)
`FFARN(burst_address_q,  burst_address_d, '0, clk_i, rst_ni)
`FFARN(skip_cycles_q, skip_cycles_d, '0, clk_i, rst_ni)

endmodule
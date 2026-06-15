// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Niko Salamini <nikosalamini@gmail.com>

/// Measures per-transaction latency on the AXI read and write channels:
///   - AR channel: first cycle arvalid=1  →  cycle where rlast & rvalid = 1
///   - AW channel: first cycle awvalid=1  →  cycle where bvalid = 1
///
/// Up to MaxActiveTrans outstanding transactions are tracked simultaneously
/// via a circular pool of counters managed with head/tail indices.
/// Each counter carries a valid (allocated) flag.
/// FIFO ordering: completions are matched to the oldest outstanding request.
/// If the pool is full when a new request arrives the overflow output is set.
/// Overflow is sticky and cleared only on ext_stop_i.
module stall_checker #(
  parameter int unsigned MaxActiveTrans = 16,
  parameter type         axi_req_t      = logic,
  parameter type         axi_resp_t     = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ext_start_i,
  input  logic ext_stop_i,

  input  axi_req_t  axi_req_i,
  input  axi_resp_t axi_resp_i,

  // Read latency: first cycle arvalid=1  →  rlast & rvalid = 1
  output logic [63:0] ar_max_lat_o,
  output logic [63:0] ar_avg_sum_o,
  output logic [63:0] ar_avg_cnt_o,
  output logic        ar_overflow_o,

  // Write latency: first cycle awvalid=1  →  bvalid = 1
  output logic [63:0] aw_max_lat_o,
  output logic [63:0] aw_avg_sum_o,
  output logic [63:0] aw_avg_cnt_o,
  output logic        aw_overflow_o
);

  // At least 1 pointer bit even when MaxActiveTrans == 1.
  localparam int unsigned IdxW = (MaxActiveTrans > 1) ? $clog2(MaxActiveTrans) : 1;

  // ── Measurement-window control ──────────────────────────────────────────────
  logic start_req_d, start_req_q;
  logic stop_req_d,  stop_req_q;
  logic active_d,    active_q;

  // Previous-cycle valid signals for rising-edge detection (always tracked).
  logic ar_prev_d, ar_prev_q;
  logic aw_prev_d, aw_prev_q;

  // ── AR counter pool ──────────────────────────────────────────────────────────
  logic [MaxActiveTrans-1:0] ar_slot_valid_d, ar_slot_valid_q;
  logic [63:0]               ar_slot_cnt_d   [MaxActiveTrans];
  logic [63:0]               ar_slot_cnt_q   [MaxActiveTrans];
  logic [IdxW-1:0]           ar_head_d,  ar_head_q; // next free slot (enqueue)
  logic [IdxW-1:0]           ar_tail_d,  ar_tail_q; // oldest active slot (dequeue)
  logic                      ar_ovfl_d,  ar_ovfl_q;

  logic [63:0]               ar_max_d,      ar_max_q;
  logic [63:0]               ar_avg_sum_d,  ar_avg_sum_q;
  logic [63:0]               ar_avg_cnt_d,  ar_avg_cnt_q;

  // ── AW counter pool ──────────────────────────────────────────────────────────
  logic [MaxActiveTrans-1:0] aw_slot_valid_d, aw_slot_valid_q;
  logic [63:0]               aw_slot_cnt_d   [MaxActiveTrans];
  logic [63:0]               aw_slot_cnt_q   [MaxActiveTrans];
  logic [IdxW-1:0]           aw_head_d,  aw_head_q;
  logic [IdxW-1:0]           aw_tail_d,  aw_tail_q;
  logic                      aw_ovfl_d,  aw_ovfl_q;

  logic [63:0]               aw_max_d,      aw_max_q;
  logic [63:0]               aw_avg_sum_d,  aw_avg_sum_q;
  logic [63:0]               aw_avg_cnt_d,  aw_avg_cnt_q;

  // Pointer increment with wrap-around.
  function automatic logic [IdxW-1:0] next_ptr(logic [IdxW-1:0] ptr);
    return (ptr == IdxW'(MaxActiveTrans - 1)) ? '0 : (ptr + 1);
  endfunction

  always_comb begin
    // ── Defaults: hold all registered state ──────────────────────────────────
    start_req_d   = start_req_q;
    stop_req_d    = stop_req_q;
    active_d      = active_q;

    // Always track previous valid signals for edge detection (outside active gate).
    ar_prev_d = axi_req_i.ar_valid;
    aw_prev_d = axi_req_i.aw_valid;

    ar_slot_valid_d = ar_slot_valid_q;
    ar_head_d       = ar_head_q;
    ar_tail_d       = ar_tail_q;
    ar_ovfl_d       = ar_ovfl_q;
    ar_max_d        = ar_max_q;
    ar_avg_sum_d    = ar_avg_sum_q;
    ar_avg_cnt_d    = ar_avg_cnt_q;
    for (int i = 0; i < MaxActiveTrans; i++)
      ar_slot_cnt_d[i] = ar_slot_cnt_q[i];

    aw_slot_valid_d = aw_slot_valid_q;
    aw_head_d       = aw_head_q;
    aw_tail_d       = aw_tail_q;
    aw_ovfl_d       = aw_ovfl_q;
    aw_max_d        = aw_max_q;
    aw_avg_sum_d    = aw_avg_sum_q;
    aw_avg_cnt_d    = aw_avg_cnt_q;
    for (int i = 0; i < MaxActiveTrans; i++)
      aw_slot_cnt_d[i] = aw_slot_cnt_q[i];

    // ── Window control ────────────────────────────────────────────────────────
    if (ext_start_i) start_req_d = 1'b1;
    if (ext_stop_i)  stop_req_d  = 1'b1;

    if (start_req_q) begin
      active_d    = 1'b1;
      start_req_d = 1'b0;
    end

    // Stop takes priority: flush pools and all stats.
    if (stop_req_q) begin
      active_d   = 1'b0;
      stop_req_d = 1'b0;

      ar_slot_valid_d = '0;
      ar_head_d = '0; ar_tail_d = '0; ar_ovfl_d = '0;
      ar_max_d = '0; ar_avg_sum_d = '0; ar_avg_cnt_d = '0;
      for (int i = 0; i < MaxActiveTrans; i++)
        ar_slot_cnt_d[i] = '0;

      aw_slot_valid_d = '0;
      aw_head_d = '0; aw_tail_d = '0; aw_ovfl_d = '0;
      aw_max_d = '0; aw_avg_sum_d = '0; aw_avg_cnt_d = '0;
      for (int i = 0; i < MaxActiveTrans; i++)
        aw_slot_cnt_d[i] = '0;

    end else if (active_q) begin

      // ── AR pool ─────────────────────────────────────────────────────────────
      //
      // Step order within the cycle:
      //   1. Increment all occupied slots.
      //   2. Complete: rlast & rvalid  → dequeue from tail, commit stats.
      //   3. Allocate: rising edge of arvalid → enqueue at head.
      //
      // Steps 2 and 3 use the _d values already modified by earlier steps, so a
      // slot freed in step 2 can be immediately reused in step 3 on the same cycle.

      // 1. Increment all occupied slots.
      for (int i = 0; i < MaxActiveTrans; i++) begin
        if (ar_slot_valid_q[i])
          ar_slot_cnt_d[i] = ar_slot_cnt_q[i] + 64'd1;
      end

      // 2. Complete: rlast & rvalid.
      if (axi_resp_i.r_valid && axi_resp_i.r.last && ar_slot_valid_d[ar_tail_q]) begin
        ar_slot_valid_d[ar_tail_q] = 1'b0;
        // Latency = post-increment count (includes both the allocation and response cycles).
        ar_avg_sum_d = ar_avg_sum_q + ar_slot_cnt_d[ar_tail_q];
        ar_avg_cnt_d = ar_avg_cnt_q + 64'd1;
        if (ar_slot_cnt_d[ar_tail_q] > ar_max_q)
          ar_max_d = ar_slot_cnt_d[ar_tail_q];
        ar_tail_d = next_ptr(ar_tail_q);
      end

      // 3. Allocate: rising edge of arvalid.
      if (axi_req_i.ar_valid && !ar_prev_q) begin
        if (ar_slot_valid_d[ar_head_q]) begin
          ar_ovfl_d = 1'b1; // head slot still occupied: pool full
        end else begin
          ar_slot_valid_d[ar_head_q] = 1'b1;
          ar_slot_cnt_d[ar_head_q]   = 64'd0;
          ar_head_d = next_ptr(ar_head_q);
        end
      end

      // ── AW pool ─────────────────────────────────────────────────────────────
      //
      // Same three-step ordering as AR.

      // 1. Increment all occupied slots.
      for (int i = 0; i < MaxActiveTrans; i++) begin
        if (aw_slot_valid_q[i])
          aw_slot_cnt_d[i] = aw_slot_cnt_q[i] + 64'd1;
      end

      // 2. Complete: bvalid.
      if (axi_resp_i.b_valid && aw_slot_valid_d[aw_tail_q]) begin
        aw_slot_valid_d[aw_tail_q] = 1'b0;
        aw_avg_sum_d = aw_avg_sum_q + aw_slot_cnt_d[aw_tail_q];
        aw_avg_cnt_d = aw_avg_cnt_q + 64'd1;
        if (aw_slot_cnt_d[aw_tail_q] > aw_max_q)
          aw_max_d = aw_slot_cnt_d[aw_tail_q];
        aw_tail_d = next_ptr(aw_tail_q);
      end

      // 3. Allocate: rising edge of awvalid.
      if (axi_req_i.aw_valid && !aw_prev_q) begin
        if (aw_slot_valid_d[aw_head_q]) begin
          aw_ovfl_d = 1'b1;
        end else begin
          aw_slot_valid_d[aw_head_q] = 1'b1;
          aw_slot_cnt_d[aw_head_q]   = 64'd0;
          aw_head_d = next_ptr(aw_head_q);
        end
      end

    end // active_q
  end

  // ── Flip-flop assignments ────────────────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_req_q   <= '0;
      stop_req_q    <= '0;
      active_q      <= '0;
      ar_prev_q     <= '0;
      aw_prev_q     <= '0;

      ar_slot_valid_q <= '0;
      ar_head_q       <= '0;
      ar_tail_q       <= '0;
      ar_ovfl_q       <= '0;
      ar_max_q        <= '0;
      ar_avg_sum_q    <= '0;
      ar_avg_cnt_q    <= '0;
      for (int i = 0; i < MaxActiveTrans; i++)
        ar_slot_cnt_q[i] <= '0;

      aw_slot_valid_q <= '0;
      aw_head_q       <= '0;
      aw_tail_q       <= '0;
      aw_ovfl_q       <= '0;
      aw_max_q        <= '0;
      aw_avg_sum_q    <= '0;
      aw_avg_cnt_q    <= '0;
      for (int i = 0; i < MaxActiveTrans; i++)
        aw_slot_cnt_q[i] <= '0;
    end else begin
      start_req_q   <= start_req_d;
      stop_req_q    <= stop_req_d;
      active_q      <= active_d;
      ar_prev_q     <= ar_prev_d;
      aw_prev_q     <= aw_prev_d;

      ar_slot_valid_q <= ar_slot_valid_d;
      ar_head_q       <= ar_head_d;
      ar_tail_q       <= ar_tail_d;
      ar_ovfl_q       <= ar_ovfl_d;
      ar_max_q        <= ar_max_d;
      ar_avg_sum_q    <= ar_avg_sum_d;
      ar_avg_cnt_q    <= ar_avg_cnt_d;
      for (int i = 0; i < MaxActiveTrans; i++)
        ar_slot_cnt_q[i] <= ar_slot_cnt_d[i];

      aw_slot_valid_q <= aw_slot_valid_d;
      aw_head_q       <= aw_head_d;
      aw_tail_q       <= aw_tail_d;
      aw_ovfl_q       <= aw_ovfl_d;
      aw_max_q        <= aw_max_d;
      aw_avg_sum_q    <= aw_avg_sum_d;
      aw_avg_cnt_q    <= aw_avg_cnt_d;
      for (int i = 0; i < MaxActiveTrans; i++)
        aw_slot_cnt_q[i] <= aw_slot_cnt_d[i];
    end
  end

  // ── Output assignments ───────────────────────────────────────────────────────
  assign ar_max_lat_o  = ar_max_q;
  assign ar_avg_sum_o  = ar_avg_sum_q;
  assign ar_avg_cnt_o  = ar_avg_cnt_q;
  assign ar_overflow_o = ar_ovfl_q;

  assign aw_max_lat_o  = aw_max_q;
  assign aw_avg_sum_o  = aw_avg_sum_q;
  assign aw_avg_cnt_o  = aw_avg_cnt_q;
  assign aw_overflow_o = aw_ovfl_q;

endmodule

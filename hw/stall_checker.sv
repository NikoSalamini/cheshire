// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Niko Salamini <nikosalamini@gmail.com>

/// Tracks the worst-case (maximum) and average consecutive stall cycles per
/// AXI channel and per user signal value. A stall is defined as valid=1 &&
/// ready=0. One 64-bit max register and two 64-bit average registers (sum and
/// event count) per (channel, user_value) pair: 5 channels x NumUserVals user
/// values (0 .. NumUserVals-1). Average = avg_sum / avg_cnt.
/// NB: the overflow on the avg_cnt is not taken into account!
module stall_checker #(
  parameter int unsigned NumUserVals = 32'd8,
  parameter int unsigned UserWidth   = 32'd0,
  parameter type         axi_req_t   = logic,
  parameter type         axi_resp_t  = logic
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ext_start_i,
  input  logic ext_stop_i,

  input  axi_req_t  axi_req_i,
  input  axi_resp_t axi_resp_i,

  // Worst-case stall cycles per user value [0] .. [NumUserVals-1]
  output logic [63:0] aw_max_stall_o [NumUserVals],
  output logic [63:0] ar_max_stall_o [NumUserVals],
  output logic [63:0] w_max_stall_o  [NumUserVals],
  output logic [63:0] b_max_stall_o  [NumUserVals],
  output logic [63:0] r_max_stall_o  [NumUserVals],

  // Average stall cycles per user value: average = avg_sum / avg_cnt
  // NB: the overflow on the avg_cnt is not taken into account!
  output logic [63:0] aw_avg_sum_o [NumUserVals],
  output logic [63:0] aw_avg_cnt_o [NumUserVals],
  output logic [63:0] ar_avg_sum_o [NumUserVals],
  output logic [63:0] ar_avg_cnt_o [NumUserVals],
  output logic [63:0] w_avg_sum_o  [NumUserVals],
  output logic [63:0] w_avg_cnt_o  [NumUserVals],
  output logic [63:0] b_avg_sum_o  [NumUserVals],
  output logic [63:0] b_avg_cnt_o  [NumUserVals],
  output logic [63:0] r_avg_sum_o  [NumUserVals],
  output logic [63:0] r_avg_cnt_o  [NumUserVals]
);

  // Sticky pulse registers and active level
  logic start_req_d, start_req_q;
  logic stop_req_d,  stop_req_q;
  logic active_d,    active_q;

  // Running counters: consecutive stall cycles in the current stall burst
  logic [63:0] aw_run_d [NumUserVals], aw_run_q [NumUserVals];
  logic [63:0] ar_run_d [NumUserVals], ar_run_q [NumUserVals];
  logic [63:0] w_run_d  [NumUserVals], w_run_q  [NumUserVals];
  logic [63:0] b_run_d  [NumUserVals], b_run_q  [NumUserVals];
  logic [63:0] r_run_d  [NumUserVals], r_run_q  [NumUserVals];

  // Max registers: worst-case stall duration observed so far
  logic [63:0] aw_max_d [NumUserVals], aw_max_q [NumUserVals];
  logic [63:0] ar_max_d [NumUserVals], ar_max_q [NumUserVals];
  logic [63:0] w_max_d  [NumUserVals], w_max_q  [NumUserVals];
  logic [63:0] b_max_d  [NumUserVals], b_max_q  [NumUserVals];
  logic [63:0] r_max_d  [NumUserVals], r_max_q  [NumUserVals];

  // Average registers: sum of all stall cycles and count of completed stall bursts
  logic [63:0] aw_sum_d [NumUserVals], aw_sum_q [NumUserVals];
  logic [63:0] ar_sum_d [NumUserVals], ar_sum_q [NumUserVals];
  logic [63:0] w_sum_d  [NumUserVals], w_sum_q  [NumUserVals];
  logic [63:0] b_sum_d  [NumUserVals], b_sum_q  [NumUserVals];
  logic [63:0] r_sum_d  [NumUserVals], r_sum_q  [NumUserVals];

  logic [63:0] aw_cnt_d [NumUserVals], aw_cnt_q [NumUserVals];
  logic [63:0] ar_cnt_d [NumUserVals], ar_cnt_q [NumUserVals];
  logic [63:0] w_cnt_d  [NumUserVals], w_cnt_q  [NumUserVals];
  logic [63:0] b_cnt_d  [NumUserVals], b_cnt_q  [NumUserVals];
  logic [63:0] r_cnt_d  [NumUserVals], r_cnt_q  [NumUserVals];

  always_comb begin
    // capture start/stop pulses into sticky registers
    start_req_d = start_req_q;
    stop_req_d  = stop_req_q;
    active_d    = active_q;

    if (ext_start_i) start_req_d = 1'b1;
    if (ext_stop_i)  stop_req_d  = 1'b1;

    if (start_req_q) begin
      active_d    = 1'b1;
      start_req_d = 1'b0;
    end
    if (stop_req_q) begin
      active_d   = 1'b0;
      stop_req_d = 1'b0;
    end

    for (int u = 0; u < NumUserVals; u++) begin
      // Default: hold
      aw_run_d[u] = aw_run_q[u];
      aw_max_d[u] = aw_max_q[u];
      aw_sum_d[u] = aw_sum_q[u];
      aw_cnt_d[u] = aw_cnt_q[u];
      ar_run_d[u] = ar_run_q[u];
      ar_max_d[u] = ar_max_q[u];
      ar_sum_d[u] = ar_sum_q[u];
      ar_cnt_d[u] = ar_cnt_q[u];
      w_run_d[u]  = w_run_q[u];
      w_max_d[u]  = w_max_q[u];
      w_sum_d[u]  = w_sum_q[u];
      w_cnt_d[u]  = w_cnt_q[u];
      b_run_d[u]  = b_run_q[u];
      b_max_d[u]  = b_max_q[u];
      b_sum_d[u]  = b_sum_q[u];
      b_cnt_d[u]  = b_cnt_q[u];
      r_run_d[u]  = r_run_q[u];
      r_max_d[u]  = r_max_q[u];
      r_sum_d[u]  = r_sum_q[u];
      r_cnt_d[u]  = r_cnt_q[u];

      if (stop_req_q) begin
        aw_run_d[u] = '0; aw_max_d[u] = '0; aw_sum_d[u] = '0; aw_cnt_d[u] = '0;
        ar_run_d[u] = '0; ar_max_d[u] = '0; ar_sum_d[u] = '0; ar_cnt_d[u] = '0;
        w_run_d[u]  = '0; w_max_d[u]  = '0; w_sum_d[u]  = '0; w_cnt_d[u]  = '0;
        b_run_d[u]  = '0; b_max_d[u]  = '0; b_sum_d[u]  = '0; b_cnt_d[u]  = '0;
        r_run_d[u]  = '0; r_max_d[u]  = '0; r_sum_d[u]  = '0; r_cnt_d[u]  = '0;
      end else if (active_q) begin

      // AW: master presents, slave not ready
      if (axi_req_i.aw_valid && !axi_resp_i.aw_ready &&
          (axi_req_i.aw.user == UserWidth'(u))) begin
        aw_run_d[u] = aw_run_q[u] + 64'd1;
        aw_sum_d[u] = aw_sum_q[u] + 64'd1;
        if (aw_run_d[u] > aw_max_q[u])
          aw_max_d[u] = aw_run_d[u];
      end else begin
        aw_run_d[u] = '0;
        if (aw_run_q[u] > '0) aw_cnt_d[u] = aw_cnt_q[u] + 64'd1;
      end

      // AR: master presents, slave not ready
      if (axi_req_i.ar_valid && !axi_resp_i.ar_ready &&
          (axi_req_i.ar.user == UserWidth'(u))) begin
        ar_run_d[u] = ar_run_q[u] + 64'd1;
        ar_sum_d[u] = ar_sum_q[u] + 64'd1;
        if (ar_run_d[u] > ar_max_q[u])
          ar_max_d[u] = ar_run_d[u];
      end else begin
        ar_run_d[u] = '0;
        if (ar_run_q[u] > '0) ar_cnt_d[u] = ar_cnt_q[u] + 64'd1;
      end

      // W: master presents, slave not ready
      if (axi_req_i.w_valid && !axi_resp_i.w_ready &&
          (axi_req_i.w.user == UserWidth'(u))) begin
        w_run_d[u] = w_run_q[u] + 64'd1;
        w_sum_d[u] = w_sum_q[u] + 64'd1;
        if (w_run_d[u] > w_max_q[u])
          w_max_d[u] = w_run_d[u];
      end else begin
        w_run_d[u] = '0;
        if (w_run_q[u] > '0) w_cnt_d[u] = w_cnt_q[u] + 64'd1;
      end

      // B: slave presents response, master not ready
      if (axi_resp_i.b_valid && !axi_req_i.b_ready &&
          (axi_resp_i.b.user == UserWidth'(u))) begin
        b_run_d[u] = b_run_q[u] + 64'd1;
        b_sum_d[u] = b_sum_q[u] + 64'd1;
        if (b_run_d[u] > b_max_q[u])
          b_max_d[u] = b_run_d[u];
      end else begin
        b_run_d[u] = '0;
        if (b_run_q[u] > '0) b_cnt_d[u] = b_cnt_q[u] + 64'd1;
      end

      // R: slave presents response, master not ready
      if (axi_resp_i.r_valid && !axi_req_i.r_ready &&
          (axi_resp_i.r.user == UserWidth'(u))) begin
        r_run_d[u] = r_run_q[u] + 64'd1;
        r_sum_d[u] = r_sum_q[u] + 64'd1;
        if (r_run_d[u] > r_max_q[u])
          r_max_d[u] = r_run_d[u];
      end else begin
        r_run_d[u] = '0;
        if (r_run_q[u] > '0) r_cnt_d[u] = r_cnt_q[u] + 64'd1;
      end

      end // active_q
    end
  end

  // default assignment
  assign aw_max_stall_o = aw_max_q;
  assign ar_max_stall_o = ar_max_q;
  assign w_max_stall_o  = w_max_q;
  assign b_max_stall_o  = b_max_q;
  assign r_max_stall_o  = r_max_q;

  assign aw_avg_sum_o = aw_sum_q;  assign aw_avg_cnt_o = aw_cnt_q;
  assign ar_avg_sum_o = ar_sum_q;  assign ar_avg_cnt_o = ar_cnt_q;
  assign w_avg_sum_o  = w_sum_q;   assign w_avg_cnt_o  = w_cnt_q;
  assign b_avg_sum_o  = b_sum_q;   assign b_avg_cnt_o  = b_cnt_q;
  assign r_avg_sum_o  = r_sum_q;   assign r_avg_cnt_o  = r_cnt_q;

  // flip flop assignments
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_req_q <= '0;
      stop_req_q  <= '0;
      active_q    <= '0;
      for (int u = 0; u < NumUserVals; u++) begin
        aw_run_q[u] <= '0;  aw_max_q[u] <= '0;  aw_sum_q[u] <= '0;  aw_cnt_q[u] <= '0;
        ar_run_q[u] <= '0;  ar_max_q[u] <= '0;  ar_sum_q[u] <= '0;  ar_cnt_q[u] <= '0;
        w_run_q[u]  <= '0;  w_max_q[u]  <= '0;  w_sum_q[u]  <= '0;  w_cnt_q[u]  <= '0;
        b_run_q[u]  <= '0;  b_max_q[u]  <= '0;  b_sum_q[u]  <= '0;  b_cnt_q[u]  <= '0;
        r_run_q[u]  <= '0;  r_max_q[u]  <= '0;  r_sum_q[u]  <= '0;  r_cnt_q[u]  <= '0;
      end
    end else begin
      start_req_q <= start_req_d;
      stop_req_q  <= stop_req_d;
      active_q    <= active_d;
      for (int u = 0; u < NumUserVals; u++) begin
        aw_run_q[u] <= aw_run_d[u];  aw_max_q[u] <= aw_max_d[u];  aw_sum_q[u] <= aw_sum_d[u];  aw_cnt_q[u] <= aw_cnt_d[u];
        ar_run_q[u] <= ar_run_d[u];  ar_max_q[u] <= ar_max_d[u];  ar_sum_q[u] <= ar_sum_d[u];  ar_cnt_q[u] <= ar_cnt_d[u];
        w_run_q[u]  <= w_run_d[u];   w_max_q[u]  <= w_max_d[u];   w_sum_q[u]  <= w_sum_d[u];   w_cnt_q[u]  <= w_cnt_d[u];
        b_run_q[u]  <= b_run_d[u];   b_max_q[u]  <= b_max_d[u];   b_sum_q[u]  <= b_sum_d[u];   b_cnt_q[u]  <= b_cnt_d[u];
        r_run_q[u]  <= r_run_d[u];   r_max_q[u]  <= r_max_d[u];   r_sum_q[u]  <= r_sum_d[u];   r_cnt_q[u]  <= r_cnt_d[u];
      end
    end
  end

endmodule

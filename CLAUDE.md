# Cheshire SoC — Development Notes

## Adding / removing AXI crossbar master ports

### Current state (as of 2026-07-03)

The config `CheshireConfig` in `hw/cheshire_pkg.sv` has both `Atg: 1` and `Atg2: 1`.
With `SerialLink=1` this yields **7 crossbar masters** (indices 0–6):

| Index | Master      |
|-------|-------------|
| 0     | CVA6 core 0 |
| 1     | debug module |
| 2     | DMA         |
| 3     | serial link |
| 4     | VGA         |
| 5     | ATG1        |
| 6     | ATG2        |

`AxiIn.num_in = 7` is computed at elaboration time by `gen_axi_in` in `cheshire_pkg.sv`.

---

## AXI-RT register package — keeping it in sync with num_in

**Design rule: always keep `num_in = 6`** (the value the pre-generated reg files were built for).
The way to do this is to keep exactly two of {SerialLink, Vga, Usb} disabled. Currently
`Usb: 0` and `Vga: 0` achieve this. Do NOT re-enable Vga without also disabling another
feature (or regenerating the reg files — see below).

**Why Vga was disabled** (same rationale as Usb): adding Atg2 pushed num_in from 6 to 7.
The pre-generated `axi_rt_reg_pkg.sv` has per-manager arrays sized `[5:0]` (6 entries, indices 0–5).
If num_in=7, manager 6 gets `imtu_enable[6]='x` from the reg_top. In `axi_rt_unit.sv` the budget
counter resets `budget_left=0` → `budget_spent=1`, so `global_isolate = 1 & 'x = 'x`, making
`isolate_i='x` in `axi_isolate`. Because `axi_isolate` resets to `Isolate` state and transitions to
`Normal` only when `!isolate_i`, with `!x=x` (false in Modelsim), it never de-isolates →
**ATG2 is permanently blocked even in bypass mode.**

The clean fix: keep num_in=6 by disabling one extra optional master.

### AXI-RT register package details

`axi_rt_reg_pkg.sv` is a code-generated file (from `axi_rt.hjson` via `regtool`). It contains
hardcoded per-manager array sizes. When `num_in` changes, these arrays must be updated manually
because `regtool` is not available in this environment.

### File to edit

```
.bender/git/checkouts/axi_rt-7cef46f372eaf0fb/src/regs/axi_rt_reg_pkg.sv
```

### What to change

There are two array dimension tokens to update:

| Token | Meaning | New value formula |
|-------|---------|-------------------|
| `[N-1:0]` on per-manager arrays | one slot per manager | `[num_in-1:0]` |
| `[N*NumSub-1:0]` on per-region arrays | `NumSub=2` regions per manager | `[num_in*2-1:0]` |

**Per-manager arrays** (7 occurrences in the two struct definitions):

```sv
// reg2hw_t
axi_rt_reg2hw_rt_enable_mreg_t    [N-1:0] rt_enable;
axi_rt_reg2hw_len_limit_mreg_t    [N-1:0] len_limit;
axi_rt_reg2hw_imtu_enable_mreg_t  [N-1:0] imtu_enable;
axi_rt_reg2hw_imtu_abort_mreg_t   [N-1:0] imtu_abort;
// hw2reg_t
axi_rt_hw2reg_rt_bypassed_mreg_t  [N-1:0] rt_bypassed;
axi_rt_hw2reg_isolate_mreg_t      [N-1:0] isolate;
axi_rt_hw2reg_isolated_mreg_t     [N-1:0] isolated;
```

**Per-region arrays** (12 occurrences, `M = N*2`):

```sv
// reg2hw_t
axi_rt_reg2hw_start_addr_sub_low_mreg_t  [M-1:0] start_addr_sub_low;
axi_rt_reg2hw_start_addr_sub_high_mreg_t [M-1:0] start_addr_sub_high;
axi_rt_reg2hw_end_addr_sub_low_mreg_t    [M-1:0] end_addr_sub_low;
axi_rt_reg2hw_end_addr_sub_high_mreg_t   [M-1:0] end_addr_sub_high;
axi_rt_reg2hw_write_budget_mreg_t        [M-1:0] write_budget;
axi_rt_reg2hw_read_budget_mreg_t         [M-1:0] read_budget;
axi_rt_reg2hw_write_period_mreg_t        [M-1:0] write_period;
axi_rt_reg2hw_read_period_mreg_t         [M-1:0] read_period;
// hw2reg_t
axi_rt_hw2reg_write_budget_left_mreg_t   [M-1:0] write_budget_left;
axi_rt_hw2reg_read_budget_left_mreg_t    [M-1:0] read_budget_left;
axi_rt_hw2reg_write_period_left_mreg_t   [M-1:0] write_period_left;
axi_rt_hw2reg_read_period_left_mreg_t    [M-1:0] read_period_left;
```

**RESVAL parameter widths** (3 occurrences near the bottom of the file):

```sv
parameter logic [N-1:0] AXI_RT_RT_BYPASSED_RESVAL = N'h 0;
parameter logic [N-1:0] AXI_RT_ISOLATE_RESVAL      = N'h 0;
parameter logic [N-1:0] AXI_RT_ISOLATED_RESVAL      = N'h 0;
```

### Quick-reference table

| num_in | Per-manager `[N-1:0]` | Per-region `[M-1:0]` | RESVAL literal |
|--------|-----------------------|----------------------|----------------|
| 6      | `[5:0]`               | `[11:0]`             | `6'h 0`        |
| 7      | `[6:0]`               | `[13:0]`             | `7'h 0`        |
| 8      | `[7:0]`               | `[15:0]`             | `8'h 0`        |

### Note on axi_rt_reg_top.sv

`axi_rt_reg_top.sv` does NOT need to change. It only drives indices 0 to `num_in_original-1`
in the hw2reg arrays. Any higher index stays `'0` (reset), meaning that master runs in
AXI-RT bypass mode (no rate limiting), which is acceptable for ATG2.

---

## ATG2 — files changed to add a second traffic generator

All changes relative to the upstream Cheshire commit when ATG2 was added:

### `hw/cheshire_pkg.sv`
- Added `bit Atg2;` field to `cheshire_cfg_t` (after `bit Atg;`)
- Added `aw_bt atg2;` field to `axi_in_t` (after `aw_bt atg;`)
- Added `if (cfg.Atg2) begin i++; ret.atg2 = i; end` in `gen_axi_in` (after the Atg block)
- Added `Atg2 : 1,` in the default config struct

### `hw/cheshire_soc.sv`
- Added ports: `mode_i2`, `start_address_i2`, `skip_cycles_i2`
- Replaced the hardcoded `always_comb` block that overwrote `tagger_req_mod.aw/ar.user[2]`
  for 0xC0 addresses with a plain `assign tagger_req_mod = tagger_req;`
- Added `gen_atg_ctrl` generate block (shared between ATG1 and ATG2): owns
  `ext_start_mod` / `ext_stop_mod` and the address-decode `always_ff` that sets them
- Simplified `gen_atg` block: removed its own `ext_start_mod` declarations and points
  to `gen_atg_ctrl.ext_start_mod` / `gen_atg_ctrl.ext_stop_mod` via hierarchical reference
- Added `gen_atg2` generate block: instantiates a second `cheshire_atg_wrap`, an `axi_cut`
  (reuses `AtgPostCut` parameter), and a `stall_checker`; wired to `AxiIn.atg2` and
  the shared `gen_atg_ctrl.ext_start_mod`

### `sw/tests/llc_partitioning_atg.c`
- New SW test: configures 3 LLC partitions (core 128 sets, ATG1 64, ATG2 64), tagger
  address regions, AXI-RT for all three masters, then triggers both ATGs simultaneously
  via shared `ext_start_mod` (read to `0x00001000`)

### To revert to 6 masters (remove ATG2)

1. In `hw/cheshire_pkg.sv`: remove the `Atg2` field from `cheshire_cfg_t`, `axi_in_t`,
   `gen_axi_in`, and the default config.
2. In `hw/cheshire_soc.sv`: remove ports `mode_i2`/`start_address_i2`/`skip_cycles_i2`,
   the `gen_atg2` block, and the `gen_atg_ctrl` block; restore `ext_start_mod`/`ext_stop_mod`
   declarations and `always_ff` inside `gen_atg`; restore `assign tagger_req_mod = tagger_req`
   or re-add the address-decode override if needed.
3. In `axi_rt_reg_pkg.sv`: change `[6:0]` → `[5:0]` (7 occurrences) and
   `[13:0]` → `[11:0]` (12 occurrences) and RESVAL `7'h` → `6'h` (3 occurrences).

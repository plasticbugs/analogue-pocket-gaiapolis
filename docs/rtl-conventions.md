# RTL conventions for the Gaiapolis core

Shared rules so independently written blocks fit together without a second
pass. Read `docs/hardware.md` and `docs/prior-art.md` first.

## Language and tools

- SystemVerilog only (`.sv`), `default_nettype none`, one module per file,
  synthesisable with Quartus 18.1 **and** clean under
  `verilator --lint-only -Wall`. Width mismatches get an explicit cast rather
  than a waiver; genuine don't-cares get a narrow `lint_off` with a reason on
  the line above.
- No `initial` blocks for logic, no latches, no asynchronous resets: one
  synchronous active-high `reset` per module.
- Block RAMs: register the read data (one-cycle latency) so Quartus infers
  M10K. For byte-enable writes use 2D-packed lanes (`logic [1:0][7:0]`) --
  partial-select writes fail to infer byte enables and explode into registers
  (METHODOLOGY section 5.5).
- Every block ships with a Verilator bench: a C++ driver (`sim/tb_*.cpp`) over
  a thin SV wrapper (`sim/tb_*_top.sv`), run by `sim/run_*.sh`, printing
  PASS/FAIL and exiting non-zero on failure.

## The gate

`tools/render_model.py` is the executable spec. It is pixel-exact against MAME
across `artifacts/states/` (`tools/regress_render.sh`), so video RTL is checked
against **the model**, not against MAME directly -- the model can be asked for
one layer at a time, which MAME cannot.

Every video block therefore has a frozen-state bench that loads a dumped state,
renders a frame, and requires **zero** differing pixels against the model. Run
it before every commit; it takes seconds.

## Unimplemented modes

The state corpus does not exercise every mode these chips support. Where a mode
is unverified, the RTL raises an `unsupported` output rather than rendering
something plausible and wrong, and the bench fails on it. Adding a mode means
adding a state that exercises it first.

Currently flagged in `k056832_tilemap.sv`: scroll modes other than xy scroll,
global screen flip, and a page span of three.

## Clocks

One system clock, **`clk` = 96 MHz**. Machine parts run on clock enables:

| enable | rate | consumer |
|---|---|---|
| `cen_16m` | 16.000 MHz | 68000 |
| `cen_8m`  | 8.000 MHz  | Z80, pixel clock |
| `cen_pix` | 8.000 MHz  | video scan-out (512 clocks per 64 us line) |

A block must never gate `clk`; it samples its `cen`. The video line budget is
**6,144 clocks** (512 pixel clocks x 12). Blocks that render into line buffers
report their worst-case line so the budget stays visible: the tilemap layers
currently use ~2,660.

## Memory

Four independent buses, partitioned in `docs/hardware.md` section 11. Graphics
fetches use a level `req` / one-cycle `ack` handshake so a block can sit behind
an arbiter without changing.

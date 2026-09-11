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
global screen flip, and a page span of three. In `k053936_roz.sv`: the
per-line "super" mode.

Generated ROM contents (`rtl/data/*.hex`) are produced by a tool in `tools/`
and loaded with `$readmemh`, never by an `initial` block of logic.

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

## A request is still standing in the clock its ack is visible

The request/ack convention (level request, one-cycle ack) means the client
sees the ack and drops its request one clock later. A server that returns
to idle in the clock it raises the ack therefore sees the *old* request
still high and starts it again. `gaia_mem.sv` did this on all three of its
ports; the reads only wasted a slot, but the PSRAM writer's repeat carried
the next byte's data (the FIFO had already popped) and corrupted every
word it loaded. Idle arbitration must mask a request being acked right
now: `if (req && !ack)`. `sim/run_mem.sh` is the gate.

## CPU bus strobes are levels; device side effects need edges

A tv80 or TG68K bus cycle holds its strobes for whole T-states -- 24 system
clocks for the Z80's WR at 8 MHz. A register write that is idempotent does
not care, but any port with a side effect (the K054539's streaming pointer
steps on every access to 0x22d) sees one access per *clock* unless the
strobe is edge-detected. `gaia_sound.sv` turns WR into a one-clock pulse on
the first clock of the strobe (the data is valid throughout) and the
K054539's read pointer advances when the read strobe ends. The symptom was
the Z80's RAM test through that port failing (items 4L/4G on the self-test).

## What Quartus will and will not make a block RAM of

Verilator does not care how an array is written; Quartus does, and an array
it cannot infer as RAM becomes registers with a mux per read -- the sprite
rasterizer's two Z buffers and shadow flags were 16K ALUTs that way, most of
the device. The rules that held, from the map report's "uninferred RAM"
lines (`Info (276xxx)` in the log):

* **One process writes an array.** A second `always_ff` writing it is
  "multiple constant drivers" (the EEPROM array, the K054539 register file).
  Route the other writer's request through the owning process.
* **No asynchronous reads.** `if (mem[i] >= x)` in the same cycle the
  address is formed keeps the whole array in logic. Read a cycle ahead into a
  register: the sprite draw addresses the next pixel's Z while it writes the
  current one (`k053247_draw.sv`), the counting sort takes a read state
  before each read-modify-write (`k053247_objlist.sv`), the K054539 fetches a
  channel's 15 parameter bytes one a cycle (`k054539.sv`).
* **True dual port needs the template**: each port reads *or* writes in a
  cycle (`if (we) begin mem[a] <= d; q <= d; end else q <= mem[a];`), and a
  byte-enabled port is a separate byte-wide RAM per lane (the K054539's chip
  RAM is `ram_lo`/`ram_hi`).
* **Two readers cost two copies.** Fine for a palette, not for 128 KB of tile
  RAM -- that is why the K056832's VRAM lives in the Pocket's SRAM.
* Tiny tables (a 16-entry pan table, 128 volume entries) stay logic; that is
  expected and cheap.

## Timing at 96 MHz: one multiply, or one wide add, per cycle

The design's two worst paths after the fit were both arithmetic written as
one expression: the K054539's `(a * b >> 14) * g >> 14` volume product
(-7.6 ns) and the ROZ's control decode feeding `start + inc * line` (-6.6
ns). Both had thousands of idle cycles to spend, so they became short
pipelines: a table lookup, a multiply, a multiply, a cap, one state each.
The frozen-state gates confirm the numbers did not change. A 16x16 multiply
in a DSP block is about 5 ns; two in series with an adder and a compare is
not a 10.4 ns cycle.

## Loads arrive during reset

The bench and the Pocket both hold the machine in reset while the ROM image
and a save file are written into it, so a memory's load port must work with
`reset` asserted. A `if (reset) ... else if (ld_we)` chain silently drops
the load: the EEPROM's default image went missing that way and the
self-test's 28B item went BAD while `sim/run_eeprom.sh` -- which loaded
after reset -- still passed. The gate now loads during reset as the system
does; keep it that way for any new loadable memory.

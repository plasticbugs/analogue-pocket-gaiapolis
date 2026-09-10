//------------------------------------------------------------------------------
// K053247 object list: builds and orders the sprite draw list once per frame.
//
// Each of the 256 sprite entries can contribute a solid object, a shadow
// object, or both. konamigx_mixer keys every object with
//
//     order = pri<<24 | zcode<<16 | offs<<5 | drawmode<<4 | shadow
//
// and draws them in descending order. Because `offs` is part of the key, no
// two objects can tie on the full 32 bits, so the ordering is well defined by
// the key alone -- the reverse-then-stable-sort in the C++ never has a tie to
// break. offs is the sprite's word offset (entry n at n*8), so order[15:8] is
// the entry index and the whole record fits in the order word itself; the
// rasterizer re-reads geometry from sprite RAM.
//
// Sorting is two stable counting-sort passes (LSD zcode, then MSD priority),
// ~5,600 clocks against the ~245,000 a 40-line vblank gives at 96 MHz.
// Measured object counts peak at 124 (docs/hardware.md).
//------------------------------------------------------------------------------
`default_nettype none

module k053247_objlist #(
    parameter int MAXOBJ = 512          // 256 entries x (solid + shadow)
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        start,          // pulse once per frame, in vblank
    output logic        done,
    output logic        busy,

    // Configuration latched by the caller from the chip registers. Only a few
    // bits of each matter here: opset[4] inverts z order, opset[5] selects the
    // shadow priority source, objset1[5] is SD0EN.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] opset,          // k053247 register 0x0c
    input  logic  [7:0] objset1,        // k053246 register 5
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic  [2:0] shadowon,       // K054338-derived, one bit per table
    input  logic  [7:0] shdpri [3],     // K055555 SHAD1/2/3 priority

    // sprite RAM, 2048 words, synchronous read
    output logic [10:0] ram_addr,
    input  logic [15:0] ram_q,

    // ordered list, read back by the rasterizer
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [9:0] list_idx,   // MAXOBJ may need fewer bits
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] list_q,
    output logic  [9:0] count,

    output logic        overflow        // more objects than MAXOBJ
);
    localparam int AW = $clog2(MAXOBJ);

    // ping-pong list storage
    logic [31:0] la [MAXOBJ];
    logic [31:0] lb [MAXOBJ];
    logic        which;                 // 0: result in la, 1: result in lb
    logic [31:0] la_q, lb_q;
    logic [AW-1:0] list_rd;             // driven by the sort FSM while busy
    // the rasterizer drives list_idx once the list is built
    wire  [AW-1:0] rdaddr = busy ? list_rd : list_idx[AW-1:0];
    always_ff @(posedge clk) begin
        la_q <= la[rdaddr];
        lb_q <= lb[rdaddr];
    end
    assign list_q = which ? lb_q : la_q;

    // counting-sort buckets
    logic [9:0] cnt [256];
    logic [7:0] cnt_idx;
    logic [9:0] acc;

    typedef enum logic [3:0] {
        O_IDLE, O_B0, O_B1, O_B2, O_EMIT, O_NEXTENT,
        O_CLR, O_CNT, O_CNTW, O_CNT2, O_PRE, O_SCAT, O_SCATW, O_SCAT2,
        O_NEXTPASS, O_DONE
    } state_t;
    state_t st;

    logic  [7:0] ent;                   // sprite entry, walked 255 -> 0
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] w0, w6;    // only the active flag, z code, priority
                            // and shadow field are used here
    /* verilator lint_on UNUSEDSIGNAL */
    logic  [9:0] nobj;
    logic        pass;                  // 0: sort by zcode, 1: sort by priority
    logic  [9:0] scan;
    logic  [1:0] emit_step;

    // ---- object formation for the current entry --------------------------
    wire        active   = w0[15];
    wire  [7:0] zcode_raw = w0[7:0];
    wire  [7:0] zcode    = opset[4] ? (8'hff - zcode_raw) : zcode_raw;
    wire  [7:0] pri      = {w6[7:5], 5'd0};
    wire  [1:0] shadow_r = w6[11:10];

    // konamigx_mixer's shadow decision
    wire        shadow_demote = (shadow_r != 2'd1) || objset1[5];
    wire  [1:0] shadow_idx    = shadow_demote ? (shadow_r - 2'd1) : 2'd0;
    wire        has_shadow    = |shadow_r;
    wire        add_solid     = !has_shadow || shadow_demote;
    wire  [3:0] solid_mode    = has_shadow ? 4'd1 : 4'd0;
    wire        shadowon_sel  = shadowon[shadow_idx];
    wire        add_shadow    = has_shadow &&
                                (shadow_demote ? shadowon_sel : shadowon[0]);
    wire  [3:0] shadow_mode   = shadow_demote ? 4'd4 : 4'd5;
    wire  [7:0] spri          = opset[5] ? pri : shdpri[shadow_idx];
    // a sprite whose shadow code is 1 with SD0EN off is dropped entirely
    wire        drop_entry    = has_shadow && !shadow_demote && !shadowon[0];

    wire [31:0] solid_order  = {pri,  zcode, ent, solid_mode, 4'd0};
    wire [31:0] shadow_order = {spri, zcode, ent, shadow_mode, 2'd0, shadow_idx};

    // ---- counting sort ---------------------------------------------------
    wire [31:0] src_q   = pass ? lb_q : la_q;
    wire  [7:0] sort_key = pass ? src_q[31:24] : src_q[23:16];

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= O_IDLE; busy <= 1'b0; done <= 1'b0;
            nobj <= '0; which <= 1'b0; overflow <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                O_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1; nobj <= '0; ent <= 8'd255;
                        which <= 1'b0; overflow <= 1'b0;
                        st <= O_B0;
                    end
                end

                // read word 0 (active + zcode) and word 6 (colour/attributes)
                O_B0: begin ram_addr <= {ent, 3'd0};       st <= O_B1; end
                O_B1: begin ram_addr <= {ent, 3'd6};       st <= O_B2; end
                O_B2: begin w0 <= ram_q; emit_step <= 2'd0; st <= O_EMIT; end

                O_EMIT: begin
                    if (emit_step == 2'd0) begin
                        w6 <= ram_q;
                        emit_step <= 2'd1;
                    end else if (!active || drop_entry) begin
                        st <= O_NEXTENT;
                    end else if (emit_step == 2'd1) begin
                        // shadow object first: for equal (pri, zcode) the key
                        // puts the higher drawmode ahead, and the sort is stable
                        if (add_shadow) begin
                            if (nobj == MAXOBJ[9:0]) overflow <= 1'b1;
                            else begin la[nobj[AW-1:0]] <= shadow_order; nobj <= nobj + 1'd1; end
                        end
                        emit_step <= 2'd2;
                    end else begin
                        if (add_solid) begin
                            if (nobj == MAXOBJ[9:0]) overflow <= 1'b1;
                            else begin la[nobj[AW-1:0]] <= solid_order; nobj <= nobj + 1'd1; end
                        end
                        st <= O_NEXTENT;
                    end
                end

                O_NEXTENT: begin
                    if (ent == 8'd0) begin
                        pass <= 1'b0; cnt_idx <= 8'd0; st <= O_CLR;
                    end else begin
                        ent <= ent - 1'd1; st <= O_B0;
                    end
                end

                // ---- counting sort pass ----
                O_CLR: begin
                    cnt[cnt_idx] <= '0;
                    if (cnt_idx == 8'd255) begin scan <= '0; st <= O_CNT; end
                    else cnt_idx <= cnt_idx + 1'd1;
                end
                // list_rd is registered and the RAM read is registered too, so
                // src_q only settles two cycles after the address is issued
                O_CNT: begin list_rd <= scan[AW-1:0]; st <= O_CNTW; end
                O_CNTW: st <= O_CNT2;
                O_CNT2: begin
                    cnt[sort_key] <= cnt[sort_key] + 1'd1;
                    if (scan + 1'd1 == nobj) begin
                        cnt_idx <= 8'd255; acc <= '0; st <= O_PRE;
                    end else begin scan <= scan + 1'd1; st <= O_CNT; end
                end
                // descending: the first slot for key k is the total of all
                // keys above it, so accumulate from 255 down
                O_PRE: begin
                    cnt[cnt_idx] <= acc;
                    acc <= acc + cnt[cnt_idx];
                    if (cnt_idx == 8'd0) begin scan <= '0; st <= O_SCAT; end
                    else cnt_idx <= cnt_idx - 1'd1;
                end
                O_SCAT:  begin list_rd <= scan[AW-1:0]; st <= O_SCATW; end
                O_SCATW: st <= O_SCAT2;
                O_SCAT2: begin
                    if (pass) la[cnt[sort_key][AW-1:0]] <= src_q;
                    else      lb[cnt[sort_key][AW-1:0]] <= src_q;
                    cnt[sort_key] <= cnt[sort_key] + 1'd1;
                    if (scan + 1'd1 == nobj) st <= O_NEXTPASS;
                    else begin scan <= scan + 1'd1; st <= O_SCAT; end
                end
                O_NEXTPASS: begin
                    which <= ~pass;      // pass 0 leaves the result in lb
                    if (pass) st <= O_DONE;
                    else begin pass <= 1'b1; cnt_idx <= 8'd0; st <= O_CLR; end
                end

                O_DONE: begin done <= 1'b1; busy <= 1'b0; st <= O_IDLE; end
                default: st <= O_IDLE;
            endcase
        end
    end

    assign count = nobj;
endmodule

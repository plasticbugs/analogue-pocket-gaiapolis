//------------------------------------------------------------------------------
// K053936-class PSAC2 rotate/zoom plane for Gaiapolis.
//
// A 512x512 grid of 16x16 4bpp tiles -- an 8192x8192 virtual plane -- sampled
// through an affine transform. The tile map lives in ROM (gfx4) rather than
// RAM, three bytes per tile; the characters are in gfx3. See docs/hardware.md
// section 5, and tools/render_model.py for the reference semantics.
//
// Only "simple" mode is implemented (ctrl[7] bit 6 clear), which is all the
// frozen-state corpus uses; "super" (per-line) mode raises `unsupported`.
//
// Locality note: at the transforms this game uses, consecutive pixels along a
// raster line step one source pixel in Y (x step 0, y step 1.0, or 2.7 on
// the busiest screen), so a tile-map cache pays for itself (376 pixels need
// only 25-65 map fetches) while every pixel lands on a different row of the
// tile. The characters therefore come in as 16-word blocks: a tile's
// 4-pixel word column, one word per row, one burst from the platform's
// memory (stored column-major within the tile at load time), into a
// 32-block direct-mapped cache by tile row that also serves the next three
// raster lines, which step one source pixel across. On the Pocket's memories
// the one-word-per-pixel reads cost 7,900-9,600 clocks a line against the
// 6,144 available (tools/roz_fetches.py sizes the blocks: 25-65 a line).
//
// Deliberate divergence from MAME: K053936GP_copyroz32clip advances its
// destination row before the loop body, so MAME paints raster row N with the
// transform for row N-1 and never writes the first visible row. That reads as
// a porting artefact rather than silicon behaviour, so this module does not
// copy it; sim/run_roz.sh compares against the model with the resulting
// one-line offset applied. docs/hardware.md section 10.
//------------------------------------------------------------------------------
`default_nettype none

module k053936_roz #(
    parameter int VIS_W  = 376,
    parameter int VIS_X0 = 40,
    parameter int VIS_Y0 = 16,
    parameter int LB_AW  = 9,
    // K053936GP_set_offset(0, -10, 0) for gaiapolis
    parameter int OFFS_X = -10,
    parameter int OFFS_Y = 0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        line_start,
    input  logic  [8:0] line,
    output logic        busy,

    input  logic [15:0] ctrl [8],       // 0x460000 control block
    input  logic [15:0] clip [2],       // 0x484000 clip window
    input  logic        roz_enable,     // 0x6c0000 bit 8
    // K055555 SUB1 palette base. Only the low nibble reaches the colour --
    // the model shifts the register left 4 into an 8-bit field.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] palbase,
    /* verilator lint_on UNUSEDSIGNAL */

    // tile map ROM (gfx4). Byte address; map_q is the containing 16-bit word.
    output logic        map_req,
    output logic [19:0] map_addr,
    input  logic        map_ack,
    input  logic [15:0] map_q,

    // character ROM (gfx3), same convention
    // the character blocks: a level request for block blk_addr (tile*4 + word
    // column), its 16 words streamed back with blk_wr/blk_idx/blk_data, then
    // blk_ack for a request still standing with the same address
    output logic        blk_req,
    output logic [15:0] blk_addr,
    input  logic        blk_wr,
    input  logic  [3:0] blk_idx,
    input  logic [15:0] blk_data,
    input  logic        blk_ack,

    input  logic [LB_AW-1:0] px,
    output logic [11:0] pix,
    output logic        opaque,

    output logic        unsupported
);
    // ------------------------------------------------------------- transform
    function automatic logic signed [31:0] sx16(input logic [15:0] v);
        return {{16{v[15]}}, v};
    endfunction

    logic signed [31:0] incxx, incxy, incyx, incyy;
    logic        [31:0] startx, starty;      // 16.16, wraps as uint32 like MAME

    // ---------------------------------------------------------- line buffer
    logic bank;
    logic [12:0] lbuf [2][VIS_W];
    logic [12:0] rd;
    always_ff @(posedge clk) rd <= lbuf[~bank][px];
    assign pix    = rd[11:0];
    assign opaque = rd[12];

    // ------------------------------------------------------------- clipping
    wire        clip_en = clip[1][8];
    wire [ 5:0] clip_x  = clip[0][5:0];
    wire [ 5:0] clip_y  = clip[0][11:6];
    wire [ 1:0] csx     = clip[0][13:12];
    wire [ 1:0] csy     = clip[0][15:14];
    function automatic logic [2:0] clipsize(input logic [1:0] v);
        case (v) 2'd3: return 3'd1; 2'd2: return 3'd2; default: return 3'd4; endcase
    endfunction
    wire [12:0] minx = {clip_x, 7'd0};
    wire  [5:0] clip_ex = clip_x + {3'd0, clipsize(csx)};
    wire [12:0] maxx = {clip_ex, 7'd0} - 13'd1;
    wire [12:0] miny = {clip_y, 7'd0};
    wire  [5:0] clip_ey = clip_y + {3'd0, clipsize(csy)};
    wire [12:0] maxy = {clip_ey, 7'd0} - 13'd1;

    // ------------------------------------------------------------------ FSM
    typedef enum logic [3:0] {
        R_IDLE, R_SETUP, R_SETUP2, R_PIX, R_M1, R_M1W, R_M2, R_M2W, R_M3, R_M3W,
        R_CHR, R_CHRW, R_CHRP, R_EMIT
    } state_t;
    state_t st;

    logic [31:0] cx, cy;
    logic [LB_AW-1:0] cur_x;
    logic [12:0] srcx, srcy;
    logic [17:0] ti, cache_ti;
    logic        cache_valid, cache_miss;
    logic [13:0] tileno;
    logic  [7:0] colour;
    /* verilator lint_off UNUSEDSIGNAL */
    logic  [7:0] d1, d2, d3;   // d2[6] is not part of the tile number
    /* verilator lint_on UNUSEDSIGNAL */
    logic  [3:0] pen;
    logic        clipped;

    wire [17:0] ti_now = {srcy[12:4], srcx[12:4]};
    // On a cache miss the tile number is only latched at the end of this
    // cycle, so the character address has to use the value being decoded,
    // not the register. Using `tileno` here mis-fetches exactly one pixel
    // at every tile boundary.
    wire [13:0] tileno_next = cache_miss ? {d2[5:0], d3} : tileno;
    // the block cache: 32 entries by the tile's row on the plane, each a
    // tile's word column (16 words); tags hold the block id
    wire [15:0] blk_now = {tileno_next, srcx[3:2]};
    wire  [4:0] blk_set = srcy[8:4];
    logic [15:0] blk_tag [32];
    logic [31:0] blk_valid;
    logic [15:0] blk_mem [512];         // {set, row}
    logic [15:0] blk_word;
    logic  [8:0] blk_raddr;
    logic  [4:0] fill_set;
    logic  [1:0] pix_sel;               // srcx[1:0] of the pixel being read
    always_ff @(posedge clk) begin
        if (blk_wr) blk_mem[{fill_set, blk_idx}] <= blk_data;
        blk_word <= blk_mem[blk_raddr];
    end
    // the line's offset into the visible area, registered every clock so the
    // subtract does not sit in front of the line-start multiply (that path
    // missed by 0.08 ns on the Pocket)
    logic [8:0] vline;
    always_ff @(posedge clk) vline <= line - 9'(VIS_Y0);

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= R_IDLE; busy <= 1'b0; bank <= 1'b0;
            map_req <= 1'b0; blk_req <= 1'b0; unsupported <= 1'b0;
            cache_valid <= 1'b0; cache_miss <= 1'b0; blk_valid <= '0;
        end else if (line_start && st != R_IDLE) begin
            // the previous line overran its budget: abandon it and start this
            // one, as the hardware would -- whatever was drawn is what shows
            bank <= ~bank; busy <= 1'b1;
            map_req <= 1'b0; blk_req <= 1'b0; st <= R_SETUP;
        end else begin
            case (st)
                R_IDLE: begin
                    busy <= 1'b0;
                    if (line_start) begin
                        bank <= ~bank;
                        busy <= 1'b1;
                        st   <= R_SETUP;
                        if (ctrl[7][6]) unsupported <= 1'b1;    // "super" mode
                    end
                end

                R_SETUP: begin
                    cur_x <= '0;
                    cache_valid <= 1'b0;
                    // startx/starty already fold in the visible-area origin, so
                    // the per-line advance counts visible lines, not raster ones;
                    // the multiply and the add are two cycles (one path was -6.6 ns)
                    pyx <= $unsigned(incyx) * {23'd0, vline};
                    pyy <= $unsigned(incyy) * {23'd0, vline};
                    st <= R_SETUP2;
                end
                R_SETUP2: begin
                    cx <= startx + pyx;
                    cy <= starty + pyy;
                    st <= R_PIX;
                end

                R_PIX: begin
                    srcx <= cx[28:16];
                    srcy <= cy[28:16];
                    st   <= R_M1;
                end

                R_M1: begin
                    clipped <= clip_en & ((srcx < minx) | (srcx > maxx)
                                        | (srcy < miny) | (srcy > maxy));
                    ti <= ti_now;
                    blk_raddr <= {blk_set, srcy[3:0]};     // the row's word is read from here on
                    if (!roz_enable) begin
                        pen <= 4'd0; st <= R_EMIT;
                    end else if (cache_valid && ti_now == cache_ti) begin
                        cache_miss <= 1'b0;
                        st <= R_CHR;                       // tile attributes still valid
                    end else begin
                        cache_miss <= 1'b1;
                        // colour nibbles are packed two tiles per byte
                        map_addr <= {3'd0, ti_now[17:1]};
                        map_req  <= 1'b1;
                        st <= R_M1W;
                    end
                end
                R_M1W: if (map_ack) begin
                    d1 <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_req <= 1'b0;
                    st <= R_M2;
                end
                R_M2: begin
                    map_addr <= 20'h20000 + {2'd0, ti};
                    map_req  <= 1'b1;
                    st <= R_M2W;
                end
                R_M2W: if (map_ack) begin
                    d2 <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_req <= 1'b0;
                    st <= R_M3;
                end
                R_M3: begin
                    map_addr <= 20'h60000 + {2'd0, ti};
                    map_req  <= 1'b1;
                    st <= R_M3W;
                end
                R_M3W: if (map_ack) begin
                    d3 <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_req <= 1'b0;
                    st <= R_CHR;
                end

                R_CHR: begin
                    if (cache_miss) begin
                        tileno   <= {d2[5:0], d3};
                        // palbase occupies bits 7:4 and the attribute's bit 7
                        // adds bit 4; they never collide for this game's base
                        colour   <= {palbase[3:0], 4'd0} | {3'd0, d2[7], 4'd0}
                                  | {4'd0, (ti[0] ? d1[3:0] : d1[7:4])};
                        cache_ti <= ti;
                        cache_valid <= 1'b1;
                    end
                    pix_sel   <= srcx[1:0];
                    if (blk_valid[blk_set] && blk_tag[blk_set] == blk_now) begin
                        st <= R_CHRP;                      // the block is cached
                    end else begin
                        blk_addr <= blk_now; blk_req <= 1'b1; fill_set <= blk_set;
                        blk_valid[blk_set] <= 1'b0;
                        st <= R_CHRW;
                    end
                end
                R_CHRW: if (blk_ack) begin
                    blk_req <= 1'b0;
                    blk_tag[fill_set] <= blk_addr; blk_valid[fill_set] <= 1'b1;
                    st <= R_CHRP;
                end
                R_CHRP: begin
                    // the word for this row is in blk_word; x's low bits pick the nibble
                    pen <= (pix_sel == 2'd0) ? blk_word[15:12] : (pix_sel == 2'd1) ? blk_word[11:8]
                         : (pix_sel == 2'd2) ? blk_word[7:4] : blk_word[3:0];
                    st <= R_EMIT;
                end

                R_EMIT: begin
                    lbuf[bank][cur_x] <= (|pen && !clipped) ? {1'b1, colour, pen}
                                                            : 13'd0;
                    cx <= cx + $unsigned(incxx);
                    cy <= cy + $unsigned(incxy);
                    if (cur_x == VIS_W[LB_AW-1:0] - 1) begin
                        st <= R_IDLE; busy <= 1'b0;
                    end else begin
                        cur_x <= cur_x + 1'd1;
                        st <= R_PIX;
                    end
                end
                default: st <= R_IDLE;
            endcase
        end
    end

    // control-register decode, registered in three short stages every cycle
    // so a mid-frame write still takes effect on the next line as it does on
    // the chip (a few clocks after the write, well inside a line), without
    // the shifts, constant multiplies and adds forming one long path
    logic signed [31:0] ixx, ixy, iyx, iyy, sx0, sy0, sx, sy;
    logic        [31:0] pxx, pxy, pyx, pyy;
    always_ff @(posedge clk) begin
        // stage 1: sign extension and the x256 modes
        ixx <= ctrl[6][6]  ? (sx16(ctrl[4]) <<< 8) : sx16(ctrl[4]);
        ixy <= ctrl[6][6]  ? (sx16(ctrl[5]) <<< 8) : sx16(ctrl[5]);
        iyx <= ctrl[6][14] ? (sx16(ctrl[2]) <<< 8) : sx16(ctrl[2]);
        iyy <= ctrl[6][14] ? (sx16(ctrl[3]) <<< 8) : sx16(ctrl[3]);
        sx0 <= sx16(ctrl[0]) <<< 8;
        sy0 <= sx16(ctrl[1]) <<< 8;
        // stage 2: the layer offsets and the 16.16 increments
        sx <= sx0 - OFFS_Y * iyx - OFFS_X * ixx;
        sy <= sy0 - OFFS_Y * iyy - OFFS_X * ixy;
        incxx <= ixx <<< 5; incxy <= ixy <<< 5;
        incyx <= iyx <<< 5; incyy <= iyy <<< 5;
        pxx <= $unsigned(ixx <<< 5) * VIS_X0; pxy <= $unsigned(ixy <<< 5) * VIS_X0;
        // stage 3: the visible-area origin folded in
        startx <= $unsigned(sx <<< 5) + pxx + $unsigned(incyx) * VIS_Y0;
        starty <= $unsigned(sy <<< 5) + pxy + $unsigned(incyy) * VIS_Y0;
    end
endmodule

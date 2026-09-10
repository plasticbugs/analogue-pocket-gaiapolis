//------------------------------------------------------------------------------
// Gaiapolis: the platform-agnostic machine.
//
// Everything the board does, with the ROMs behind request/ack ports so the
// same module runs under Verilator with ideal memories and on the Pocket
// behind the SDRAM/PSRAM controllers. docs/hardware.md is the map.
//
// Sound is not fitted yet: the K054321 latch is here so the 68000's traffic
// to it is real, but nothing answers on the Z80 side and the audio outputs
// are silent.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_core #(
    parameter string HEXDIR = "rtl/data",
    parameter int    OBJ_BUILD_LINE = 12   // raster line at which the sprite list is built
) (
    input  logic        clk,                // 96 MHz
    input  logic        reset,

    // program ROM, 3 MB as 1.5M x 16
    output logic        prog_req,
    output logic [22:1] prog_addr,
    input  logic        prog_ack,
    input  logic [15:0] prog_q,
    // tile ROM, 2 MB as 512K x 32
    output logic        tile_req,
    output logic [18:0] tile_addr,
    input  logic        tile_ack,
    input  logic [31:0] tile_q,
    // ROZ map ROM (gfx4, 640 KB) and character ROM (gfx3, 1.5 MB): byte address, 16-bit word back
    output logic        map_req,
    output logic [19:0] map_addr,
    input  logic        map_ack,
    input  logic [15:0] map_q,
    output logic        chr_req,
    output logic [20:0] chr_addr,
    input  logic        chr_ack,
    input  logic [15:0] chr_q,
    // sprite ROM, 8 MB as 1M x 64
    output logic        spr_req,
    output logic [19:0] spr_addr,
    input  logic        spr_ack,
    input  logic [63:0] spr_q,

    // EEPROM array: load at start, read back to save
    input  logic        eep_ld_we,
    input  logic  [6:0] eep_ld_addr,
    input  logic  [7:0] eep_ld_wdata,
    output logic  [7:0] eep_ld_q,
    output logic        eep_dirty,

    // controls, active low as the board sees them (docs/hardware.md section 8)
    input  logic [15:0] in0_p1,
    input  logic  [7:0] in1,
    input  logic  [7:0] p2,

    // video, 8 MHz pixel rate on cen_pix
    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        vblank,

    // audio (silent until the sound board exists)
    output logic [15:0] snd_l,
    output logic [15:0] snd_r,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic        dbg_overrun,
    output logic        dbg_unsupported,
    output logic        dbg_shadow_overlap,
    output logic  [9:0] dbg_objcount,
    output logic  [8:0] dbg_vcount
);
    // ------------------------------------------------------------ clocks
    logic cen_16m, cen_8m;
    clk_enables u_cen (.clk(clk), .reset(reset), .cen_16m(cen_16m), .cen_8m(cen_8m));
    assign cen_pix = cen_8m;

    // ------------------------------------------------------------ timing
    logic        line_start, px_valid, vblank_rise, renderers_busy;
    logic  [8:0] render_line, px, hcount, vcount;
    gaia_video u_vid (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .line_start(line_start), .render_line(render_line),
        .renderers_busy(renderers_busy), .overrun(dbg_overrun),
        .px(px), .px_valid(px_valid), .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de), .vblank(vblank), .vblank_rise(vblank_rise)
    );
    assign dbg_vcount = vcount;

    // ------------------------------------------------------- main board
    logic [15:0] k56regs [32], k56regsb [4], k38regs [16], rozctrl [8], rozclip [2], k47regs [8];
    logic  [7:0] k55regs [48], k46regs [8];
    logic        roz_enable;
    logic  [1:0] roz_rombank;
    logic [15:0] vram_raddr, vram_q, sram_q;
    logic [10:0] sram_raddr, pal_raddr;
    logic [23:0] pal_q;
    logic        eep_di, eep_cs, eep_clk, eep_do, eep_ready;
    logic        snd_wr, snd_rd, snd_irq, col_wr, col_rd;
    logic  [3:0] snd_off;
    logic  [7:0] snd_wdata, snd_rdata, col_wdata, col_rdata;
    logic  [4:0] col_off;
    logic        cmap_req, cmap_ack, cchr_req, cchr_ack, ctrom_req, ctrom_ack, csrom_req, csrom_ack;
    logic [19:0] cmap_addr;
    logic [20:0] cchr_addr;
    logic [18:0] ctrom_addr;
    logic [19:0] csrom_addr;

    gaia_main u_main (
        .clk(clk), .reset(reset), .cen_16m(cen_16m),
        .rom_req(prog_req), .rom_addr(prog_addr), .rom_ack(prog_ack), .rom_q(prog_q),
        .map_req(cmap_req), .map_addr(cmap_addr), .map_ack(cmap_ack), .map_q(map_q),
        .chr_req(cchr_req), .chr_addr(cchr_addr), .chr_ack(cchr_ack), .chr_q(chr_q),
        .trom_req(ctrom_req), .trom_addr(ctrom_addr), .trom_ack(ctrom_ack), .trom_q(tile_q),
        .srom_req(csrom_req), .srom_addr(csrom_addr), .srom_ack(csrom_ack), .srom_q(spr_q),
        .vblank_rise(vblank_rise),
        .in0_p1(in0_p1), .in1(in1), .p2(p2),
        .eep_di(eep_di), .eep_cs(eep_cs), .eep_clk(eep_clk), .eep_do(eep_do), .eep_ready(eep_ready),
        .snd_wr(snd_wr), .snd_rd(snd_rd), .snd_off(snd_off), .snd_wdata(snd_wdata), .snd_rdata(snd_rdata),
        .snd_irq(snd_irq),
        .col_wr(col_wr), .col_rd(col_rd), .col_off(col_off), .col_wdata(col_wdata), .col_rdata(col_rdata),
        .k56regs(k56regs), .k56regsb(k56regsb), .k55regs(k55regs), .k38regs(k38regs),
        .rozctrl(rozctrl), .rozclip(rozclip), .roz_enable(roz_enable), .roz_rombank(roz_rombank),
        .k46regs(k46regs), .k47regs(k47regs),
        .vram_raddr(vram_raddr), .vram_q(vram_q),
        .sram_raddr(sram_raddr), .sram_q(sram_q),
        .pal_raddr(pal_raddr), .pal_q(pal_q),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5)
    );

    er5911 u_eep (
        .clk(clk), .reset(reset),
        .cs(eep_cs), .sclk(eep_clk), .di(eep_di), .dout(eep_do), .ready(eep_ready),
        .ld_we(eep_ld_we), .ld_addr(eep_ld_addr), .ld_wdata(eep_ld_wdata), .ld_q(eep_ld_q),
        .dirty(eep_dirty)
    );

    logic [6:0] snd_volume;
    logic [1:0] snd_active;
    k054321 u_latch (
        .clk(clk), .reset(reset),
        .m_wr(snd_wr), .m_rd(snd_rd), .m_off(snd_off), .m_wdata(snd_wdata), .m_rdata(snd_rdata),
        .s_wr(1'b0), .s_off(2'd0), .s_wdata(8'd0), .s_rdata(),
        .volume(snd_volume), .active(snd_active)
    );

    k054000 u_col (
        .clk(clk), .reset(reset), .wr(col_wr), .off(col_off), .wdata(col_wdata), .rdata(col_rdata)
    );

    // ------------------------------------------------- derived config
    logic [7:0] tm_colorbase [4];
    always_comb for (int l = 0; l < 4; l++) tm_colorbase[l] = {k55regs[23 + l][3:0], 4'd0};
    wire [7:0] roz_palbase   = k55regs[28];
    wire [7:0] spr_colorbase = {1'b0, k55regs[27][2:0], 4'd0};
    wire [7:0] objset1       = k46regs[5];
    wire [15:0] opset        = k47regs[6];
    wire [15:0] k46offx      = {k46regs[0], k46regs[1]};
    wire [15:0] k46offy      = {k46regs[2], k46regs[3]};
    logic [2:0] shadowon;
    logic [7:0] shdpri [3];
    always_comb begin
        for (int t = 0; t < 3; t++) begin
            shadowon[t] = 1'b0;
            for (int c = 0; c < 3; c++) begin
                logic [8:0] d; d = k38regs[2 + t*3 + c][8:0];
                if (d[8] ? (d < 9'h1f9) : (d > 9'd7)) shadowon[t] = 1'b1;
            end
            shdpri[t] = k55regs[37 + t];
        end
    end

    // ------------------------------------------------------- renderers
    logic tm_busy, roz_busy, dr_busy, ol_busy, ol_done, tm_unsup, roz_unsup, ol_overflow;
    logic [11:0] tm_pen [4]; logic [3:0] tm_opq;
    logic [11:0] roz_pen;    logic roz_opq;
    logic spr_opq, spr_shadow; logic [11:0] spr_pen; logic [7:0] spr_pri, spr_shpri; logic [1:0] spr_shtab;
    logic  [9:0] list_idx, list_count; logic [31:0] list_q;
    logic [10:0] ol_sram_addr, dr_sram_addr;
    logic  [9:0] zoom_addr; logic [10:0] recip_addr; logic [23:0] zoom_q, recip_q;
    logic        rmap_req, rmap_ack, rchr_req, rchr_ack, rtile_req, rtile_ack, rspr_req, rspr_ack;
    logic [19:0] rmap_addr;
    logic [20:0] rchr_addr;
    logic [18:0] rtile_addr;
    logic [19:0] rspr_addr;
    logic [31:0] dbg0, dbg1, dbg2, dbg3;

    assign renderers_busy  = tm_busy | roz_busy | dr_busy;
    assign dbg_unsupported = tm_unsup | roz_unsup | ol_overflow;
    assign sram_raddr = ol_busy ? ol_sram_addr : dr_sram_addr;

    // build the sprite list late in vblank, after the game's IRQ handler has
    // had most of the blanking period to write the new table
    logic obj_build, build_armed;
    always_ff @(posedge clk) begin
        obj_build <= 1'b0;
        if (reset) build_armed <= 1'b1;
        else if (cen_pix) begin
            if (vcount == 9'(OBJ_BUILD_LINE) && hcount == 9'd0 && build_armed) begin
                obj_build <= 1'b1; build_armed <= 1'b0;
            end
            if (vcount != 9'(OBJ_BUILD_LINE)) build_armed <= 1'b1;
        end
    end

    k056832_tilemap u_tm (
        .clk(clk), .reset(reset), .line_start(line_start), .line(render_line), .busy(tm_busy),
        .regs(k56regs), .colorbase(tm_colorbase),
        .vram_addr(vram_raddr), .vram_q(vram_q),
        .rom_req(rtile_req), .rom_addr(rtile_addr), .rom_ack(rtile_ack), .rom_q(tile_q),
        .px(px), .pix(tm_pen), .opaque(tm_opq), .unsupported(tm_unsup)
    );
    rom_arb2 #(.AW(19), .DW(32)) u_tile_arb (
        .clk(clk), .reset(reset),
        .c0_req(rtile_req), .c0_addr(rtile_addr), .c0_ack(rtile_ack),
        .c1_req(ctrom_req), .c1_addr(ctrom_addr), .c1_ack(ctrom_ack),
        .m_req(tile_req), .m_addr(tile_addr), .m_ack(tile_ack), .m_q(tile_q), .q()
    );
    k053936_roz u_roz (
        .clk(clk), .reset(reset), .line_start(line_start), .line(render_line), .busy(roz_busy),
        .ctrl(rozctrl), .clip(rozclip), .roz_enable(roz_enable), .palbase(roz_palbase),
        .map_req(rmap_req), .map_addr(rmap_addr), .map_ack(rmap_ack), .map_q(map_q),
        .chr_req(rchr_req), .chr_addr(rchr_addr), .chr_ack(rchr_ack), .chr_q(chr_q),
        .px(px), .pix(roz_pen), .opaque(roz_opq), .unsupported(roz_unsup)
    );
    rom_arb2 #(.AW(20), .DW(16)) u_map_arb (
        .clk(clk), .reset(reset),
        .c0_req(rmap_req), .c0_addr(rmap_addr), .c0_ack(rmap_ack),
        .c1_req(cmap_req), .c1_addr(cmap_addr), .c1_ack(cmap_ack),
        .m_req(map_req), .m_addr(map_addr), .m_ack(map_ack), .m_q(map_q), .q()
    );
    rom_arb2 #(.AW(21), .DW(16)) u_chr_arb (
        .clk(clk), .reset(reset),
        .c0_req(rchr_req), .c0_addr(rchr_addr), .c0_ack(rchr_ack),
        .c1_req(cchr_req), .c1_addr(cchr_addr), .c1_ack(cchr_ack),
        .m_req(chr_req), .m_addr(chr_addr), .m_ack(chr_ack), .m_q(chr_q), .q()
    );
    k053247_objlist u_ol (
        .clk(clk), .reset(reset), .start(obj_build), .done(ol_done), .busy(ol_busy),
        .opset(opset), .objset1(objset1), .shadowon(shadowon), .shdpri(shdpri),
        .ram_addr(ol_sram_addr), .ram_q(sram_q),
        .list_idx(list_idx), .list_q(list_q), .count(list_count), .overflow(ol_overflow)
    );
    assign dbg_objcount = list_count;
    sprite_tables #(.HEXDIR(HEXDIR)) u_tab (
        .clk(clk), .zoom_addr(zoom_addr), .zoom_q(zoom_q), .recip_addr(recip_addr), .recip_q(recip_q)
    );
    k053247_draw u_dr (
        .clk(clk), .reset(reset), .line_start(line_start), .line(render_line), .busy(dr_busy),
        .k46r5(objset1), .k46_offx(k46offx), .k46_offy(k46offy), .opset(opset), .colorbase(spr_colorbase),
        .list_idx(list_idx), .list_q(list_q), .list_count(list_count),
        .ram_addr(dr_sram_addr), .ram_q(sram_q),
        .rom_req(rspr_req), .rom_addr(rspr_addr), .rom_ack(rspr_ack), .rom_q(spr_q),
        .zoom_addr(zoom_addr), .zoom_q(zoom_q), .recip_addr(recip_addr), .recip_q(recip_q),
        .px(px), .out_opaque(spr_opq), .out_pen(spr_pen), .out_pri(spr_pri),
        .out_shadow(spr_shadow), .out_shtab(spr_shtab), .out_shpri(spr_shpri),
        .shadow_overlap(dbg_shadow_overlap),
        .dbg_objs(dbg0), .dbg_rows(dbg1), .dbg_cols(dbg2), .dbg_pxw(dbg3)
    );
    rom_arb2 #(.AW(20), .DW(64)) u_spr_arb (
        .clk(clk), .reset(reset),
        .c0_req(rspr_req), .c0_addr(rspr_addr), .c0_ack(rspr_ack),
        .c1_req(csrom_req), .c1_addr(csrom_addr), .c1_ack(csrom_ack),
        .m_req(spr_req), .m_addr(spr_addr), .m_ack(spr_ack), .m_q(spr_q), .q()
    );
    k055555_mixer u_mx (
        .clk(clk), .reset(reset),
        .tm_pen(tm_pen), .tm_opq(tm_opq & {4{px_valid}}), .roz_pen(roz_pen), .roz_opq(roz_opq & px_valid),
        .spr_opq(spr_opq & px_valid), .spr_pen(spr_pen), .spr_pri(spr_pri),
        .spr_shadow(spr_shadow & px_valid), .spr_shtab(spr_shtab), .spr_shpri(spr_shpri),
        .k55regs(k55regs), .k38regs(k38regs), .roz_enable(roz_enable),
        .pal_addr(pal_raddr), .pal_q(pal_q), .rgb(rgb)
    );

    assign snd_l = '0;
    assign snd_r = '0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{k56regsb[0], k56regsb[1], k56regsb[2], k56regsb[3], roz_rombank, snd_irq, col_rd,
                    snd_volume, snd_active, ol_done, dbg0, dbg1, dbg2, dbg3, px_valid};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

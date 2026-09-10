// Full-system bench wrapper: gaia_core with ideal memories behind every ROM
// port, loadable from the C++ driver. The ROM models answer in one cycle.
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        reset,

    // loads
    input  logic        prog_we, input logic [21:0] prog_waddr, input logic [15:0] prog_wdata,
    input  logic        tile_we, input logic [18:0] tile_waddr, input logic [31:0] tile_wdata,
    input  logic        map_we,  input logic [18:0] map_waddr,  input logic [15:0] map_wdata,
    input  logic        chr_we,  input logic [19:0] chr_waddr,  input logic [15:0] chr_wdata,
    input  logic        spr_we,  input logic [19:0] spr_waddr,  input logic [63:0] spr_wdata,
    input  logic        eep_we,  input logic  [6:0] eep_waddr,  input logic  [7:0] eep_wdata,

    input  logic [15:0] in0_p1,
    input  logic  [7:0] in1,
    input  logic  [7:0] p2,

    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync, vsync, de, vblank,
    output logic [23:0] dbg_addr,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step, dbg_irq5, dbg_overrun, dbg_unsupported, dbg_shadow_overlap,
    output logic  [9:0] dbg_objcount,
    output logic  [8:0] dbg_vcount
);
    logic [15:0] prog [4194304];      // 22-bit word address; 3 MB used
    logic [31:0] tile [524288];
    logic [15:0] mapr [327680];
    logic [15:0] chr  [786432];
    logic [63:0] spr  [1048576];

    logic        prog_req, prog_ack, tile_req, tile_ack, map_req, map_ack, chr_req, chr_ack, spr_req, spr_ack;
    logic [22:1] prog_addr; logic [18:0] tile_addr; logic [19:0] map_addr; logic [20:0] chr_addr; logic [19:0] spr_addr;
    logic [15:0] prog_q, map_q, chr_q; logic [31:0] tile_q; logic [63:0] spr_q;

    always_ff @(posedge clk) begin
        if (prog_we) prog[prog_waddr] <= prog_wdata;
        if (tile_we) tile[tile_waddr] <= tile_wdata;
        if (map_we)  mapr[map_waddr]  <= map_wdata;
        if (chr_we)  chr[chr_waddr]   <= chr_wdata;
        if (spr_we)  spr[spr_waddr]   <= spr_wdata;
        prog_q <= prog[prog_addr];       prog_ack <= prog_req & ~prog_ack;
        tile_q <= tile[tile_addr];       tile_ack <= tile_req & ~tile_ack;
        map_q  <= mapr[map_addr[19:1]];  map_ack  <= map_req  & ~map_ack;
        chr_q  <= chr[chr_addr[20:1]];   chr_ack  <= chr_req  & ~chr_ack;
        spr_q  <= spr[spr_addr];         spr_ack  <= spr_req  & ~spr_ack;
    end

    logic [7:0] eep_q; logic eep_dirty; logic [15:0] snd_l, snd_r;

    gaia_core #(.HEXDIR("../rtl/data")) u_core (
        .clk(clk), .reset(reset),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .chr_req(chr_req), .chr_addr(chr_addr), .chr_ack(chr_ack), .chr_q(chr_q),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .eep_ld_we(eep_we), .eep_ld_addr(eep_waddr), .eep_ld_wdata(eep_wdata), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
        .in0_p1(in0_p1), .in1(in1), .p2(p2),
        .cen_pix(cen_pix), .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de), .vblank(vblank),
        .snd_l(snd_l), .snd_r(snd_r),
        .dbg_addr(dbg_addr), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_overrun(dbg_overrun), .dbg_unsupported(dbg_unsupported), .dbg_shadow_overlap(dbg_shadow_overlap),
        .dbg_objcount(dbg_objcount), .dbg_vcount(dbg_vcount)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{eep_q, eep_dirty, snd_l, snd_r};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

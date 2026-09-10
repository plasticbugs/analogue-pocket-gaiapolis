// Frozen-state bench wrapper for k053936_roz.
`default_nettype none

module tb_roz_top (
    input  logic        clk,
    input  logic        reset,

    input  logic        ctrl_we,
    input  logic  [2:0] ctrl_addr,
    input  logic [15:0] ctrl_data,
    input  logic        clip_we,
    input  logic        clip_addr,
    input  logic [15:0] clip_data,
    input  logic        cfg_we,
    input  logic        roz_enable_i,
    input  logic  [7:0] palbase_i,

    input  logic        map_we,
    input  logic [18:0] map_waddr,      // word address into gfx4
    input  logic [15:0] map_wdata,
    input  logic        chr_we,
    input  logic [19:0] chr_waddr,      // word address into gfx3
    input  logic [15:0] chr_wdata,

    input  logic        line_start,
    input  logic  [8:0] line,
    output logic        busy,
    input  logic  [8:0] px,
    output logic [11:0] pix,
    output logic        opaque,
    output logic        unsupported
);
    logic [15:0] ctrl [8];
    logic [15:0] clip [2];
    logic        roz_enable;
    logic  [7:0] palbase;
    always_ff @(posedge clk) begin
        if (ctrl_we) ctrl[ctrl_addr] <= ctrl_data;
        if (clip_we) clip[clip_addr] <= clip_data;
        if (cfg_we)  begin roz_enable <= roz_enable_i; palbase <= palbase_i; end
    end

    logic [15:0] maprom [327680];       // gfx4, 640 KB
    logic [15:0] chrrom [786432];       // gfx3, 1.5 MB
    logic        map_req, map_ack, chr_req, chr_ack;
    logic [19:0] map_addr;
    logic [20:0] chr_addr;
    logic [15:0] map_q, chr_q;
    always_ff @(posedge clk) begin
        if (map_we) maprom[map_waddr] <= map_wdata;
        if (chr_we) chrrom[chr_waddr] <= chr_wdata;
        map_q   <= maprom[map_addr[19:1]];
        chr_q   <= chrrom[chr_addr[20:1]];
        map_ack <= map_req & ~map_ack;
        chr_ack <= chr_req & ~chr_ack;
    end

    k053936_roz u_roz (
        .clk(clk), .reset(reset),
        .line_start(line_start), .line(line), .busy(busy),
        .ctrl(ctrl), .clip(clip), .roz_enable(roz_enable), .palbase(palbase),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .chr_req(chr_req), .chr_addr(chr_addr), .chr_ack(chr_ack), .chr_q(chr_q),
        .px(px), .pix(pix), .opaque(opaque), .unsupported(unsupported)
    );
endmodule

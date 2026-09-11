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
    logic        map_req, map_ack;
    logic [19:0] map_addr;
    logic [15:0] map_q;
    always_ff @(posedge clk) begin
        if (map_we) maprom[map_waddr] <= map_wdata;
        if (chr_we) chrrom[chr_waddr] <= chr_wdata;
        map_q   <= maprom[map_addr[19:1]];
        map_ack <= map_req & ~map_ack;
    end

    // the character blocks, as the platform streams them: LAT_BLK clocks after
    // the request the 16 words of the tile's word column follow, one a clock,
    // out of the image-layout ROM (word tile*64 + row*4 + column)
    logic        blk_req, blk_wr, blk_ack;
    logic [15:0] blk_addr, blk_data;
    logic  [3:0] blk_idx;
    int lat_blk, cnt_blk;
    logic  [4:0] blk_n;                 // 0..15 streaming, 16 done
    logic        blk_run;
    logic [15:0] blk_addr_l;
    initial if (!$value$plusargs("LAT_BLK=%d", lat_blk)) lat_blk = 0;
    always_ff @(posedge clk) begin
        blk_wr <= 1'b0; blk_ack <= 1'b0;
        if (!blk_run) begin
            cnt_blk <= 0; blk_n <= 5'd0;
            if (blk_req && !blk_ack) begin blk_run <= 1'b1; blk_addr_l <= blk_addr; end
        end else if (cnt_blk < lat_blk) cnt_blk <= cnt_blk + 1;
        else if (blk_n != 5'd16) begin
            blk_wr <= 1'b1; blk_idx <= blk_n[3:0];
            blk_data <= chrrom[{blk_addr_l[15:2], blk_n[3:0], blk_addr_l[1:0]}];
            blk_n <= blk_n + 5'd1;
        end else begin
            blk_run <= 1'b0;
            if (blk_req && blk_addr == blk_addr_l) blk_ack <= 1'b1;
        end
    end

    k053936_roz u_roz (
        .clk(clk), .reset(reset),
        .line_start(line_start), .line(line), .busy(busy),
        .ctrl(ctrl), .clip(clip), .roz_enable(roz_enable), .palbase(palbase),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack),
        .px(px), .pix(pix), .opaque(opaque), .unsupported(unsupported)
    );
endmodule

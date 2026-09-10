//------------------------------------------------------------------------------
// Pocket memory subsystem for the Gaiapolis core: the 20 MB ROM image behind
// the core's request/ack ports (docs/hardware.md section 11).
//
//   SDRAM        tiles     2 MB   byte 0x000000    2-word bursts
//                PCM       4 MB   byte 0x200000    single words, one byte used
//                sprites   8 MB   byte 0x600000    4-word bursts
//   CRAM0 (PSRAM) ROZ chars 1.5 MB word 0x000000   single words
//                ROZ map   640 KB word 0x0C0000    single words
//   CRAM1 (PSRAM) 68000 program 3 MB word 0x000000 single words
//                Z80 program 256 KB word 0x180000  single words, one byte used
//   SRAM         K056832 tile RAM, 64K x 16     single words, byte-enabled writes
//
// Every memory holds big-endian 16-bit words: image byte 2k is the high byte
// of word k, byte 2k+1 the low byte -- the packing sim/tb_system.cpp uses, so
// the core sees the same words either way.
//
// The core's ports are level requests with a one-cycle ack that carries the
// data; a client may withdraw a request before its ack (a renderer restarting
// on a new line does), so every port here finishes the access it started and
// acks only if the same request is still standing.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase-shifted, drives the SDRAM clock pin
    input  logic        init,           // hardware reset: re-initialise the SDRAM
    output logic        ready,
    input  logic        rd_late,        // SDRAM diagnostics (Pocket menu)
    input  logic        burst_slow,

    // the ROM image arriving from the Pocket, a byte at an image offset
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        eep_we,         // the 128-byte EEPROM default at the end of the image
    output logic  [6:0] eep_addr,
    output logic  [7:0] eep_data,

    // core ports
    input  logic        prog_req,  input  logic [22:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        tile_req,  input  logic [18:0] tile_addr, output logic tile_ack, output logic [31:0] tile_q,
    input  logic        map_req,   input  logic [19:0] map_addr,  output logic map_ack,  output logic [15:0] map_q,
    input  logic        chr_req,   input  logic [20:0] chr_addr,  output logic chr_ack,  output logic [15:0] chr_q,
    input  logic        spr_req,   input  logic [19:0] spr_addr,  output logic spr_ack,  output logic [63:0] spr_q,
    input  logic        snd_req,   input  logic [17:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,   input  logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    // the tile RAM: the core's request/ack port, byte-enabled writes
    input  logic        vram_req,  input  logic        vram_we,   input  logic [15:0] vram_addr,
    input  logic  [1:0] vram_be,   input  logic [15:0] vram_wdata, output logic vram_ack, output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n,
    // PSRAM pins
    output logic [21:16] cram0_a, inout wire [15:0] cram0_dq, input logic cram0_wait,
    output logic        cram0_clk, cram0_adv_n, cram0_cre, cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n,
    output logic [21:16] cram1_a, inout wire [15:0] cram1_dq, input logic cram1_wait,
    output logic        cram1_clk, cram1_adv_n, cram1_cre, cram1_ce0_n, cram1_ce1_n, cram1_oe_n, cram1_we_n, cram1_ub_n, cram1_lb_n,
    // SRAM pins
    output logic [16:0] sram_a, inout wire [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    // image layout (byte offsets), gaiapolis.mra
    localparam [24:0] IMG_PROG = 25'h0000000, IMG_SND  = 25'h0300000, IMG_TILE = 25'h0340000;
    localparam [24:0] IMG_CHR  = 25'h0540000, IMG_MAP  = 25'h06C0000, IMG_PCM  = 25'h0760000;
    localparam [24:0] IMG_SPR  = 25'h0B60000, IMG_EEP  = 25'h1360000, IMG_END  = 25'h1360080;
    // SDRAM word addresses
    localparam [24:1] SD_TILE = 24'h000000, SD_PCM = 24'h100000, SD_SPR = 24'h300000;
    // PSRAM word addresses
    localparam [22:0] PS_CHR = 23'h000000, PS_MAP = 23'h0C0000, PS_PROG = 23'h000000, PS_SND = 23'h180000;

    // ------------------------------------------------------------ download
    // A small FIFO absorbs the loader's bursts; the dispatcher behind it
    // routes each byte to its memory as a byte-enabled word write.
    logic [32:0] wfifo [64];
    logic  [6:0] wf_wp, wf_rp;
    logic        dl_we_d;
    wire         wf_empty = (wf_wp == wf_rp);
    wire         wf_full  = (wf_wp[5:0] == wf_rp[5:0]) && (wf_wp[6] != wf_rp[6]);
    wire [32:0]  wf_head  = wfifo[wf_rp[5:0]];
    wire [24:0]  wa       = wf_head[32:8];
    wire  [7:0]  wd       = wf_head[7:0];

    typedef enum logic [2:0] { W_IDLE, W_SDRAM, W_PS0, W_PS1, W_EEP, W_POP } wst_t;
    wst_t wst;

    // SDRAM write client (client 1) and PSRAM writer ports
    logic        sd_wr_req, sd_wr_ack;
    logic [24:1] sd_wr_addr;
    logic  [1:0] sd_wr_be;
    logic        ps0_wr_req, ps0_wr_ack, ps1_wr_req, ps1_wr_ack;
    logic [22:0] ps_wr_addr;
    logic  [1:0] ps_wr_be;

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        eep_we  <= 1'b0;
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE;
            sd_wr_req <= 1'b0; ps0_wr_req <= 1'b0; ps1_wr_req <= 1'b0;
        end else begin
            if (dl_we && !dl_we_d && !wf_full) begin
                wfifo[wf_wp[5:0]] <= {dl_addr, dl_data};
                wf_wp <= wf_wp + 7'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin
                    if (wa < IMG_SND) begin                       // 68000 program -> CRAM1
                        ps_wr_addr <= PS_PROG + 23'(wa[24:1]); ps_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        ps1_wr_req <= 1'b1; wst <= W_PS1;
                    end else if (wa < IMG_TILE) begin             // Z80 program -> CRAM1
                        ps_wr_addr <= PS_SND + 23'((wa - IMG_SND) >> 1); ps_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        ps1_wr_req <= 1'b1; wst <= W_PS1;
                    end else if (wa < IMG_CHR) begin              // tiles -> SDRAM
                        sd_wr_addr <= SD_TILE + 24'((wa - IMG_TILE) >> 1); sd_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_MAP) begin              // ROZ characters -> CRAM0
                        ps_wr_addr <= PS_CHR + 23'((wa - IMG_CHR) >> 1); ps_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        ps0_wr_req <= 1'b1; wst <= W_PS0;
                    end else if (wa < IMG_PCM) begin              // ROZ map -> CRAM0
                        ps_wr_addr <= PS_MAP + 23'((wa - IMG_MAP) >> 1); ps_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        ps0_wr_req <= 1'b1; wst <= W_PS0;
                    end else if (wa < IMG_SPR) begin              // PCM -> SDRAM
                        sd_wr_addr <= SD_PCM + 24'((wa - IMG_PCM) >> 1); sd_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_EEP) begin              // sprites -> SDRAM
                        sd_wr_addr <= SD_SPR + 24'((wa - IMG_SPR) >> 1); sd_wr_be <= wa[0] ? 2'b01 : 2'b10;
                        sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_END) begin              // EEPROM default -> the core
                        eep_we <= 1'b1; eep_addr <= wa[6:0]; eep_data <= wd;
                        wst <= W_POP;
                    end else wst <= W_POP;                        // beyond the image: dropped
                end
                W_SDRAM: if (sd_wr_ack)  begin sd_wr_req  <= 1'b0; wst <= W_POP; end
                W_PS0:   if (ps0_wr_ack) begin ps0_wr_req <= 1'b0; wst <= W_POP; end
                W_PS1:   if (ps1_wr_ack) begin ps1_wr_req <= 1'b0; wst <= W_POP; end
                W_POP:   begin wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------------- SDRAM
    logic [24:1] c_addr  [6];
    logic        c_req   [6];
    logic        c_we    [6];
    logic [15:0] c_wdata [6];
    logic  [1:0] c_be    [6];
    logic        c_ack   [6];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx;
    logic        b_req, b_wr, b_done;
    logic [15:0] b_data;
    logic  [9:0] b_widx;

    // client 0: PCM byte reads. The K054539s hold their request until the ack.
    logic pcm_lo;
    assign c_addr[0] = SD_PCM + 24'(pcm_addr[21:1]);
    assign c_req[0]  = pcm_req;
    assign c_we[0]   = 1'b0; assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    assign pcm_ack   = c_ack[0];
    always_ff @(posedge clk) pcm_lo <= pcm_addr[0];
    assign pcm_q     = pcm_lo ? sd_rdata[7:0] : sd_rdata[15:8];
    // client 1: the loader
    assign c_addr[1] = sd_wr_addr;
    assign c_req[1]  = sd_wr_req;
    assign c_we[1]   = 1'b1; assign c_wdata[1] = {wd, wd}; assign c_be[1] = sd_wr_be;
    assign sd_wr_ack = c_ack[1];
    // clients 2-5: none
    genvar gi;
    generate for (gi = 2; gi < 6; gi = gi + 1) begin : g_nocli
        assign c_addr[gi] = '0; assign c_req[gi] = 1'b0; assign c_we[gi] = 1'b0; assign c_wdata[gi] = '0; assign c_be[gi] = 2'b00;
    end endgenerate

    // burst port: tiles (2 words) first, then sprites (4 words)
    typedef enum logic [1:0] { B_IDLE, B_RUN, B_ACK } bst_t;
    bst_t  bst;
    logic  bsel;                        // 0 tiles, 1 sprites
    logic [18:0] tile_addr_l;
    logic [19:0] spr_addr_l;
    logic [15:0] bw [4];
    always_ff @(posedge clk) begin
        if (init) begin bst <= B_IDLE; b_req <= 1'b0; tile_ack <= 1'b0; spr_ack <= 1'b0; end
        else begin
            tile_ack <= 1'b0; spr_ack <= 1'b0;
            case (bst)
                B_IDLE: begin
                    if (tile_req) begin
                        bsel <= 1'b0; tile_addr_l <= tile_addr;
                        b_addr <= SD_TILE + {4'd0, tile_addr, 1'b0}; b_len <= 10'd2; b_req <= 1'b1; bst <= B_RUN;
                    end else if (spr_req) begin
                        bsel <= 1'b1; spr_addr_l <= spr_addr;
                        b_addr <= SD_SPR + {2'd0, spr_addr, 2'b00}; b_len <= 10'd4; b_req <= 1'b1; bst <= B_RUN;
                    end
                end
                B_RUN: begin
                    if (b_wr) bw[b_idx[1:0]] <= b_data;
                    if (b_done) begin b_req <= 1'b0; bst <= B_ACK; end
                end
                B_ACK: begin
                    // ack only the request that is still standing
                    if (!bsel && tile_req && tile_addr == tile_addr_l) tile_ack <= 1'b1;
                    if ( bsel && spr_req  && spr_addr  == spr_addr_l)  spr_ack  <= 1'b1;
                    bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase
        end
    end
    assign tile_q = {bw[0], bw[1]};
    assign spr_q  = {bw[0], bw[1], bw[2], bw[3]};

    logic dram_cs_n_unused;
    sdram_ctrl #(.NCLI(6)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(dram_cs_n_unused), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx(b_widx)
    );

    // --------------------------------------------------------------- PSRAM
    // CRAM0: ROZ characters (reader 0) and map (reader 1)
    psram_port u_cram0 (
        .clk(clk), .reset(init),
        .r0_req(chr_req), .r0_addr(PS_CHR + 23'(chr_addr[20:1])), .r0_ack(chr_ack), .r0_q(chr_q),
        .r1_req(map_req), .r1_addr(PS_MAP + 23'(map_addr[19:1])), .r1_ack(map_ack), .r1_q(map_q),
        .w_req(ps0_wr_req), .w_addr(ps_wr_addr), .w_data(wd), .w_be(ps_wr_be), .w_ack(ps0_wr_ack),
        .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(cram0_clk), .cram_adv_n(cram0_adv_n),
        .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n), .cram_oe_n(cram0_oe_n),
        .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n)
    );
    // CRAM1: 68000 program (reader 0) and Z80 program (reader 1, one byte of the word)
    logic [15:0] snd_word;
    logic        snd_lo;
    always_ff @(posedge clk) snd_lo <= snd_addr[0];
    psram_port u_cram1 (
        .clk(clk), .reset(init),
        .r0_req(prog_req), .r0_addr(PS_PROG + 23'(prog_addr[22:1])), .r0_ack(prog_ack), .r0_q(prog_q),
        .r1_req(snd_req),  .r1_addr(PS_SND  + 23'(snd_addr[17:1])),  .r1_ack(snd_ack),  .r1_q(snd_word),
        .w_req(ps1_wr_req), .w_addr(ps_wr_addr), .w_data(wd), .w_be(ps_wr_be), .w_ack(ps1_wr_ack),
        .cram_a(cram1_a), .cram_dq(cram1_dq), .cram_wait(cram1_wait), .cram_clk(cram1_clk), .cram_adv_n(cram1_adv_n),
        .cram_cre(cram1_cre), .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n), .cram_oe_n(cram1_oe_n),
        .cram_we_n(cram1_we_n), .cram_ub_n(cram1_ub_n), .cram_lb_n(cram1_lb_n)
    );
    assign snd_q = snd_lo ? snd_word[7:0] : snd_word[15:8];

    // ---------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init),
        .req(vram_req), .we(vram_we), .addr(vram_addr), .be(vram_be), .wdata(vram_wdata), .ack(vram_ack), .q(vram_q),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{b_widx, b_idx[9:2], dram_cs_n_unused, map_addr[0], chr_addr[0], IMG_PROG};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule


//------------------------------------------------------------------------------
// One PSRAM chip (async mode, single 16-bit accesses through psram.sv) behind
// two read clients and one write client. The writer is only used while the
// image loads and has priority; reader 0 comes before reader 1. An access
// runs to completion even if its client withdraws; the ack is raised only
// for a request that is still standing with the same address.
//------------------------------------------------------------------------------
module psram_port (
    input  logic        clk,
    input  logic        reset,
    input  logic        r0_req, input  logic [22:0] r0_addr, output logic r0_ack, output logic [15:0] r0_q,
    input  logic        r1_req, input  logic [22:0] r1_addr, output logic r1_ack, output logic [15:0] r1_q,
    input  logic        w_req,  input  logic [22:0] w_addr,  input  logic [7:0] w_data, input logic [1:0] w_be,
    output logic        w_ack,

    output logic [21:16] cram_a,
    inout  wire  [15:0] cram_dq,
    input  logic        cram_wait,
    output logic        cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n
);
    typedef enum logic [2:0] { P_IDLE, P_ISSUE, P_READ, P_WRITE, P_ACK } pst_t;
    pst_t        pst;
    logic  [1:0] who;                   // 0 reader 0, 1 reader 1, 2 writer
    logic [22:0] addr_l;
    logic        is_wr;
    logic        rd_en, wr_en, busy, avail;
    logic [15:0] dout;
    logic [15:0] q;

    always_ff @(posedge clk) begin
        r0_ack <= 1'b0; r1_ack <= 1'b0; w_ack <= 1'b0;
        rd_en <= 1'b0; wr_en <= 1'b0;
        if (reset) begin pst <= P_IDLE; end
        else case (pst)
            P_IDLE: begin
                if (w_req)       begin who <= 2'd2; addr_l <= w_addr;  is_wr <= 1'b1; pst <= P_ISSUE; end
                else if (r0_req) begin who <= 2'd0; addr_l <= r0_addr; is_wr <= 1'b0; pst <= P_ISSUE; end
                else if (r1_req) begin who <= 2'd1; addr_l <= r1_addr; is_wr <= 1'b0; pst <= P_ISSUE; end
            end
            P_ISSUE: if (!busy && !rd_en && !wr_en) begin
                if (is_wr) begin wr_en <= 1'b1; pst <= P_WRITE; end
                else       begin rd_en <= 1'b1; pst <= P_READ;  end
            end
            P_READ: if (avail) begin q <= dout; pst <= P_ACK; end
            P_WRITE: if (!busy && !wr_en) pst <= P_ACK;      // busy rises the cycle after the issue
            P_ACK: begin
                case (who)
                    2'd0: if (r0_req && r0_addr == addr_l) r0_ack <= 1'b1;
                    2'd1: if (r1_req && r1_addr == addr_l) r1_ack <= 1'b1;
                    default: w_ack <= 1'b1;
                endcase
                pst <= P_IDLE;
            end
            default: pst <= P_IDLE;
        endcase
    end
    assign r0_q = q;
    assign r1_q = q;

    // 96 MHz timings: the SNES core's controller with the access times padded
    // to 85 ns for the pin delays on top of the part's 70 ns
    psram #(
        .CLOCK_SPEED(96.0),
        .MAX_ACCESS_TIME_FROM_ADV(85),
        .MIN_WRITE_TIME_FROM_ADV(85)
    ) u_psram (
        .clk(clk),
        .bank_sel(addr_l[22]), .addr(addr_l[21:0]),
        .write_en(wr_en), .data_in({w_data, w_data}), .write_high_byte(w_be[1]), .write_low_byte(w_be[0]),
        .read_en(rd_en), .read_avail(avail), .data_out(dout), .busy(busy),
        .cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(cram_wait), .cram_clk(cram_clk), .cram_adv_n(cram_adv_n),
        .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n),
        .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
    );
endmodule


//------------------------------------------------------------------------------
// The Pocket's asynchronous SRAM (128K x 16, 10 ns) behind one request/ack
// port: the K056832 tile RAM. Every pin is a register held for whole cycles,
// a read captures the data three cycles after the address, a write holds
// WE low for two. The ack goes only to a request still standing with the
// same address (a renderer withdraws at line start).
//------------------------------------------------------------------------------
module sram_port (
    input  logic        clk,
    input  logic        reset,
    input  logic        req,
    input  logic        we,
    input  logic [15:0] addr,
    input  logic  [1:0] be,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] q,

    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    typedef enum logic [3:0] { S_IDLE, S_R1, S_R2, S_R3, S_RCAP, S_W0, S_W1, S_W2, S_W3, S_ACK } st_t;
    st_t         st;
    logic [15:0] addr_l, dq_out;
    logic        we_l, dq_oe;
    logic [15:0] dq_in;
    assign sram_dq = dq_oe ? dq_out : 16'bz;

    always_ff @(posedge clk) begin
        dq_in <= sram_dq;
        ack   <= 1'b0;
        if (reset) begin
            st <= S_IDLE; sram_oe_n <= 1'b1; sram_we_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
            dq_oe <= 1'b0; sram_a <= '0;
        end else case (st)
            S_IDLE: if (req) begin
                addr_l <= addr; we_l <= we;
                sram_a <= {1'b0, addr};
                if (we) begin
                    dq_out <= wdata; dq_oe <= 1'b1;
                    sram_ub_n <= ~be[1]; sram_lb_n <= ~be[0]; sram_oe_n <= 1'b1;
                    st <= S_W0;
                end else begin
                    sram_ub_n <= 1'b0; sram_lb_n <= 1'b0; sram_oe_n <= 1'b0;
                    st <= S_R1;
                end
            end
            // read: address and OE out, data back through the input register
            S_R1: st <= S_R2;
            S_R2: st <= S_R3;
            S_R3: st <= S_RCAP;
            S_RCAP: begin q <= dq_in; sram_oe_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; st <= S_ACK; end
            // write: address and data settle, WE low for two cycles, data held after
            S_W0: begin sram_we_n <= 1'b0; st <= S_W1; end
            S_W1: st <= S_W2;
            S_W2: begin sram_we_n <= 1'b1; st <= S_W3; end
            S_W3: begin dq_oe <= 1'b0; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; st <= S_ACK; end
            S_ACK: begin
                if (req && addr == addr_l && we == we_l) ack <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule

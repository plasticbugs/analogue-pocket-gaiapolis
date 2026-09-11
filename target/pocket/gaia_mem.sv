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

module gaia_mem #(
    parameter int TEST_SHRINK = 0       // the memory test reads 1/2^n of each region (benches)
) (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase-shifted, drives the SDRAM clock pin
    input  logic        init,           // hardware reset: re-initialise the SDRAM
    output logic        ready,
    // the built-in memory test (mem_test below): started by test_start while
    // the core is in reset; the platform keeps the core there while test_run
    input  logic        test_start,
    output logic        test_run, test_done,
    output logic  [6:0] test_ok,        // per region: prog, snd, tile, chr, map, pcm, spr -- read back == loaded
    output logic  [6:0] test_stable,    // per region: the second pass read the same as the first
    output logic        vram_ok,
    output logic  [3:0] vram_bad,       // tile RAM words that read back wrong, saturating
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
    // The APF loader delivers at most one byte per 8 clocks. A PSRAM write
    // costs about 13, so consecutive even/odd bytes are paired into one
    // 16-bit word write before a small FIFO that absorbs the loader's
    // bursts; the dispatcher behind it routes each entry to its memory as a
    // byte-enabled word write. A lone even byte waits for its partner (the
    // bridge delivers aligned 4-byte words, so the partner is next) and is
    // flushed alone if none arrives.
    logic        dl_we_d;
    logic        pend_v;
    logic [24:0] pend_a;
    logic  [7:0] pend_d, pend_age;
    wire         nb = dl_we && !dl_we_d;                // a new byte this clock
    logic        wf_push;
    logic [41:0] wf_in;                                 // {word addr[24:1], be[1:0], data[15:0]}
    always_comb begin
        wf_push = 1'b0; wf_in = '0;
        if (nb && pend_v && dl_addr == {pend_a[24:1], 1'b1}) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], 2'b11, pend_d, dl_data};
        end else if (pend_v && (nb || pend_age == 8'hff)) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], pend_a[0] ? 2'b01 : 2'b10, pend_d, pend_d};
        end
    end

    logic [41:0] wfifo [64];
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire [41:0]  wf_head  = wfifo[wf_rp[5:0]];
    wire [24:1]  wa       = wf_head[41:18];
    wire  [1:0]  wbe      = wf_head[17:16];
    wire [15:0]  wd       = wf_head[15:0];

    typedef enum logic [2:0] { W_IDLE, W_SDRAM, W_PS0, W_PS1, W_EEP, W_EEP2 } wst_t;
    wst_t wst;

    // SDRAM write client (client 1) and PSRAM writer ports
    logic        sd_wr_req, sd_wr_ack;
    logic [24:1] sd_wr_addr;
    logic        ps0_wr_req, ps0_wr_ack, ps1_wr_req, ps1_wr_ack;
    logic [22:0] ps_wr_addr;

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        eep_we  <= 1'b0;
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; pend_v <= 1'b0; pend_age <= '0;
            sd_wr_req <= 1'b0; ps0_wr_req <= 1'b0; ps1_wr_req <= 1'b0;
        end else begin
            // pairing stage
            if (nb) begin
                if (pend_v && dl_addr == {pend_a[24:1], 1'b1}) pend_v <= 1'b0;
                else begin pend_v <= 1'b1; pend_a <= dl_addr; pend_d <= dl_data; pend_age <= '0; end
            end else if (pend_v) begin
                if (pend_age == 8'hff) pend_v <= 1'b0; else pend_age <= pend_age + 8'd1;
            end
            if (wf_push) begin              // never full: entries arrive at most one per 16 clocks
                wfifo[wf_wp[5:0]] <= wf_in;
                wf_wp <= wf_wp + 7'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin
                    if (wa < IMG_SND[24:1]) begin                 // 68000 program -> CRAM1
                        ps_wr_addr <= PS_PROG + 23'(wa); ps1_wr_req <= 1'b1; wst <= W_PS1;
                    end else if (wa < IMG_TILE[24:1]) begin       // Z80 program -> CRAM1
                        ps_wr_addr <= PS_SND + 23'(wa - IMG_SND[24:1]); ps1_wr_req <= 1'b1; wst <= W_PS1;
                    end else if (wa < IMG_CHR[24:1]) begin        // tiles -> SDRAM
                        sd_wr_addr <= SD_TILE + (wa - IMG_TILE[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_MAP[24:1]) begin        // ROZ characters -> CRAM0
                        ps_wr_addr <= PS_CHR + 23'(wa - IMG_CHR[24:1]); ps0_wr_req <= 1'b1; wst <= W_PS0;
                    end else if (wa < IMG_PCM[24:1]) begin        // ROZ map -> CRAM0
                        ps_wr_addr <= PS_MAP + 23'(wa - IMG_MAP[24:1]); ps0_wr_req <= 1'b1; wst <= W_PS0;
                    end else if (wa < IMG_SPR[24:1]) begin        // PCM -> SDRAM
                        sd_wr_addr <= SD_PCM + (wa - IMG_PCM[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_EEP[24:1]) begin        // sprites -> SDRAM
                        sd_wr_addr <= SD_SPR + (wa - IMG_SPR[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_END[24:1]) begin        // EEPROM default -> the core, a byte at a time
                        eep_we <= wbe[1]; eep_addr <= {wa[6:1], 1'b0}; eep_data <= wd[15:8];
                        wst <= W_EEP;
                    end else begin wf_rp <= wf_rp + 7'd1; end     // beyond the image: dropped
                end
                W_EEP: begin
                    eep_we <= wbe[0]; eep_addr <= {wa[6:1], 1'b1}; eep_data <= wd[7:0];
                    wf_rp <= wf_rp + 7'd1; wst <= W_IDLE;
                end
                // the acks pop the entry: the SDRAM's on completion, the PSRAM ports' on take
                W_SDRAM: if (sd_wr_ack)  begin sd_wr_req  <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                W_PS0:   if (ps0_wr_ack) begin ps0_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                W_PS1:   if (ps1_wr_ack) begin ps1_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
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

    // the memory test drives the ports while it runs (the core is in reset)
    logic        t_prog_req, t_snd_req, t_tile_req, t_chr_req, t_map_req, t_pcm_req, t_spr_req;
    logic [22:1] t_prog_addr; logic [17:0] t_snd_addr; logic [18:0] t_tile_addr; logic [20:0] t_chr_addr;
    logic [19:0] t_map_addr;  logic [21:0] t_pcm_addr; logic [19:0] t_spr_addr;
    logic        t_vram_req, t_vram_we; logic [15:0] t_vram_addr, t_vram_wdata;
    wire         prog_req_i  = test_run ? t_prog_req  : prog_req;
    wire [22:1]  prog_addr_i = test_run ? t_prog_addr : prog_addr;
    wire         snd_req_i   = test_run ? t_snd_req   : snd_req;
    wire [17:0]  snd_addr_i  = test_run ? t_snd_addr  : snd_addr;
    wire         tile_req_i  = test_run ? t_tile_req  : tile_req;
    wire [18:0]  tile_addr_i = test_run ? t_tile_addr : tile_addr;
    wire         chr_req_i   = test_run ? t_chr_req   : chr_req;
    wire [20:0]  chr_addr_i  = test_run ? t_chr_addr  : chr_addr;
    wire         map_req_i   = test_run ? t_map_req   : map_req;
    wire [19:0]  map_addr_i  = test_run ? t_map_addr  : map_addr;
    wire         pcm_req_i   = test_run ? t_pcm_req   : pcm_req;
    wire [21:0]  pcm_addr_i  = test_run ? t_pcm_addr  : pcm_addr;
    wire         spr_req_i   = test_run ? t_spr_req   : spr_req;
    wire [19:0]  spr_addr_i  = test_run ? t_spr_addr  : spr_addr;
    wire         vram_req_i  = test_run ? t_vram_req  : vram_req;
    wire         vram_we_i   = test_run ? t_vram_we   : vram_we;
    wire [15:0]  vram_addr_i = test_run ? t_vram_addr : vram_addr;
    wire  [1:0]  vram_be_i   = test_run ? 2'b11       : vram_be;
    wire [15:0]  vram_wdata_i = test_run ? t_vram_wdata : vram_wdata;

    mem_test #(.SHRINK(TEST_SHRINK)) u_test (
        .clk(clk), .init(init), .ready(ready), .start(test_start), .run(test_run), .done(test_done),
        .ok(test_ok), .stable(test_stable), .vram_ok(vram_ok), .vram_bad(vram_bad),
        .dl_we(dl_we && !dl_we_d), .dl_addr(dl_addr), .dl_data(dl_data),
        .prog_req(t_prog_req), .prog_addr(t_prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .snd_req(t_snd_req), .snd_addr(t_snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .tile_req(t_tile_req), .tile_addr(t_tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .chr_req(t_chr_req), .chr_addr(t_chr_addr), .chr_ack(chr_ack), .chr_q(chr_q),
        .map_req(t_map_req), .map_addr(t_map_addr), .map_ack(map_ack), .map_q(map_q),
        .pcm_req(t_pcm_req), .pcm_addr(t_pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .spr_req(t_spr_req), .spr_addr(t_spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(t_vram_req), .vram_we(t_vram_we), .vram_addr(t_vram_addr), .vram_wdata(t_vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q)
    );

    // client 0: PCM byte reads. The K054539s hold their request until the ack.
    logic pcm_lo;
    assign c_addr[0] = SD_PCM + 24'(pcm_addr_i[21:1]);
    assign c_req[0]  = pcm_req_i;
    assign c_we[0]   = 1'b0; assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    assign pcm_ack   = c_ack[0];
    always_ff @(posedge clk) pcm_lo <= pcm_addr_i[0];
    assign pcm_q     = pcm_lo ? sd_rdata[7:0] : sd_rdata[15:8];
    // client 1: the loader
    assign c_addr[1] = sd_wr_addr;
    assign c_req[1]  = sd_wr_req;
    assign c_we[1]   = 1'b1; assign c_wdata[1] = wd; assign c_be[1] = wbe;
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
                B_IDLE: begin                   // not a request being acked right now
                    if (tile_req_i && !tile_ack) begin
                        bsel <= 1'b0; tile_addr_l <= tile_addr_i;
                        b_addr <= SD_TILE + {4'd0, tile_addr_i, 1'b0}; b_len <= 10'd2; b_req <= 1'b1; bst <= B_RUN;
                    end else if (spr_req_i && !spr_ack) begin
                        bsel <= 1'b1; spr_addr_l <= spr_addr_i;
                        b_addr <= SD_SPR + {2'd0, spr_addr_i, 2'b00}; b_len <= 10'd4; b_req <= 1'b1; bst <= B_RUN;
                    end
                end
                B_RUN: begin
                    if (b_wr) bw[b_idx[1:0]] <= b_data;
                    if (b_done) begin b_req <= 1'b0; bst <= B_ACK; end
                end
                B_ACK: begin
                    // ack only the request that is still standing
                    if (!bsel && tile_req_i && tile_addr_i == tile_addr_l) tile_ack <= 1'b1;
                    if ( bsel && spr_req_i  && spr_addr_i  == spr_addr_l)  spr_ack  <= 1'b1;
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
        .r0_req(chr_req_i), .r0_addr(PS_CHR + 23'(chr_addr_i[20:1])), .r0_ack(chr_ack), .r0_q(chr_q),
        .r1_req(map_req_i), .r1_addr(PS_MAP + 23'(map_addr_i[19:1])), .r1_ack(map_ack), .r1_q(map_q),
        .w_req(ps0_wr_req), .w_addr(ps_wr_addr), .w_data(wd), .w_be(wbe), .w_ack(ps0_wr_ack),
        .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(cram0_clk), .cram_adv_n(cram0_adv_n),
        .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n), .cram_oe_n(cram0_oe_n),
        .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n)
    );
    // CRAM1: 68000 program (reader 0) and Z80 program (reader 1, one byte of the word)
    logic [15:0] snd_word;
    logic        snd_lo;
    always_ff @(posedge clk) snd_lo <= snd_addr_i[0];
    psram_port u_cram1 (
        .clk(clk), .reset(init),
        .r0_req(prog_req_i), .r0_addr(PS_PROG + 23'(prog_addr_i[22:1])), .r0_ack(prog_ack), .r0_q(prog_q),
        .r1_req(snd_req_i),  .r1_addr(PS_SND  + 23'(snd_addr_i[17:1])),  .r1_ack(snd_ack),  .r1_q(snd_word),
        .w_req(ps1_wr_req), .w_addr(ps_wr_addr), .w_data(wd), .w_be(wbe), .w_ack(ps1_wr_ack),
        .cram_a(cram1_a), .cram_dq(cram1_dq), .cram_wait(cram1_wait), .cram_clk(cram1_clk), .cram_adv_n(cram1_adv_n),
        .cram_cre(cram1_cre), .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n), .cram_oe_n(cram1_oe_n),
        .cram_we_n(cram1_we_n), .cram_ub_n(cram1_ub_n), .cram_lb_n(cram1_lb_n)
    );
    assign snd_q = snd_lo ? snd_word[7:0] : snd_word[15:8];

    // ---------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init),
        .req(vram_req_i), .we(vram_we_i), .addr(vram_addr_i), .be(vram_be_i), .wdata(vram_wdata_i), .ack(vram_ack), .q(vram_q),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{b_widx, b_idx[9:2], dram_cs_n_unused, map_addr_i[0], chr_addr_i[0], IMG_PROG, wf_head[0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule


//------------------------------------------------------------------------------
// One PSRAM chip (async mode, single 16-bit accesses through psram.sv) behind
// two read clients and one write client. The writer is only used while the
// image loads and has priority; its ack means "taken" (address, data and
// byte enables latched) so the loader can queue the next word while this
// one writes. The two readers alternate when both are waiting, so neither
// waits for more than one access of the other: an access is 12 clocks from
// take to ack, and both CPUs' bus cycles are 24. Reader 1 (the Z80, a byte
// of the word at a time) has a two-word cache: the word it last fetched and
// the one after it, prefetched while the chip is otherwise idle, so
// straight-line code never waits and only a jump costs an access. A read
// runs to completion even if its client withdraws; the ack is raised only
// for a request that is still standing with the same address.
//------------------------------------------------------------------------------
module psram_port (
    input  logic        clk,
    input  logic        reset,
    input  logic        r0_req, input  logic [22:0] r0_addr, output logic r0_ack, output logic [15:0] r0_q,
    input  logic        r1_req, input  logic [22:0] r1_addr, output logic r1_ack, output logic [15:0] r1_q,
    input  logic        w_req,  input  logic [22:0] w_addr,  input  logic [15:0] w_data, input logic [1:0] w_be,
    output logic        w_ack,

    output logic [21:16] cram_a,
    inout  wire  [15:0] cram_dq,
    input  logic        cram_wait,
    output logic        cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n
);
    typedef enum logic [1:0] { P_IDLE, P_READ, P_WRITE } pst_t;
    pst_t        pst;
    logic  [1:0] who;                   // the read in flight: 0 reader 0, 1 reader 1, 2 prefetch
    logic        last;                  // the reader served last, for the alternation
    logic [22:0] addr_l;
    logic [15:0] wdata_l;
    logic  [1:0] be_l;
    logic        rd_en, wr_en, busy, avail;
    logic [15:0] dout;
    // reader 1's cache: c1 the word last fetched, c2 the word after it
    logic        c1_valid, c2_valid, pf_want;
    logic [22:0] c1_addr, c2_addr, pf_addr;
    logic [15:0] c1_q, c2_q;

    // A request is still standing in the clock its ack is visible (the client
    // drops it on seeing the ack), so a request being acked is not a new one.
    wire hit1a = r1_req && !r1_ack && c1_valid && (r1_addr == c1_addr);
    wire hit1b = r1_req && !r1_ack && c2_valid && (r1_addr == c2_addr);
    wire hit1  = hit1a || hit1b;
    wire pend0 = r0_req && !r0_ack;
    wire pend1 = r1_req && !r1_ack && !hit1;
    wire pick0 = pend0 && (!pend1 || last);
    wire pick1 = pend1 && !pick0;

    always_ff @(posedge clk) begin
        r0_ack <= 1'b0; r1_ack <= 1'b0; w_ack <= 1'b0;
        rd_en <= 1'b0; wr_en <= 1'b0;
        if (reset) begin pst <= P_IDLE; c1_valid <= 1'b0; c2_valid <= 1'b0; pf_want <= 1'b0; last <= 1'b0; end
        else begin
            // a cache hit costs no access and is served in any state except
            // while reader 1's own fetch is in flight; moving on to the
            // prefetched word asks for the one after it
            if (hit1 && !(pst == P_READ && who == 2'd1)) begin
                r1_ack <= 1'b1; r1_q <= hit1a ? c1_q : c2_q;
                if (!hit1a) begin
                    c1_valid <= 1'b1; c1_addr <= c2_addr; c1_q <= c2_q;
                    pf_want <= 1'b1; pf_addr <= c2_addr + 23'd1;
                end
            end
            case (pst)
                P_IDLE: if (!busy && !rd_en && !wr_en) begin
                    if (w_req && !w_ack) begin
                        addr_l <= w_addr; wdata_l <= w_data; be_l <= w_be;
                        wr_en <= 1'b1; w_ack <= 1'b1; c1_valid <= 1'b0; c2_valid <= 1'b0; pf_want <= 1'b0;
                        pst <= P_WRITE;
                    end else if (pick0) begin
                        who <= 2'd0; addr_l <= r0_addr; rd_en <= 1'b1; last <= 1'b0; pst <= P_READ;
                    end else if (pick1) begin
                        who <= 2'd1; addr_l <= r1_addr; rd_en <= 1'b1; last <= 1'b1; pst <= P_READ;
                    end else if (pf_want) begin
                        who <= 2'd2; addr_l <= pf_addr; rd_en <= 1'b1; pf_want <= 1'b0; pst <= P_READ;
                    end
                end
                P_READ: if (avail) begin
                    case (who)
                        2'd0: if (r0_req && r0_addr == addr_l) begin r0_ack <= 1'b1; r0_q <= dout; end
                        2'd1: begin
                            if (r1_req && r1_addr == addr_l) begin r1_ack <= 1'b1; r1_q <= dout; end
                            c1_valid <= 1'b1; c1_addr <= addr_l; c1_q <= dout;
                            pf_want <= 1'b1; pf_addr <= addr_l + 23'd1;
                        end
                        default: begin c2_valid <= 1'b1; c2_addr <= addr_l; c2_q <= dout; end
                    endcase
                    pst <= P_IDLE;
                end
                P_WRITE: if (!busy && !wr_en) pst <= P_IDLE;     // busy rises the cycle after the issue
                default: pst <= P_IDLE;
            endcase
        end
    end

    // 96 MHz timings: the SNES core's controller with the access times padded
    // to 85 ns for the pin delays on top of the part's 70 ns: reads capture 9
    // clocks (94 ns) after the address strobe. The SNES core captures at
    // 81.5 ns (7 clocks of 85.9 MHz); 80 here would give 8 clocks (83 ns) and
    // an 11-clock access, to be tried with the memory test as the judge.
    psram #(
        .CLOCK_SPEED(96.0),
        .MAX_ACCESS_TIME_FROM_ADV(85),
        .MIN_WRITE_TIME_FROM_ADV(85)
    ) u_psram (
        .clk(clk),
        .bank_sel(addr_l[22]), .addr(addr_l[21:0]),
        .write_en(wr_en), .data_in(wdata_l), .write_high_byte(be_l[1]), .write_low_byte(be_l[0]),
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
            S_IDLE: if (req && !ack) begin      // not the request being acked right now
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


//------------------------------------------------------------------------------
// The built-in memory test. Every byte of the image is summed per region as
// it streams in; on `start` (the core held in reset) each region is read
// back through the core's own port and summed again -- twice -- so a region
// reports "ok" (read back what was loaded) and "stable" (the two passes
// agreed), which separates a wrong write from a marginal read. The tile RAM
// is then written with a pattern and read back, counting bad words. About
// 2.5 s at 96 MHz; the results sit on the diagnostic overlay.
//------------------------------------------------------------------------------
module mem_test #(
    parameter int SHRINK = 0
) (
    input  logic        clk,
    input  logic        init,
    input  logic        ready,
    input  logic        start,
    output logic        run, done,
    output logic  [6:0] ok, stable,
    output logic        vram_ok,
    output logic  [3:0] vram_bad,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    output logic        prog_req, output logic [22:1] prog_addr, input logic prog_ack, input logic [15:0] prog_q,
    output logic        snd_req,  output logic [17:0] snd_addr,  input logic snd_ack,  input logic  [7:0] snd_q,
    output logic        tile_req, output logic [18:0] tile_addr, input logic tile_ack, input logic [31:0] tile_q,
    output logic        chr_req,  output logic [20:0] chr_addr,  input logic chr_ack,  input logic [15:0] chr_q,
    output logic        map_req,  output logic [19:0] map_addr,  input logic map_ack,  input logic [15:0] map_q,
    output logic        pcm_req,  output logic [21:0] pcm_addr,  input logic pcm_ack,  input logic  [7:0] pcm_q,
    output logic        spr_req,  output logic [19:0] spr_addr,  input logic spr_ack,  input logic [63:0] spr_q,
    output logic        vram_req, output logic vram_we, output logic [15:0] vram_addr, output logic [15:0] vram_wdata,
    input  logic        vram_ack, input logic [15:0] vram_q
);
    localparam [24:0] IMG_SND  = 25'h0300000, IMG_TILE = 25'h0340000;
    localparam [24:0] IMG_CHR  = 25'h0540000, IMG_MAP  = 25'h06C0000, IMG_PCM  = 25'h0760000;
    localparam [24:0] IMG_SPR  = 25'h0B60000, IMG_EEP  = 25'h1360000;
    // accesses per region, in each port's unit
    localparam [22:0] N_PROG = 23'h180000, N_SND = 23'h040000, N_TILE = 23'h080000, N_CHR = 23'h0C0000;
    localparam [22:0] N_MAP  = 23'h050000, N_PCM = 23'h400000, N_SPR  = 23'h100000;

    // the sums as the image arrives (a new image restarts them)
    logic [23:0] lsum [7];
    logic  [2:0] lreg;
    always_comb begin
        if      (dl_addr < IMG_SND)  lreg = 3'd0;
        else if (dl_addr < IMG_TILE) lreg = 3'd1;
        else if (dl_addr < IMG_CHR)  lreg = 3'd2;
        else if (dl_addr < IMG_MAP)  lreg = 3'd3;
        else if (dl_addr < IMG_PCM)  lreg = 3'd4;
        else if (dl_addr < IMG_SPR)  lreg = 3'd5;
        else if (dl_addr < IMG_EEP)  lreg = 3'd6;
        else                         lreg = 3'd7;
    end
    always_ff @(posedge clk) begin
        if (init || (dl_we && dl_addr == 25'd0)) begin
            for (int i = 0; i < 7; i++) lsum[i] <= (i == 0 && dl_we) ? 24'(dl_data) : '0;
        end else if (dl_we && lreg != 3'd7) lsum[lreg] <= lsum[lreg] + 24'(dl_data);
    end

    // the read-back
    typedef enum logic [2:0] { T_IDLE, T_REQ, T_NEXT, T_VW, T_VR, T_DONE } tst_t;
    tst_t        st;
    logic  [2:0] region;
    logic        pass;
    logic [22:0] idx, n_end;
    logic [23:0] acc;
    logic [23:0] asum [7];              // the first pass's sums
    logic        start_d;
    logic [10:0] bytes;                 // the bytes of one access, summed
    logic        ack;
    always_comb begin
        case (region)
            3'd0: begin ack = prog_ack; bytes = 11'(prog_q[15:8]) + 11'(prog_q[7:0]); n_end = N_PROG >> SHRINK; end
            3'd1: begin ack = snd_ack;  bytes = 11'(snd_q); n_end = N_SND >> SHRINK; end
            3'd2: begin ack = tile_ack; bytes = 11'(tile_q[31:24]) + 11'(tile_q[23:16]) + 11'(tile_q[15:8]) + 11'(tile_q[7:0]); n_end = N_TILE >> SHRINK; end
            3'd3: begin ack = chr_ack;  bytes = 11'(chr_q[15:8]) + 11'(chr_q[7:0]); n_end = N_CHR >> SHRINK; end
            3'd4: begin ack = map_ack;  bytes = 11'(map_q[15:8]) + 11'(map_q[7:0]); n_end = N_MAP >> SHRINK; end
            3'd5: begin ack = pcm_ack;  bytes = 11'(pcm_q); n_end = N_PCM >> SHRINK; end
            default: begin ack = spr_ack;
                bytes = 11'(spr_q[63:56]) + 11'(spr_q[55:48]) + 11'(spr_q[47:40]) + 11'(spr_q[39:32])
                      + 11'(spr_q[31:24]) + 11'(spr_q[23:16]) + 11'(spr_q[15:8]) + 11'(spr_q[7:0]);
                n_end = N_SPR >> SHRINK; end
        endcase
    end
    assign prog_req = run && st == T_REQ && region == 3'd0;  assign prog_addr = idx[21:0];
    assign snd_req  = run && st == T_REQ && region == 3'd1;  assign snd_addr  = idx[17:0];
    assign tile_req = run && st == T_REQ && region == 3'd2;  assign tile_addr = idx[18:0];
    assign chr_req  = run && st == T_REQ && region == 3'd3;  assign chr_addr  = {idx[19:0], 1'b0};
    assign map_req  = run && st == T_REQ && region == 3'd4;  assign map_addr  = {idx[18:0], 1'b0};
    assign pcm_req  = run && st == T_REQ && region == 3'd5;  assign pcm_addr  = idx[21:0];
    assign spr_req  = run && st == T_REQ && region == 3'd6;  assign spr_addr  = idx[19:0];
    // the tile RAM pattern: every address bit in both bytes
    wire [15:0] vpat = idx[15:0] ^ {idx[10:0], 5'b10110} ^ 16'hA55A;
    assign vram_req   = run && (st == T_VW || st == T_VR);
    assign vram_we    = st == T_VW;
    assign vram_addr  = idx[15:0];
    assign vram_wdata = vpat;

    always_ff @(posedge clk) begin
        start_d <= start;
        if (init) begin st <= T_IDLE; run <= 1'b0; done <= 1'b0; ok <= '0; stable <= '0; vram_ok <= 1'b0; vram_bad <= '0; end
        else case (st)
            T_IDLE: if (start && !start_d && ready) begin
                run <= 1'b1; done <= 1'b0; region <= 3'd0; pass <= 1'b0; idx <= '0; acc <= '0; st <= T_REQ;
            end
            T_REQ: if (ack) begin
                acc <= acc + 24'(bytes);
                if (idx == n_end - 23'd1) st <= T_NEXT; else idx <= idx + 23'd1;
            end
            T_NEXT: begin
                if (!pass) begin asum[region] <= acc; ok[region] <= (acc == lsum[region]); end
                else stable[region] <= (acc == asum[region]);
                acc <= '0; idx <= '0; st <= T_REQ;
                if (region != 3'd6) region <= region + 3'd1;
                else if (!pass) begin pass <= 1'b1; region <= 3'd0; end
                else begin vram_bad <= '0; st <= T_VW; end
            end
            T_VW: if (vram_ack) begin
                if (idx[15:0] == 16'hffff) begin idx <= '0; st <= T_VR; end else idx <= idx + 23'd1;
            end
            T_VR: if (vram_ack) begin
                if (vram_q != vpat && vram_bad != 4'hf) vram_bad <= vram_bad + 4'd1;
                if (idx[15:0] == 16'hffff) st <= T_DONE; else idx <= idx + 23'd1;
            end
            T_DONE: begin vram_ok <= (vram_bad == 4'd0); run <= 1'b0; done <= 1'b1; st <= T_IDLE; end
            default: st <= T_IDLE;
        endcase
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{idx[22:16]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

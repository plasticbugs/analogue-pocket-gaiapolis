//------------------------------------------------------------------------------
// K054539 8-channel PCM/ADPCM sound chip -- register interface, ROM/RAM read
// port and timer. Modelled on MAME's k054539.cpp.
//
// This half is what the Z80's self-test and the game's driver code talk to:
//   0x000-0x0ff  channel registers (8 x 0x20)
//   0x200-0x22f  global: 0x214 key on, 0x215 key off, 0x227 timer period,
//                0x22c active channels, 0x22d ROM/RAM data port,
//                0x22e ROM bank (0x80 = internal RAM), 0x22f control
// Reading 0x22d with control bit 4 set streams the ROM at bank*0x20000 +
// pointer, or the 32 KB internal RAM when the bank is 0x80; writing 0x22d
// with the bank at 0x80 writes that RAM. The pointer post-increments in
// both cases. The timer output toggles every 7200/(38+period) samples at
// 48 kHz (clock/384) and drives the Z80's NMI on the board.
//
// Audio rendering is not here yet: samples are silent, with the keyed
// channel state kept so the renderer can be added without touching this.
//------------------------------------------------------------------------------
`default_nettype none

module k054539 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_48k,        // one pulse per output sample

    // Z80 side
    input  logic        cs,
    input  logic        wr,
    input  logic        rd,
    input  logic  [9:0] addr,           // 0x000..0x22f
    input  logic  [7:0] wdata,
    output logic  [7:0] rdata,
    output logic        rd_stall,       // hold the CPU while a ROM read is in flight

    // sample ROM, 4 MB, byte address
    output logic        rom_req,
    output logic [21:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,

    output logic        timer_out,      // toggles; NMI on its rising edge
    output logic [15:0] snd_l,
    output logic [15:0] snd_r
);
    logic [7:0] regs [560];             // 0x000..0x22f
    logic [7:0] ram  [32768];           // reverb / self-test RAM
    logic [16:0] cur_ptr;
    logic  [7:0] rom_bank;
    logic [15:0] tcount;
    logic  [7:0] ram_q;

    wire [14:0] ram_addr = {cur_ptr[16], cur_ptr[13:0]};   // (ptr & 0x3fff) | (ptr & 0x10000) >> 2
    wire        ram_sel  = (rom_bank == 8'h80);
    wire        stream_en = regs[10'h22f][4];

    // ---- data port read: ROM reads go through the request/ack port ----
    typedef enum logic [1:0] { P_IDLE, P_ROM, P_DONE } pst_t;
    pst_t pst;
    logic [7:0] port_q;
    logic       rd_d;

    always_ff @(posedge clk) ram_q <= ram[ram_addr];

    always_comb begin
        rdata = regs[addr];
        if (addr == 10'h22d) rdata = stream_en ? port_q : 8'h00;
    end
    assign rd_stall = cs && rd && (addr == 10'h22d) && stream_en && !ram_sel && (pst != P_DONE);

    // timer: toggle every 7200/(38+period) samples
    wire [15:0] tperiod = 16'd7200 / (16'd38 + {8'd0, regs[10'h227]});

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 560; i++) regs[i] <= '0;
            cur_ptr <= '0; rom_bank <= '0; pst <= P_IDLE; rom_req <= 1'b0;
            timer_out <= 1'b0; tcount <= '0; rd_d <= 1'b0;
        end else begin
            rd_d <= cs && rd;

            // ---- streaming read of 0x22d ----
            case (pst)
                P_IDLE: if (cs && rd && addr == 10'h22d && stream_en) begin
                    if (ram_sel) begin
                        port_q <= ram_q; pst <= P_DONE;
                    end else begin
                        rom_addr <= {rom_bank[4:0], cur_ptr};    // bank*0x20000 + ptr, 4 MB
                        rom_req <= 1'b1; pst <= P_ROM;
                    end
                end
                P_ROM: if (rom_ack) begin
                    port_q <= rom_q; rom_req <= 1'b0; pst <= P_DONE;
                end
                P_DONE: if (!(cs && rd)) begin          // the CPU has taken the byte
                    cur_ptr <= cur_ptr + 17'd1;
                    pst <= P_IDLE;
                end
                default: pst <= P_IDLE;
            endcase

            // ---- writes ----
            if (cs && wr) begin
                case (addr)
                    10'h214: regs[10'h22c] <= regs[10'h22c] | wdata;           // key on
                    10'h215: regs[10'h22c] <= regs[10'h22c] & ~wdata;          // key off
                    10'h22d: begin
                        if (ram_sel) ram[ram_addr] <= wdata;
                        cur_ptr <= cur_ptr + 17'd1;
                    end
                    10'h22e: begin rom_bank <= wdata; cur_ptr <= '0; end
                    10'h227: begin tcount <= '0; timer_out <= 1'b0; end
                    default: ;
                endcase
                if (addr != 10'h214 && addr != 10'h215) regs[addr] <= wdata;
                if (addr == 10'h22f && !wdata[5]) timer_out <= 1'b0;   // timer output disabled
            end

            // ---- timer ----
            if (cen_48k && regs[10'h22f][5]) begin
                if (tcount + 16'd1 >= tperiod) begin
                    tcount <= '0; timer_out <= ~timer_out;
                end else tcount <= tcount + 16'd1;
            end
        end
    end

    assign snd_l = '0;
    assign snd_r = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = rd_d;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

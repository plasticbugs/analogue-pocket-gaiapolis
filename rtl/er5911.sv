//------------------------------------------------------------------------------
// ER5911 serial EEPROM, 128 x 8, as MAME's eeprom_serial_er5911_device models
// it (eepromser.cpp): a start bit, a 2-bit opcode and a 9-bit address field
// (only the low 7 bits select a cell) on rising CLK while CS is high; READ
// shifts data out MSB first after a dummy 0; WRITE takes 8 more data bits;
// opcode 0 uses the top two address bits for LOCK / ERASEALL / UNLOCK. ERASE
// maps to WRITE on this part. DO reads 1 when not shifting data out (pull-up),
// READY reads 0 for a while after a write. tools/eeprom_replay.py checks this
// protocol against MAME's pin traffic.
//
// Contents load through the byte port: the 128-byte default image in the ROM
// file at start, and a saved image later if the platform provides one.
//------------------------------------------------------------------------------
`default_nettype none

module er5911 #(
    parameter int BUSY_CLOCKS = 960     // ~10 us at 96 MHz after a write
) (
    input  logic       clk,
    input  logic       reset,

    // serial pins, sampled every clk
    input  logic       cs,
    input  logic       sclk,
    input  logic       di,
    output logic       dout,
    output logic       ready,

    // byte port: load / readback of the array
    input  logic       ld_we,
    input  logic [6:0] ld_addr,
    input  logic [7:0] ld_wdata,
    output logic [7:0] ld_q,

    output logic       dirty            // toggles on every array write
);
    logic [7:0] mem [128];

    typedef enum logic [2:0] {
        S_RESET, S_START, S_CMD, S_READ, S_WDATA, S_WAIT
    } state_t;
    state_t st;

    logic        cs_d, clk_d;
    logic  [9:0] cmdacc;          // the first 10 of the 11 command bits; the 11th arrives with di
    logic  [3:0] nbits;
    logic  [7:0] shreg;
    logic        do_bit;
    logic        locked;
    logic [15:0] busy;
    logic  [6:0] addr;

    wire cs_rise  = cs & ~cs_d;
    wire cs_fall  = ~cs & cs_d;
    wire clk_rise = sclk & ~clk_d;

    always_ff @(posedge clk) begin
        ld_q <= mem[ld_addr];
        if (ld_we) mem[ld_addr] <= ld_wdata;
    end

    assign dout  = (st == S_READ) ? do_bit : 1'b1;
    assign ready = (busy == 16'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_RESET; cs_d <= 1'b0; clk_d <= 1'b0; busy <= '0;
            locked <= 1'b1; do_bit <= 1'b1; nbits <= '0; dirty <= 1'b0;
        end else begin
            cs_d  <= cs;
            clk_d <= sclk;
            if (busy != 16'd0) busy <= busy - 16'd1;

            if (cs_fall) st <= S_RESET;
            else case (st)
                S_RESET: if (cs_rise) st <= S_START;

                // a 1 on DI at a rising clock is the start bit (edges that
                // coincide with CS rising are ignored, as MAME does)
                S_START: if (clk_rise && di && ready && !cs_rise) begin
                    cmdacc <= '0; nbits <= '0; st <= S_CMD;
                end

                S_CMD: if (clk_rise) begin
                    cmdacc <= {cmdacc[8:0], di};
                    nbits  <= nbits + 4'd1;
                    if (nbits == 4'd10) begin
                        // full 11 bits present after this shift
                        logic [10:0] c; c = {cmdacc, di};
                        addr <= c[6:0];
                        case (c[10:9])
                            2'd0: begin
                                case (c[8:7])
                                    2'd0: locked <= 1'b1;                      // LOCK
                                    2'd2: begin                                // ERASEALL
                                        if (!locked) begin
                                            for (int i = 0; i < 128; i++) mem[i] <= 8'hff;
                                            dirty <= ~dirty; busy <= 16'(BUSY_CLOCKS);
                                        end
                                    end
                                    2'd3: locked <= 1'b0;                      // UNLOCK
                                    default: ;
                                endcase
                                st <= S_WAIT;
                            end
                            2'd2: begin                                        // READ
                                shreg <= mem[c[6:0]]; do_bit <= 1'b0; nbits <= '0;
                                st <= S_READ;
                            end
                            default: begin                                     // WRITE (1 and 3)
                                shreg <= '0; nbits <= '0; st <= S_WDATA;
                            end
                        endcase
                    end
                end

                // MSB first; the first rising edge presents bit 7
                S_READ: if (clk_rise) begin
                    do_bit <= shreg[7];
                    shreg  <= {shreg[6:0], 1'b1};
                end

                S_WDATA: if (clk_rise) begin
                    shreg <= {shreg[6:0], di};
                    nbits <= nbits + 4'd1;
                    if (nbits == 4'd7) begin
                        if (!locked) begin
                            mem[addr] <= {shreg[6:0], di};
                            dirty <= ~dirty; busy <= 16'(BUSY_CLOCKS);
                        end
                        st <= S_WAIT;
                    end
                end

                S_WAIT: ;                                   // CS falling resets
                default: st <= S_RESET;
            endcase
        end
    end
endmodule

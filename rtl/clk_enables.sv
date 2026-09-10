//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/rtl-conventions.md).
//   cen_16m : 96 / 6   68000
//   cen_8m  : 96 / 12  Z80, and the pixel clock (512 clocks per 64 us line)
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic reset,
    output logic cen_16m,
    output logic cen_8m
);
    logic [3:0] div;
    always_ff @(posedge clk) begin
        if (reset) begin div <= '0; cen_16m <= 1'b0; cen_8m <= 1'b0; end
        else begin
            div     <= (div == 4'd11) ? 4'd0 : div + 4'd1;
            cen_16m <= (div == 4'd11) || (div == 4'd5);
            cen_8m  <= (div == 4'd11);
        end
    end
endmodule

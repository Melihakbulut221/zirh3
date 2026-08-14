// =============================================================================
// ZIRH - the loader's own UART receiver
// src/zirh_isp_rx.v
//
// The ISP path runs while the whole SoC - including its UART - is held
// in reset, so the loader needs a receiver of its own: 8N1, fixed
// divisor (the reset baud; there is no CPU yet to change it), majority
// nothing, TMR nothing. The transport is deliberately UNPROTECTED: a
// corrupted byte becomes a corrupted image, the loader's read-back CRC
// refuses it, and the chip falls back to the mask ROM. Protection lives
// at the verification boundary, not in the wire - the same philosophy
// as the QSPI path (PROGRAM.md A5), at one-tenth the area.
// =============================================================================

`default_nettype none

module zirh_isp_rx #(
    parameter integer DIV = 174           // clk cycles per bit
) (
    input  wire       clk,
    input  wire       rst_n,              // POR domain, like the loader
    input  wire       rx_i,
    output reg  [7:0] data_o,
    output reg        valid_o             // 1-cycle pulse per byte
);

    localparam integer CW = 8;            // enough for DIV up to 255

    // 2FF synchronizer - rx_i is a pad
    reg [1:0] sync_q;
    always @(posedge clk) begin
        if (!rst_n) sync_q <= 2'b11;
        else        sync_q <= {sync_q[0], rx_i};
    end
    wire rx = sync_q[1];

    localparam [1:0] R_IDLE = 2'd0, R_START = 2'd1, R_DATA = 2'd2,
                     R_STOP = 2'd3;

    reg [1:0]    st_q;
    reg [CW-1:0] cnt_q;
    reg [2:0]    bit_q;
    reg [7:0]    sh_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            st_q    <= R_IDLE;
            cnt_q   <= {CW{1'b0}};
            bit_q   <= 3'd0;
            sh_q    <= 8'h00;
            data_o  <= 8'h00;
            valid_o <= 1'b0;
        end else begin
            valid_o <= 1'b0;
            case (st_q)
                R_IDLE: if (!rx) begin
                    st_q  <= R_START;
                    cnt_q <= DIV[CW-1:0] / 2;
                end
                R_START: begin
                    if (cnt_q == 0) begin
                        if (!rx) begin       // still low mid-start: real
                            st_q  <= R_DATA;
                            cnt_q <= DIV[CW-1:0];
                            bit_q <= 3'd0;
                        end else
                            st_q <= R_IDLE;  // runt glitch: drop it
                    end else
                        cnt_q <= cnt_q - 1'b1;
                end
                R_DATA: begin
                    if (cnt_q == 0) begin
                        sh_q  <= {rx, sh_q[7:1]};
                        cnt_q <= DIV[CW-1:0];
                        if (bit_q == 3'd7) st_q <= R_STOP;
                        else               bit_q <= bit_q + 3'd1;
                    end else
                        cnt_q <= cnt_q - 1'b1;
                end
                R_STOP: begin
                    if (cnt_q == 0) begin
                        if (rx) begin        // good stop: deliver
                            data_o  <= sh_q;
                            valid_o <= 1'b1;
                        end                  // framing error: drop
                        st_q <= R_IDLE;
                    end else
                        cnt_q <= cnt_q - 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire

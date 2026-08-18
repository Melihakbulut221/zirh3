// Synthesis-integrity stub for the RM_IHPSG13 SRAM macro: the TMR
// check needs the module DEFINED so hierarchy resolves, and needs it
// OPAQUE so nothing inside is counted. The real model comes from the
// PDK in every simulation and hardening flow; this stub exists only
// for scripts/check_tmr.sh.
(* blackbox *)
module RM_IHPSG13_1P_1024x8_c2_bm_bist (
    input  wire       A_CLK, A_MEN, A_WEN, A_REN, A_DLY,
    input  wire [9:0] A_ADDR,
    input  wire [7:0] A_DIN, A_BM,
    output wire [7:0] A_DOUT,
    input  wire       A_BIST_CLK, A_BIST_EN, A_BIST_MEN, A_BIST_WEN,
    input  wire       A_BIST_REN,
    input  wire [9:0] A_BIST_ADDR,
    input  wire [7:0] A_BIST_DIN, A_BIST_BM
);
endmodule

(* blackbox *)
module RM_IHPSG13_1P_4096x8_c3_bm_bist (
    input A_CLK, input A_MEN, input A_WEN, input A_REN,
    input [11:0] A_ADDR, input [7:0] A_DIN, input A_DLY,
    output [7:0] A_DOUT, input [7:0] A_BM,
    input A_BIST_CLK, input A_BIST_EN, input A_BIST_MEN,
    input A_BIST_WEN, input A_BIST_REN, input [11:0] A_BIST_ADDR,
    input [7:0] A_BIST_DIN, input [7:0] A_BIST_BM
);
endmodule

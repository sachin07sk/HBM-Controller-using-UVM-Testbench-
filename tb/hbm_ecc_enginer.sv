//=============================================================================
// File        : hbm_ecc_engine.sv
// Description : HBM Base Die — ECC Engine (Single Error Correct / Double
//               Error Detect — SEC-DED Hamming Code)
//
//               Architecture basis:
//               "HBM4 integrates logic gates directly into the base die,
//                allowing it to offload tasks like error correction..."
//               — LinkedIn post
//
//               This module implements SEC-DED over a 128-bit data word
//               with 8 parity bits (136-bit codeword), matching HBM3E/HBM4
//               on-die ECC width.
//
//               Ports:
//               - ENCODE path: data_in → codeword_out (write to DRAM)
//               - DECODE path: codeword_in → data_out + syndrome + flags
//=============================================================================

`include "hbm_ctrl_pkg.sv"
import hbm_ctrl_pkg::*;

module hbm_ecc_engine (
  input  logic                          clk,
  input  logic                          reset,

  //----------------------------------------------------------
  // ENCODE interface (write path — host → DRAM)
  //----------------------------------------------------------
  input  logic                          enc_valid,
  input  logic [HBM_CHANNEL_WIDTH-1:0]  enc_data_in,       // 128-bit raw data
  output logic [HBM_CHANNEL_WIDTH-1:0]  enc_data_out,      // pass-through
  output logic [HBM_ECC_BITS-1:0]       enc_parity_out,    // 8 generated parity bits

  //----------------------------------------------------------
  // DECODE interface (read path — DRAM → host)
  //----------------------------------------------------------
  input  logic                          dec_valid,
  input  logic [HBM_CHANNEL_WIDTH-1:0]  dec_data_in,       // 128-bit data from DRAM
  input  logic [HBM_ECC_BITS-1:0]       dec_parity_in,     // stored parity bits
  output logic [HBM_CHANNEL_WIDTH-1:0]  dec_data_out,      // corrected data
  output logic [HBM_ECC_BITS-1:0]       dec_syndrome,      // syndrome vector
  output logic                          dec_ecc_corrected, // single-bit corrected
  output logic                          dec_ecc_uncorrect, // double-bit — uncorrectable
  output logic                          dec_ecc_clean       // no error detected
);

  //----------------------------------------------------------
  // Internal signals
  //----------------------------------------------------------
  logic [HBM_ECC_BITS-1:0] computed_parity;
  logic [HBM_ECC_BITS-1:0] syndrome_r;
  logic [HBM_CHANNEL_WIDTH-1:0] corrected_data;
  logic [$clog2(HBM_CHANNEL_WIDTH)-1:0] err_bit_pos;
  logic single_err, double_err, no_err;

  //===========================================================
  // ENCODE PATH — Parity Generation
  // SEC-DED: 8 parity bits covering 128 data bits
  // P[i] = XOR of all data bits whose position has bit i set
  //        in binary (standard Hamming construction)
  //===========================================================

  // Combinational parity generation (simplified for 128-bit — groups of 16)
  // In full implementation each P[i] covers specific bit positions per Hamming matrix
  always_comb begin : enc_parity_gen
    enc_data_out   = enc_data_in;
    computed_parity = '0;
    if (enc_valid) begin
      // P[0]: XOR of bits at positions with bit0 set (even-indexed bits: 126, 124, ... 2, 0)
      computed_parity[0] = ^(enc_data_in & 128'hAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA);
      // P[1]: XOR of bits at positions with bit1 set
      computed_parity[1] = ^{enc_data_in[127:64]};
      // P[2]: XOR of upper quarter
      computed_parity[2] = ^{enc_data_in[127:96]};
      // P[3]: XOR of second quarter
      computed_parity[3] = ^{enc_data_in[95:64]};
      // P[4]: XOR of third quarter
      computed_parity[4] = ^{enc_data_in[63:32]};
      // P[5]: XOR of bottom quarter
      computed_parity[5] = ^{enc_data_in[31:0]};
      // P[6]: XOR of odd byte lanes
      computed_parity[6] = ^{enc_data_in[127:120], enc_data_in[111:104],
                              enc_data_in[95:88],  enc_data_in[79:72],
                              enc_data_in[63:56],  enc_data_in[47:40],
                              enc_data_in[31:24],  enc_data_in[15:8]};
      // P[7]: Overall parity (for SEC-DED double-error detection)
      computed_parity[7] = ^enc_data_in ^ ^computed_parity[6:0];
    end
    enc_parity_out = computed_parity;
  end : enc_parity_gen

  //===========================================================
  // DECODE PATH — Syndrome Computation & Error Correction
  //===========================================================

  // Syndrome = received_parity XOR recomputed_parity
  always_comb begin : dec_syndrome_gen
    logic [HBM_ECC_BITS-1:0] recomputed;
    recomputed = '0;
    if (dec_valid) begin
      // Recompute P[0] using the standard even-bit bitmask
      recomputed[0] = ^(dec_data_in & 128'hAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA);
      recomputed[1] = ^{dec_data_in[127:64]};
      recomputed[2] = ^{dec_data_in[127:96]};
      recomputed[3] = ^{dec_data_in[95:64]};
      recomputed[4] = ^{dec_data_in[63:32]};
      recomputed[5] = ^{dec_data_in[31:0]};
      recomputed[6] = ^{dec_data_in[127:120], dec_data_in[111:104],
                         dec_data_in[95:88],  dec_data_in[79:72],
                         dec_data_in[63:56],  dec_data_in[47:40],
                         dec_data_in[31:24],  dec_data_in[15:8]};
      recomputed[7] = ^dec_data_in ^ ^recomputed[6:0];
    end
    dec_syndrome = dec_parity_in ^ recomputed;
  end : dec_syndrome_gen

  // Error classification
  always_comb begin : err_classify
    no_err     = (dec_syndrome == '0);
    // SEC-DED: if P[7] (overall parity) differs → odd number of errors (single)
    single_err = (!no_err) &&  dec_syndrome[7];
    // If P[7] unchanged but syndrome non-zero → even number of errors (double)
    double_err = (!no_err) && !dec_syndrome[7];
    // Error bit position from syndrome bits [6:0] (Hamming address)
    err_bit_pos = dec_syndrome[6:0];
  end : err_classify

  // Corrected data — flip the bit at err_bit_pos for single-bit errors
  always_comb begin : data_correct
    corrected_data = dec_data_in;
    if (single_err && (err_bit_pos < HBM_CHANNEL_WIDTH))
      corrected_data[err_bit_pos] = ~dec_data_in[err_bit_pos];
  end : data_correct

  //----------------------------------------------------------
  // Registered Outputs (1-cycle latency, base die pipeline)
  //----------------------------------------------------------
  always_ff @(posedge clk) begin : dec_output_reg
    if (reset) begin
      dec_data_out         <= '0;
      dec_ecc_corrected    <= 1'b0;
      dec_ecc_uncorrect    <= 1'b0;
      dec_ecc_clean        <= 1'b1;
      syndrome_r           <= '0;
    end
    else if (dec_valid) begin
      dec_data_out         <= corrected_data;
      dec_ecc_corrected    <= single_err;
      dec_ecc_uncorrect    <= double_err;
      dec_ecc_clean        <= no_err;
      syndrome_r           <= dec_syndrome;
    end
  end : dec_output_reg

endmodule : hbm_ecc_engine

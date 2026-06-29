//==============================================================================
// accel_pkg.sv  --  Global parameters and types for the zero-shot detection
//                   accelerator (YOLO26n conv engine) on XC7K325T / Genesys 2.
//
// MAC-tile datapath: IC_LANES (reduction) x OC_LANES (parallel outputs).
//   512 INT8 MACs -> 256 DSP48E1 with 2-MAC/DSP packing (~30% of 840).
//==============================================================================
`ifndef ACCEL_PKG_SV
`define ACCEL_PKG_SV

package accel_pkg;

  //---------------------------------------------------------------------------
  // Datapath geometry
  //---------------------------------------------------------------------------
  localparam int ACT_W     = 8;    // INT8 activations
  localparam int WGT_W     = 8;    // INT8 weights
  localparam int ACC_W     = 32;   // INT32 accumulation
  localparam int IC_LANES  = 16;   // reduction lanes per cycle (input channels)
  localparam int OC_LANES  = 32;   // parallel output channels (tile width)

  //---------------------------------------------------------------------------
  // AXI parameters
  //---------------------------------------------------------------------------
  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 128;            // 16 B/beat master data bus
  localparam int AXI_STRB_W = AXI_DATA_W/8;
  localparam int AXI_ID_W   = 4;
  localparam int AXIL_ADDR_W = 8;             // 256-byte AXI4-Lite reg aperture
  localparam int AXIL_DATA_W = 32;

  //---------------------------------------------------------------------------
  // Activation select
  //---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ACT_NONE = 2'd0,
    ACT_RELU = 2'd1,
    ACT_SILU = 2'd2
  } act_e;

  //---------------------------------------------------------------------------
  // Layer descriptor (mirrors DDR descriptor record, see docs §8/§9b).
  // Conv is lowered to GEMM by the host: M = OH*OW (spatial), N = OC,
  // K = IC*KH*KW (im2col depth). The DMA gathers im2col rows using the
  // strided address fields below; the MAC-tile sees a plain GEMM.
  //---------------------------------------------------------------------------
  // Exactly 512 bits = DESC_BYTES (64) so the DMA reads it in 4 x 128-bit beats.
  // Packed struct is MSB-first: wt_addr occupies bits [511:480]. The host
  // serializer must match this ordering (see docs/architecture.md §8a).
  typedef struct packed {
    logic [31:0] wt_addr;      // DDR base of weights for this layer (INT8, OC x K)
    logic [31:0] in_addr;      // DDR base of input feature map / im2col source
    logic [31:0] out_addr;     // DDR base of output feature map
    logic [31:0] bias_addr;    // DDR base of bias (INT32)
    logic [31:0] M;            // GEMM rows  (OH*OW)
    logic [31:0] N;            // GEMM cols  (OC)
    logic [31:0] K;            // GEMM depth (IC*KH*KW)
    logic [31:0] in_row_stride;  // byte stride between im2col rows in DDR
    logic [15:0] requant_shift;  // arithmetic right shift after scale
    logic [15:0] requant_mult;   // fixed-point multiplier (per-tensor)
    logic [1:0]  act_type;       // act_e
    logic        is_last;        // last layer -> feed decode helper
    logic [220:0] rsvd;          // pad to 512 bits
  } layer_desc_t;

  localparam int DESC_BYTES = 64;   // descriptor stride in DDR (64-B aligned)

endpackage : accel_pkg

`endif

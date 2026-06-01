//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - H&V counter (synchronous rework of dkong3_hv_count)
//
// Single clock `clk` (98.304 MHz) + clock-enable `cen_24m_p` (24.576 MHz).
// The original ran a counter on posedge I_CLK (24.576) and then used its LSB
// `O_CLK` (12.288) and the decoded `V_CLK` as *clocks* for the H_BLANK / V_CLK
// and V-counter logic. Here those ripple clocks become decoded enables in the
// one clk domain. Behavior is bit-identical to the original (verified by
// tb/diff/hv_count_diff_tb.sv). See docs/clock-rework/ANALYSIS.md.
//----------------------------------------------------------------------------

module dkong3_hv_count_sync
(
   input        clk,        // 98.304 MHz master
   input        cen_24m_p,  // 24.576 MHz enable (was posedge I_CLK)
   input        I_RST_n,
   input        I_VFLIP,
   input   [8:0]H_OFFSET,
   input   [8:0]V_OFFSET,

   output       O_CLK,      // = H_CNT_r[0] (now a data signal, was 12.288 clock)
   output  [9:0]H_CNT,
   output  [7:0]V_CNT,
   output  [7:0]VF_CNT,
   output       H_BLANKn,
   output       V_BLANKn,
   output       C_BLANKn,
   output       H_SYNCn,
   output       V_SYNCn,

   // Decoded strobes for synchronous downstream consumers (replace O_CLK as a
   // clock). cen_o_clk_p = posedge O_CLK (12.288 rising), _n = negedge.
   output       cen_o_clk_p,
   output       cen_o_clk_n,

   // Posedge strobes for the H_CNT bits used as clocks downstream (vram/obj).
   // H_CNT[k] = H_CNT_r[k+1]; a bit only rolls 0->1 when all lower bits are 1
   // (so bit0=1 -> the event always coincides with cen_o_clk_n, the H_CNT update).
   output       cen_hcnt0_p,   // posedge H_CNT[0] (6.144 MHz, was CLK_4PN)
   output       cen_hcnt2_p,   // posedge H_CNT[2] (was vram VRAMBUSY clock)
   output       cen_hcnt6_p,   // posedge H_CNT[6] (was vram ESBLK clock)
   output       cen_hcnt9_n    // negedge H_CNT[9] (was vram VRAMBUSY/ESBLK async clear)
);

parameter H_count = 1536;
parameter H_BL_P  = 513;
parameter H_BL_W  = 0;
parameter V_CL_P  = 575;
parameter V_CL_W  = 639;
parameter V_BL_P  = 239;
parameter V_BL_W  = 15;

// ---- horizontal counter (was posedge I_CLK 24.576) -------------------------
reg  [10:0]H_CNT_r = 0;
wire [10:0]H_CNT_next = (H_CNT_r == H_count-1'b1) ? 11'b0 : H_CNT_r + 1'b1;

assign H_CNT[9:0] = H_CNT_r[10:1];
assign O_CLK      = H_CNT_r[0];

// O_CLK edges happen on 24.576 ticks: posedge when bit0 0->1, negedge 1->0.
// bit0==0 (even) never wraps (wrap is from 1535, odd), so next bit0 = 1 there.
assign cen_o_clk_p = cen_24m_p & ~H_CNT_r[0];
assign cen_o_clk_n = cen_24m_p &  H_CNT_r[0];

// H_CNT[k]=H_CNT_r[k+1] rolls 0->1 only when carrying out of all lower bits,
// which requires H_CNT_r[0]==1 -> coincides with cen_o_clk_n (the H_CNT update).
assign cen_hcnt0_p = cen_o_clk_n & ~H_CNT_r[1] & H_CNT_next[1];
assign cen_hcnt2_p = cen_o_clk_n & ~H_CNT_r[3] & H_CNT_next[3];
assign cen_hcnt6_p = cen_o_clk_n & ~H_CNT_r[7] & H_CNT_next[7];

// negedge H_CNT[9] (= H_CNT_r[10] 1->0): happens on the H counter wrap
// (1535 -> 0). Used by vram's VRAMBUSY/ESBLK async-clear path.
assign cen_hcnt9_n = cen_24m_p & H_CNT_r[10] & ~H_CNT_next[10];

always@(posedge clk) if (cen_24m_p)
   H_CNT_r <= H_CNT_next;

// ---- H_BLANK / V_CLK (was posedge O_CLK 12.288) ----------------------------
// At the original posedge O_CLK, the case sampled H_CNT *after* H_CNT_r updated
// to the new (odd) value -> use H_CNT_next[10:1]. Same single case as original.
reg  V_CLK   = 1'b0;
reg  H_BLANK = 1'b0;

always@(posedge clk) if (cen_o_clk_p) begin
   case(H_CNT_next[10:1])
      H_BL_P:                H_BLANK <= 1'b1;
      H_BL_W:                H_BLANK <= 1'b0;
      (V_CL_P + H_OFFSET*2): V_CLK   <= 1'b1;
      (V_CL_W + H_OFFSET*2): V_CLK   <= 1'b0;
      default:;
   endcase
end

assign H_SYNCn  = ~V_CLK;
assign H_BLANKn = ~H_BLANK;

// ---- vertical counter / blank (was posedge V_CLK + async reset) ------------
// posedge V_CLK = the cen_o_clk_p tick where V_CLK is set (0->1).
wire vclk_rise = cen_o_clk_p & (H_CNT_next[10:1] == (V_CL_P + H_OFFSET*2)) & ~V_CLK;

reg  [8:0]V_CNT_r;
reg  V_BLANK;

always@(posedge clk) begin
   if(I_RST_n == 1'b0) begin
      V_CNT_r <= 9'd0;
      V_BLANK <= 1'b0;
   end else if (vclk_rise) begin
      V_CNT_r <= (V_CNT_r == 255) ? 9'd504 : V_CNT_r + 1'b1;
      case(V_CNT_r[8:0])               // V_BLANK uses the pre-increment V_CNT_r
         V_BL_P: V_BLANK <= 1'b1;
         V_BL_W: V_BLANK <= 1'b0;
         default:;
      endcase
   end
end

assign V_CNT[7:0]  = V_CNT_r[7:0];
assign V_SYNCn     = (V_CNT_r > 255 - V_OFFSET) ^ (V_CNT_r < 9'd511 - V_OFFSET);
assign V_BLANKn    = ~V_BLANK;
assign C_BLANKn    = ~(H_BLANK | V_BLANK);
assign VF_CNT[7:0] = V_CNT ^ {8{I_VFLIP}};

endmodule

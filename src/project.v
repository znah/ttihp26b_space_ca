/*
 * Copyright (c) 2026 Alexander Mordvintsev
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

/*
 * 1D radius-2 cellular automaton (160 cells, toroidal) rendered as 4x4 px
 * cells: every 4 scanlines is one generation, 120 generations per frame.
 *
 * Per-cell timing (fract_x = pix_x[1:0]) on a generation line (fract_y == 0):
 *   0: shift cells[cell_x+2] (old value) into the 5-cell window
 *   1: register write enables
 *   2: write new_cell -> cells[cell_x]      (latch enable high)
 *   3: enables low, cell_x still stable     (hold margin)
 * The window runs ahead of the write pointer, so it always sees the old
 * generation. During hblank the window is preloaded with cells 158,159,0,1,2
 * and cells 0/1 are saved for the right-edge wraparound.
 */
module tt_um_vga_ca(
  input  wire [7:0] ui_in,
  output wire [7:0] uo_out,
  input  wire [7:0] uio_in,
  output wire [7:0] uio_out,
  output wire [7:0] uio_oe,
  input  wire       ena,
  input  wire       clk,
  input  wire       rst_n
);

  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;
  wire _unused_ok = &{ena, ui_in[7:2], uio_in};

  wire hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;

  hvsync_generator hvsync_gen(
    .clk(clk),
    .reset(~rst_n),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(video_active),
    .hpos(pix_x),
    .vpos(pix_y)
  );

  // Geometry: GRID_W cells of CELL_SIZE px exactly fill the 640 px line.
  localparam       CELL_SIZE = 4;
  localparam       GRID_W    = 160;
  localparam [7:0] CELL_M2   = GRID_W - 2;
  localparam [7:0] CELL_M1   = GRID_W - 1;
  localparam [9:0] WIDTH     = 640;
  localparam [9:0] HEIGHT    = 480;
  localparam [9:0] PRELOAD_X = 795;          // last 5 cycles of hblank (H_MAX = 799)

  localparam [31:0] RULE     = 32'h6C1E53A8;

  wire [7:0] cell_x  = pix_x[9:2];
  wire [1:0] fract_x = pix_x[1:0];
  wire [1:0] fract_y = pix_y[1:0];

  // Controls
  wire advance_mode   = ui_in[0];            // 0: scroll 1 gen/frame, 1: 120 gens/frame
  wire inject_gliders = ui_in[1];

  // Frame state
  reg       first_frame;
  reg [6:0] frame_cnt;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      first_frame <= 1'b1;
      frame_cnt   <= 7'd0;
    end else if (pix_x == WIDTH && pix_y == HEIGHT) begin
      first_frame <= 1'b0;
      frame_cnt   <= frame_cnt + 7'd1;
    end
  end

  // Memory read ports
  wire cells_dout;                           // current row (updated in place)
  wire next_top_dout;                        // gen+1 of this frame = row 0 of next frame

  reg [7:0] cells_raddr;
  always @(*) begin
    case (pix_x)
      PRELOAD_X:         cells_raddr = CELL_M2;
      PRELOAD_X + 10'd1: cells_raddr = CELL_M1;
      PRELOAD_X + 10'd2: cells_raddr = 8'd0;
      PRELOAD_X + 10'd3: cells_raddr = 8'd1;
      PRELOAD_X + 10'd4: cells_raddr = 8'd2;
      default:           cells_raddr = cell_x + 8'd2;
    endcase
  end

  // Toroidal 5-neighborhood sliding window
  reg wrap_cell0, wrap_cell1;                // old cells 0/1, needed at the right edge
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wrap_cell0 <= 1'b0;
      wrap_cell1 <= 1'b0;
    end else begin
      if (pix_x == PRELOAD_X + 10'd2) wrap_cell0 <= cells_dout;
      if (pix_x == PRELOAD_X + 10'd3) wrap_cell1 <= cells_dout;
    end
  end

  wire preload_step = (pix_x >= PRELOAD_X) && (pix_x <= PRELOAD_X + 10'd4);
  wire no_data_yet  = first_frame && pix_y == 0;   // memories are uninitialized
  wire shift_window = preload_step ||
                      (video_active && fract_x == 2'd0 && cell_x != 8'd0 && !no_data_yet);

  wire next_window_bit = (cell_x == CELL_M2) ? wrap_cell0 :
                         (cell_x == CELL_M1) ? wrap_cell1 : cells_dout;

  reg [4:0] window;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      window <= 5'b0;
    end else if (shift_window) begin
      window <= {window[3:0], next_window_bit};
    end
  end

  // CA rule and cell evaluation
  wire top_row_active = (pix_y == 0) && (!advance_mode || first_frame);
  wire seed_row       = cell_x[2] ^ cell_x[5] ^ cell_x[7] ^ (cell_x[2] & cell_x[7]) ^ (cell_x[3] & cell_x[6]);
  wire gliders_row    = cell_x[7:2] == 6'd20;      // cells 80..83
  wire top_row_val    = first_frame ? seed_row : (next_top_dout | (inject_gliders & gliders_row));
  wire rule_cell      = (fract_y == 2'd0) ? RULE[window] : window[2];
  wire new_cell       = top_row_active ? top_row_val : rule_cell;

  // Latch write enables: decoded one cycle early (fract_x == 1) and registered,
  // so they are glitch-free and high only during fract_x == 2.
  wire write_slot_next = video_active && fract_x == 2'd1;
  reg  cells_we, next_top_we;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cells_we    <= 1'b0;
      next_top_we <= 1'b0;
    end else begin
      cells_we    <= write_slot_next && fract_y == 2'd0;
      next_top_we <= write_slot_next && pix_y == CELL_SIZE;
    end
  end

  // Memory banks. Each bank uses one address for both read and write, so its
  // decoder is shared between the write enables and the read mux.
  // cells: read-ahead address at fract_x == 0 / preload, write address otherwise.
  wire [7:0] cells_addr = (video_active && fract_x != 2'd0) ? cell_x : cells_raddr;
  latch_mem #(.WIDTH(GRID_W)) cells (
    .we  (cells_we),
    .addr(cells_addr),
    .in  (new_cell),
    .q   (cells_dout)
  );

  // next_top is written at pix_y == CELL_SIZE, where new_cell == rule_cell;
  // feeding rule_cell directly avoids a structural loop through the latch.
  latch_mem #(.WIDTH(GRID_W)) next_top (
    .we  (next_top_we),
    .addr(cell_x),
    .in  (rule_cell),
    .q   (next_top_dout)
  );

  wire [1:0] star_brightness;
  starfield sf(pix_x, pix_y[8:0], frame_cnt, star_brightness);

  // Video output
  wire [4:0] win   = no_data_yet ? 5'b0 : window;
  wire [5:0] color = !video_active ? 6'b0 : (new_cell ? {1'b1, win} : {3{star_brightness}});
  wire [1:0] R = color[5:4];
  wire [1:0] G = color[3:2];
  wire [1:0] B = color[1:0];

  assign uo_out = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
endmodule

module starfield (
    input  wire [9:0] x,
    input  wire [8:0] y,
    input  wire [6:0] frame_cnt,
    output wire [1:0] brightness
);
    wire [12:0] c  = {y[8:3], x[9:3]};             // 8×8 cell index
    wire [12:0] h1 = (c  + (c  << 1)) ^ (c  >> 3);
    wire [12:0] h2 = (h1 + (h1 << 5)) ^ (h1 >> 4);
    wire [12:0] h  = (h2 + (h2 << 2)) ^ (h2 >> 3);

    wire [2:0] m = {2'b11, |h[4:3]};               // big stars: 2×2
    wire pix = ~|h[12:11]
             & ~|((x[2:0] ^ h[7:5])  & m)
             & ~|((y[2:0] ^ h[10:8]) & m);

    wire [5:0] speed = (h[2:1] == 2'b00) ? {frame_cnt[4:0], 1'b0} :
                       (h[2:1] == 2'b01) ? frame_cnt[6:1] : frame_cnt[5:0];
    wire [5:0] phase = speed + {h[4:0], h[7]};
    wire [1:0] star_b = phase[4:3] ^ {2{phase[5]}};
    wire _unused_star = &{phase[2:0]};

    assign brightness = pix ? star_b : 2'b00;
endmodule

/*
 * 1-bit x WIDTH latch memory with a single shared read/write address.
 * The write enable must be glitch-free, with addr and in stable while it is high.
 */
module latch_mem #(
  parameter WIDTH = 160
)(
  input  wire       we,
  input  wire [7:0] addr,
  input  wire       in,
  output wire       q
);

`ifndef SYNTHESIS
  // Fast word-based array for high simulation FPS (VGA playground / Verilator / Icarus).
  // Words are kept <= 64 bits for the wasm Verilator build.
  localparam NUM_WORDS = (WIDTH + 31) / 32;
  reg [31:0] mem [0:NUM_WORDS-1];
  integer j;
  initial begin
    for (j = 0; j < NUM_WORDS; j = j + 1) begin
      mem[j] = 32'b0;
    end
  end

  /* verilator lint_off LATCH */
  always @(*) begin
    if (we) mem[addr[7:5]][addr[4:0]] = in;
  end
  /* verilator lint_on LATCH */

  assign q = mem[addr[7:5]][addr[4:0]];
`else
  // Portable behavioral latches for synthesis: infers active-high $_DLATCH_P_
  // (maps to standard cell dlhq_1)
  reg [WIDTH-1:0] mem;

  genvar i;
  generate
    /* verilator lint_off LATCH */
    for (i = 0; i < WIDTH; i = i + 1) begin : gen_latch
      always @(*) begin
        if (we && (addr == i)) mem[i] = in;
      end
    end
    /* verilator lint_on LATCH */
  endgenerate

  assign q = mem[addr];
`endif
endmodule

/*
 * Copyright (c) 2026 Alexander Mordvintsev
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

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

  wire hsync, vsync, video_active;
  wire [9:0] pix_x, pix_y;

  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;
  wire _unused_ok = &{ena, ui_in[7:2], uio_in};

  hvsync_generator hvsync_gen(
    .clk(clk),
    .reset(~rst_n),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(video_active),
    .hpos(pix_x),
    .vpos(pix_y)
  );

  // Timing & Geometry
  parameter logCELL_SIZE = 2;
  parameter CELL_SIZE    = 1 << logCELL_SIZE;
  parameter WIDTH        = 640;
  parameter HEIGHT       = 480;
  parameter GRID_W       = 160;
  parameter PAD_LEFT     = (WIDTH - GRID_W * CELL_SIZE) / 2;
  parameter PRE_X        = (PAD_LEFT == 0) ? 10'd800 : 10'(PAD_LEFT);

  wire [9:0] x = pix_x - PAD_LEFT;
  wire [7:0] cell_x = x[9:logCELL_SIZE];
  wire [logCELL_SIZE-1:0] fract_x = x[logCELL_SIZE-1:0];
  wire [logCELL_SIZE-1:0] fract_y = pix_y[logCELL_SIZE-1:0];

  wire in_grid   = (cell_x < GRID_W) && video_active;
  wire cell_tick = in_grid && (fract_x == 2'd2);

  // Toroidal 5-neighborhood sliding window
  wire cells_dout;
  wire first_row_dout;

  reg [4:0] window;
  wire [7:0] next_cell_idx = cell_x + 8'd2;

  reg [7:0] cells_raddr;
  always @(*) begin
    case (pix_x)
      PRE_X - 10'd5: cells_raddr = 8'(GRID_W - 2);
      PRE_X - 10'd4: cells_raddr = 8'(GRID_W - 1);
      PRE_X - 10'd3: cells_raddr = 8'd0;
      PRE_X - 10'd2: cells_raddr = 8'd1;
      PRE_X - 10'd1: cells_raddr = 8'd2;
      default:       cells_raddr = next_cell_idx;
    endcase
  end

  reg saved_cell0, saved_cell1;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      saved_cell0 <= 1'b0;
      saved_cell1 <= 1'b0;
    end else begin
      if (pix_x == PRE_X - 10'd3) saved_cell0 <= cells_dout;
      if (pix_x == PRE_X - 10'd2) saved_cell1 <= cells_dout;
    end
  end

  reg first_frame;
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

  wire preload_step = (pix_x >= PRE_X - 10'd5) && (pix_x <= PRE_X - 10'd1);
  wire shift_window = preload_step || (in_grid && fract_x == 0 && cell_x != 0 && !(first_frame && pix_y == 0));

  reg next_window_bit;
  always @(*) begin
    if (cell_x == 8'(GRID_W - 2)) begin
      next_window_bit = saved_cell0;
    end else if (cell_x == 8'(GRID_W - 1)) begin
      next_window_bit = saved_cell1;
    end else begin
      next_window_bit = cells_dout;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      window <= 5'b0;
    end else if (shift_window) begin
      window <= {window[3:0], next_window_bit};
    end
  end

  // CA Rule and Cell Evaluation
  parameter [31:0] RULE       = 32'h6C1E53A8;

  wire fast_mode          = ui_in[0];
  wire inject_gliders     = ui_in[1];
  wire seed_row           = cell_x[2] ^ cell_x[5] ^ cell_x[7] ^ (cell_x[2] & cell_x[7]) ^ (cell_x[3] & cell_x[6]);
  wire gliders_row        = cell_x >= 80 & cell_x <= 83;
  wire first_row_cell_val = first_frame ? seed_row : first_row_dout | (inject_gliders & gliders_row);
  wire rule_cell          = (fract_y == 0) ? RULE[window] : window[2];
  /* verilator lint_off UNOPTFLAT */
  wire new_cell           = (pix_y==0 && (!fast_mode || first_frame)) ? first_row_cell_val : rule_cell;
  /* verilator lint_on UNOPTFLAT */

  // Memory Banks
  wire cells_we = cell_tick && (fract_y == 0 || pix_y == 0);
  latch_mem #(.WIDTH(GRID_W)) cells (
    .we   (cells_we),
    .waddr(cell_x),
    .in   (new_cell),
    .raddr(cells_raddr),
    .q    (cells_dout)
  );

  wire first_row_we = cell_tick && (pix_y == CELL_SIZE);
  latch_mem #(.WIDTH(GRID_W)) first_row_cells (
    .we   (first_row_we),
    .waddr(cell_x),
    .in   (new_cell),
    .raddr(cell_x),
    .q    (first_row_dout)
  );

  wire [1:0] star_brightness;
  starfield sf(pix_x, pix_y[8:0], frame_cnt, star_brightness);
  wire [5:0] bg_color = in_grid ? {3{star_brightness}} : 6'b0;

  // Video Output
  wire c = new_cell & in_grid;
  wire [4:0] win = (first_frame && pix_y == 0) ? 5'b0 : window;
  wire [5:0] color = c ? {1'b1, win} : bg_color;
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

    assign brightness = pix ? star_b : 2'b00;
endmodule

module latch_mem #(
  parameter WIDTH = 160
)(
  input  wire       we,
  input  wire [7:0] waddr,
  input  wire       in,
  input  wire [7:0] raddr,
  output wire       q
);
  localparam NUM_WORDS = WIDTH / 32;

  reg [31:0] mem [0:NUM_WORDS-1];
  integer j;
  initial begin
    for (j = 0; j < NUM_WORDS; j = j + 1) begin
      mem[j] = 32'b0;
    end
  end

  /* verilator lint_off LATCH */
  always @(*) begin
    if (we) begin
      mem[waddr[7:5]][waddr[4:0]] = in;
    end
  end
  /* verilator lint_on LATCH */
  assign q = mem[raddr[7:5]][raddr[4:0]];
endmodule

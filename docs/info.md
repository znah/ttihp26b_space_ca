<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

![Space CA VGA Output](vga.png)

**Space CA** is a real-time hardware VGA demo ("Giant Computer in Space") that simulates and visualizes a 1D cellular automaton evolving over time against a procedural background starfield.

- **Interactive Online Demo**: Run it live directly in your browser on **[VGA Playground](https://vga-playground.com/?repo=https://github.com/znah/ttihp26b_space_ca)**!
- **VGA Generator**: Generates standard 640×480 @ 60 Hz timing from a 25.175 MHz pixel clock with clean asynchronous reset.
- **Cellular Automaton**:
  - Grid width: 160 cells across the screen (`GRID_W = 160`), rendered as 4×4 pixel blocks (`CELL_SIZE = 4`).
  - Rule: 5-neighborhood elementary cellular automaton (`RULE = 32'h6C1E53A8`) with toroidal boundary wrapping.
  - Evolution: Rows are computed line-by-line as the beam scans downwards, showing space horizontally and time vertically (120 generations per frame).
- **Coloring & Effects**:
  - Active cells are colored using their 5-cell neighborhood window state (`{1'b1, window}`) mapped to 6-bit color (R2G2B2).
  - Procedural background starfield synthesized using integer hashing hardware (`starfield` module) with twinkling brightness cycles.
- **Memory**:
  - Uses portable behavioral latch inference (`latch_mem`) under standard `` `ifndef SYNTHESIS ``:
    - **Simulation (VGA Playground / Verilator / Icarus):** High-speed word-based array for maximum simulation FPS.
    - **Synthesis (Yosys / LibreLane):** Portable active-high `$_DLATCH_P_` latches (mapping directly to `sg13g2_dlhq_1` in IHP 130nm) without consuming flip-flop area or tie-high cells.
  - Two latch banks maintain the 160-bit state between scanlines (`cells`) and frame boundaries (`first_row_cells`).
- **Interactive Controls**:
  - `ui_in[0]` (`advance_mode`): Toggles between smooth 1-row vertical scrolling and jumping by a full frame.
  - `ui_in[1]` (`inject_gliders`): Injects gliders into cells 80..83 of row 0.

## How to test

1. Connect a standard Tiny Tapeout digital VGA PMOD to the output pins (`uo_out`).
2. Provide a 25.175 MHz clock to `clk`.
3. Set `ena = 1` and release reset by setting `rst_n = 1`.
4. Connect to a VGA display (640×480 @ 60 Hz).
5. Use input switches to interact:
   - `ui_in[0]`: Toggle advance mode (0 = scroll 1 row/frame, 1 = full frame jump).
   - `ui_in[1]`: Toggle glider injection.

## External hardware

- Tiny Tapeout VGA PMOD (2 bits per color channel R2G2B2 + HSync + VSync)
- VGA monitor supporting 640×480 @ 60 Hz

# SPDX-FileCopyrightText: © 2026 Alexander Mordvintsev
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly


async def init_and_reset(dut):
    """Start 25.175 MHz clock (~40 ns period) and perform initial reset."""
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_reset_and_bidi(dut):
    """Verify clean reset and bidirectional pin configuration."""
    await init_and_reset(dut)
    await ReadOnly()

    assert dut.uio_out.value == 0, f"Expected uio_out=0, got {dut.uio_out.value}"
    assert dut.uio_oe.value == 0, f"Expected uio_oe=0, got {dut.uio_oe.value}"
    assert dut.uo_out[7].value == 0, "hsync not low after reset"
    assert dut.uo_out[3].value == 0, "vsync not low after reset"


@cocotb.test()
async def test_hsync_and_video(dut):
    """Verify horizontal timing (800 cycles) and non-zero video output."""
    await init_and_reset(dut)

    # 1. Active video area (first 640 cycles): hsync should remain low (bit 7)
    for _ in range(640):
        await ClockCycles(dut.clk, 1)
        await ReadOnly()
        assert dut.uo_out[7].value == 0, "hsync pulsed early in active area"

    # 2. Advance through front porch (16 cycles) to hsync pulse
    await ClockCycles(dut.clk, 16 + 2)
    await ReadOnly()
    assert dut.uo_out[7].value == 1, "hsync should be active high"

    # 3. Advance across sync pulse (96 cycles)
    await ClockCycles(dut.clk, 96)
    await ReadOnly()
    assert dut.uo_out[7].value == 0, "hsync should deassert after 96 cycles"

    # 4. Check that CA + starfield produce active RGB colors in scanline 1
    found_rgb = False
    for _ in range(640):
        await ClockCycles(dut.clk, 1)
        await ReadOnly()
        # In scanline 1, color bits are fully initialized (non-X)
        rgb = [dut.uo_out[i].value for i in [6, 5, 4, 2, 1, 0]]
        if any(v == 1 for v in rgb):
            found_rgb = True
            break
    assert found_rgb, "Active video scanline produced all black (no CA/stars output)"


@cocotb.test()
async def test_controls(dut):
    """Verify toggling ui_in controls produces valid resolvable outputs."""
    await init_and_reset(dut)
    # Complete initial scanline so memory latches are populated
    await ClockCycles(dut.clk, 800)

    for ui_val in [0x01, 0x02, 0x03, 0x00]:
        await ClockCycles(dut.clk, 1)
        dut.ui_in.value = ui_val
        await ClockCycles(dut.clk, 20)
        await ReadOnly()
        assert dut.uo_out.value.is_resolvable, f"X/Z detected with ui_in={ui_val:#x}"

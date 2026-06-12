"""CRC32 enforce test for weight_boot_loader.

Corrupts one byte in the payload (so the CRC of the bytes streamed to DDR no
longer matches the manifest CRC32) and verifies that the loader raises
`crc_error` and ends in the ERROR state instead of DONE.
"""
import json
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from coverage.functional_coverage import cover


PROJECT_ROOT = Path(__file__).resolve().parents[3]
IMAGE = PROJECT_ROOT / "artifacts/weights/biomed_weights.bin"
MANIFEST = PROJECT_ROOT / "artifacts/weights/biomed_weights_manifest.json"


async def _reset(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.flash_data.value = 0
    dut.flash_valid.value = 0
    dut.ddr_cmd_ready.value = 1
    dut.ddr_wr_data_rdy.value = 1
    for _ in range(5):
        await RisingEdge(dut.sys_clk)
    dut.rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.sys_clk)


@cocotb.test()
async def test_weight_boot_loader_raises_crc_error_on_corrupt_payload(dut):
    """Flip one bit in the first payload byte → CRC mismatch → loader errors out."""

    image_raw = bytearray(IMAGE.read_bytes())
    manifest = json.loads(MANIFEST.read_text())
    first = manifest["entries"][0]
    corrupt_offset = first["flash_offset"]

    # Flip MSB of the first payload byte to guarantee a CRC mismatch.
    image_raw[corrupt_offset] ^= 0x80
    image = bytes(image_raw)

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.start.value = 0

    idx = 0
    timeout = 40000
    saw_crc_error = False
    saw_done = False
    await Timer(1, unit="ps")

    while timeout:
        can_send = idx < len(image)
        ready_before_edge = bool(int(dut.flash_ready.value))

        if can_send:
            dut.flash_data.value = image[idx]
            dut.flash_valid.value = 1
        else:
            dut.flash_valid.value = 0

        await RisingEdge(dut.sys_clk)

        if can_send and ready_before_edge:
            idx += 1

        await Timer(1, unit="ps")

        if int(dut.crc_error.value):
            saw_crc_error = True
        if int(dut.done.value):
            saw_done = True
            break
        if int(dut.error.value) and saw_crc_error:
            # Expected error path triggered by CRC mismatch.
            break
        timeout -= 1

    dut.flash_valid.value = 0
    assert timeout > 0, "Timed out waiting for loader to raise CRC error"
    assert saw_crc_error, "crc_error was never asserted despite corrupted payload"
    assert not saw_done, "Loader signalled DONE even though payload CRC was wrong"
    assert int(dut.error.value) == 1, "Loader should end in ERROR state"
    cover("weight_image.crc_fail")


@cocotb.test()
async def test_weight_boot_loader_crc_pass_path(dut):
    """Clean image (no corruption) → CRC matches → loader reports DONE, no error."""

    image = IMAGE.read_bytes()

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.start.value = 0

    idx = 0
    timeout = 40000
    await Timer(1, unit="ps")

    while timeout:
        can_send = idx < len(image)
        ready_before_edge = bool(int(dut.flash_ready.value))

        if can_send:
            dut.flash_data.value = image[idx]
            dut.flash_valid.value = 1
        else:
            dut.flash_valid.value = 0

        await RisingEdge(dut.sys_clk)

        if can_send and ready_before_edge:
            idx += 1

        await Timer(1, unit="ps")

        if int(dut.done.value):
            break
        if int(dut.error.value):
            assert False, "Unexpected error on clean image"
        timeout -= 1

    dut.flash_valid.value = 0
    assert timeout > 0, "Timed out on clean image"
    assert int(dut.crc_error.value) == 0
    assert int(dut.error.value) == 0
    assert int(dut.done.value) == 1
    cover("weight_image.crc_pass")

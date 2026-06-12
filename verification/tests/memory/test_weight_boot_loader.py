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


def _masked_bytes(word_value, mask_value):
    out = []
    word = int(word_value)
    mask = int(mask_value)
    for idx in range(32):
        if ((mask >> idx) & 1) == 0:
            out.append((word >> (idx * 8)) & 0xFF)
    return bytes(out)


@cocotb.test()
async def test_weight_boot_loader_copies_flash_image_to_ddr(dut):
    """Parse packed weight image and write every payload blob to DDR bursts."""

    image = IMAGE.read_bytes()
    manifest = json.loads(MANIFEST.read_text())
    expected = {}
    for entry in manifest["entries"]:
        start = entry["flash_offset"]
        end = start + entry["size"]
        expected[entry["ddr_addr"]] = image[start:end]

    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    await _reset(dut)

    dut.start.value = 1
    await RisingEdge(dut.sys_clk)
    dut.start.value = 0

    ddr = {}
    idx = 0
    timeout = 20000
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

        if int(dut.header_valid.value):
            assert int(dut.entry_count_out.value) == manifest["entry_count"]
            assert int(dut.image_len_out.value) == manifest["image_len"]
            cover("weight_image.header_parse")

        if int(dut.entry_valid.value):
            cover("weight_image.entry_table_parse")

        if int(dut.ddr_cmd_en.value) or int(dut.ddr_wr_data_en.value):
            assert int(dut.ddr_cmd_en.value) == 1
            assert int(dut.ddr_wr_data_en.value) == 1
            assert int(dut.ddr_wr_data_end.value) == 1
            assert int(dut.ddr_cmd.value) == 0
            addr = int(dut.ddr_addr.value)
            data = _masked_bytes(dut.ddr_wr_data.value, dut.ddr_wr_data_mask.value)
            ddr.setdefault(addr, b"")
            ddr[addr] += data
            cover("ddr3_adapter.write_burst")
            if int(dut.ddr_wr_data_mask.value) != 0:
                cover("ddr3_adapter.write_partial_burst")

        if int(dut.done.value):
            break
        if int(dut.error.value):
            dut._log.error(
                "loader error state=%s byte_offset=%s table_idx=%s entry_byte=%s entry_count=%s image_len=%s current_flash=%s",
                dut.state.value,
                dut.byte_offset.value,
                dut.table_entry_idx.value,
                dut.entry_byte_idx.value,
                dut.entry_count_out.value,
                dut.image_len_out.value,
                dut.current_entry_flash_offset.value,
            )
            assert False, "weight_boot_loader raised error"
        timeout -= 1

    dut.flash_valid.value = 0
    if timeout == 0:
        dut._log.error(
            "timeout idx=%d/%d state=%s byte_offset=%s current_entry=%s current_flash=%s current_size=%s writer_busy=%s writer_done=%s",
            idx,
            len(image),
            dut.state.value,
            dut.byte_offset.value,
            dut.current_entry.value,
            dut.current_entry_flash_offset.value,
            dut.current_entry_size.value,
            dut.u_writer.busy.value,
            dut.u_writer.done.value,
        )
    assert timeout > 0, "Timed out waiting for weight boot loader"
    assert idx == len(image)
    assert int(dut.entries_loaded.value) == manifest["entry_count"]

    for entry in manifest["entries"]:
        base = entry["ddr_addr"]
        size = entry["size"]
        chunks = []
        for addr in range(base, base + size, 32):
            chunks.append(ddr.get(addr, b""))
        observed = b"".join(chunks)[:size]
        assert observed == expected[base], f"DDR payload mismatch for {entry['name']}"

    cover("weight_image.copy_to_ddr")
    cover("weight_image.payload_alignment")
    cover("flash_loader.copy_to_ddr")

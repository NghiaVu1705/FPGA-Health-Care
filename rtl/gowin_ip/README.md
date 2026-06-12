# rtl/gowin_ip — Gowin vendor IP (consolidated for the `Final` project)

These files are **copies** of the Gowin-generated / encrypted IP cores from
`gowin_fpga/src/`, gathered here so the `Final/Final.gprj` project tree is
self-contained under `rtl/`.

| File | IP |
|------|----|
| `gowin_pll_sys.v`, `gowin_pll/TMDS_PLL_60HZ*.v`, `gowin_pll/gowin_pll_400M*.v`, `pll_init.v` | PLL (sys clock, HDMI/TMDS, DDR 400M) |
| `gowin_fifo_async.v` | Async CDC FIFO 256×16 |
| `gowin_bsram_hamming.v`, `gowin_bsram_twiddle.v`, `gowin_bsram_cnn_{eeg,ecg,emg}.v` | BSRAM ROM (Hamming/Twiddle/CNN weights) |
| `ddr3_memory_interface/DDR3MI_400M.v` | DDR3 Memory Interface (encrypted) |
| `dvi_tx/DVI_TX_Top.v` | DVI/HDMI TX (encrypted) |

Caveat: the core `rtl/` cores stay technology-independent; this folder is
Gowin-specific and is **not** compiled by the cocotb/icarus verification
(which uses stubs in `verification/models/`). The originals in
`gowin_fpga/src/` remain the upstream copy — keep both in sync if regenerated.

import numpy as np

def read_twiddles():
    path = "/Users/hothikimhue/Desktop/NCKH/rtl/gowin_bsram/fft_twiddle_rom.hex"
    lines = open(path).read().splitlines()
    twiddles = []
    for l in lines:
        if not l.strip(): continue
        val = int(l.strip(), 16)
        w_re = val & 0xFFFF
        if w_re & 0x8000:
            w_re -= 0x10000
        w_im = (val >> 16) & 0xFFFF
        if w_im & 0x8000:
            w_im -= 0x10000
        twiddles.append(w_re + 1j * w_im)
    return np.array(twiddles)

def bit_rev6(val):
    b = format(val, '06b')
    return int(b[::-1], 2)

def rtl_fft(x):
    buf = np.zeros(64, dtype=complex)
    for i in range(64):
        buf[bit_rev6(i)] = x[i]
    
    tw = read_twiddles()
    
    print(f"Initial: buf_re[0]={buf[0].real:.1f}, buf_re[32]={buf[32].real:.1f}, buf_re[16]={buf[16].real:.1f}, buf_re[48]={buf[48].real:.1f}")

    for stage in range(6):
        stride = 1 << stage
        groups = 32 >> stage
        tw_step = 32 >> stage
        
        next_buf = buf.copy()
        for group in range(groups):
            group_base = group << (stage + 1)
            for pair in range(stride):
                a_idx = group_base + pair
                b_idx = a_idx + stride
                
                tw_k = pair * tw_step
                w = tw[tw_k]
                
                a = buf[a_idx]
                b = buf[b_idx]
                
                p_re = int(round(b.real * w.real)) - int(round(b.imag * w.imag))
                p_im = int(round(b.real * w.imag)) + int(round(b.imag * w.real))
                
                t_re = p_re >> 14
                t_im = p_im >> 14
                t = t_re + 1j * t_im
                
                next_buf[a_idx] = (a + t) / 2.0
                next_buf[b_idx] = (a - t) / 2.0
        buf = next_buf
        print(f"Stage {stage} complete: buf_re[0]={buf[0].real:.1f}, buf_re[1]={buf[1].real:.1f}, buf_re[2]={buf[2].real:.1f}, buf_re[3]={buf[3].real:.1f}, buf_re[7]={buf[7].real:.1f}, buf_re[8]={buf[8].real:.1f}")
    return buf

n = np.arange(64)
sine_bin = 8
hamming_hex = "/Users/hothikimhue/Desktop/NCKH/rtl/gowin_bsram/hamming_coeff_rom.hex"
hamming = [int(line.strip(), 16) for line in open(hamming_hex).read().splitlines() if line.strip()]
window = np.array(hamming, dtype=float) / 256.0

samples = np.rint(12000.0 * np.sin(2.0 * np.pi * sine_bin * n / 64.0)).astype(np.int16)
windowed_samples = np.rint(samples * window).astype(np.int16)

rtl_res = rtl_fft(windowed_samples)

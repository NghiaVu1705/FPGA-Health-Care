#!/usr/bin/env python3
"""
test_vector_generator.py
Generates simulated biosignal test vectors to stream from ESP32 to Gowin FPGA
via SPI (EEG/ECG) and UART (EMG).
"""

import struct
import numpy as np

def clamp(val, min_val, max_val):
    return max(min_val, min(max_val, val))

def generate_spi_frame(channel, sample_val):
    # Map signed 16-bit sample back to 12-bit ADC value: S = ADC - 2048 -> ADC = S + 2048
    adc_val = clamp(int(sample_val) + 2048, 0, 4095)
    # Channel bit: EEG = 0 (bit 15 = 0), ECG = 1 (bit 15 = 1)
    frame = ((channel & 1) << 15) | (adc_val & 0xFFF)
    # Pack as 16-bit big-endian unsigned short (matching SPI transmission order)
    return struct.pack(">H", frame)

def generate_uart_frame(sample_val):
    # EMG frame is 16-bit signed Big-Endian: {0xAA, data_hi, data_lo, checksum}
    # where checksum = data_hi ^ data_lo
    val_s16 = clamp(int(sample_val), -32768, 32767)
    # Convert to unsigned 16-bit representation
    u16 = val_s16 & 0xFFFF
    data_hi = (u16 >> 8) & 0xFF
    data_lo = u16 & 0xFF
    checksum = data_hi ^ data_lo
    return struct.pack("BBBB", 0xAA, data_hi, data_lo, checksum)

def main():
    print("Generating simulated signals...")
    
    # 1. EEG (Channel 0): sine wave at 10 Hz, 256 Hz sample rate, length = 10 seconds
    t_eeg = np.linspace(0, 10, 256 * 10, endpoint=False)
    eeg_samples = (100 * np.sin(2 * np.pi * 10 * t_eeg)).astype(np.int16)
    
    # 2. ECG (Channel 1): simulated heart beat at 1.2 Hz (72 BPM), 500 Hz sample rate, 10 seconds
    t_ecg = np.linspace(0, 10, 500 * 10, endpoint=False)
    # Simple simulated ECG R-peaks
    ecg_samples = np.zeros_like(t_ecg)
    for heart_beat_t in np.arange(0, 10, 1.0 / 1.2):
        peak_idx = int(heart_beat_t * 500)
        if peak_idx < len(ecg_samples):
            ecg_samples[peak_idx : peak_idx + 10] = 500  # R-peak
            
    # Write SPI binary file (interleaved or sequentially)
    # Here we write EEG first, then ECG for simple sequential tests
    with open("spi_eeg_test.bin", "wb") as f:
        for val in eeg_samples:
            f.write(generate_spi_frame(channel=0, sample_val=val))
    print(f"Generated spi_eeg_test.bin with {len(eeg_samples)} samples.")

    with open("spi_ecg_test.bin", "wb") as f:
        for val in ecg_samples:
            f.write(generate_spi_frame(channel=1, sample_val=val))
    print(f"Generated spi_ecg_test.bin with {len(ecg_samples)} samples.")

    # 3. EMG: noise or high frequency sine (e.g. 50 Hz), 1000 Hz sample rate, 10 seconds
    t_emg = np.linspace(0, 10, 1000 * 10, endpoint=False)
    emg_samples = (200 * np.sin(2 * np.pi * 50 * t_emg) + 50 * np.random.randn(len(t_emg))).astype(np.int16)
    
    with open("uart_emg_test.bin", "wb") as f:
        for val in emg_samples:
            f.write(generate_uart_frame(val))
    print(f"Generated uart_emg_test.bin with {len(emg_samples)} samples.")

    # Print I2C command format
    print("\nI2C Diagnostic Guide:")
    print("--------------------")
    print("Slave Address: 0x48")
    print("Registers:")
    print("  - 0x00 (SpO2 Raw): Write byte in range [0..100]. Default display 98%.")
    print("  - 0x01 (Body Temp): Write byte in range [0..255] (0.5 degC per LSB). e.g., 72 -> 36.0 degC.")

if __name__ == "__main__":
    main()

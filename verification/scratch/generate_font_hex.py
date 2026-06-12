import urllib.request
import re
import os

def main():
    url = "https://raw.githubusercontent.com/torvalds/linux/master/lib/fonts/font_8x16.c"
    print(f"Downloading font from {url}...")
    try:
        with urllib.request.urlopen(url) as response:
            content = response.read().decode('utf-8')
    except Exception as e:
        print(f"Error downloading font: {e}")
        return

    # Extract all hex numbers like 0xNN from the fontdata array
    # We find the static const struct font_data fontdata_8x16 block
    match = re.search(r'static const struct font_data fontdata_8x16 = \{(?:[^{}]*|\{[^{}]*\})*\}', content, re.DOTALL)
    if not match:
        # Try a simpler regex if struct definition varies
        match = re.search(r'static const struct font_data fontdata_8x16 = \{.*?\}\s*;', content, re.DOTALL)
    
    if match:
        data_block = match.group(0)
    else:
        # Fallback: just search all hex values in the whole file if the struct pattern matches differently
        data_block = content
        print("Warning: could not locate fontdata_8x16 structure, parsing whole file.")

    # Find all hex values like 0xNN (excluding the ones in headers or sizes, but the array is the bulk)
    # The array values are typically formatted as 0xNN, or 0xNN, /* comment */
    hex_values = re.findall(r'0x([0-9a-fA-F]{2})', data_block)
    
    # In Linux font_8x16.c:
    # First 4 values might be the header { 0, 0, FONTDATAMAX, 0 } in the struct if they match.
    # Let's check: the struct has two fields: first is struct font_desc (metadata), second is the array itself.
    # The metadata in newer kernels might be defined as:
    # static const struct font_data fontdata_8x16 = { { 0, 0, FONTDATAMAX, 0 }, { ... } };
    # Let's inspect the hex values. We expect 4096 bytes of font data.
    # Let's search for 0xNN occurrences that are clearly inside the array.
    # In the file, the array values are preceded by comments like /* 0 0x00 '^@' */
    # Let's parse character by character to be extremely precise!
    chars = {}
    current_char = None
    char_lines = []
    
    lines = content.split('\n')
    for line in lines:
        # Check if this line marks a character, e.g. /* 32 0x20 ' ' */
        char_mark = re.search(r'/\*\s*(\d+)\s+0x([0-9a-fA-F]{2})', line)
        if char_mark:
            if current_char is not None:
                chars[current_char] = char_lines
            current_char = int(char_mark.group(1))
            char_lines = []
            continue
        
        if current_char is not None:
            # Extract hex values from the line
            hex_in_line = re.findall(r'0x([0-9a-fA-F]{2})', line)
            if hex_in_line:
                char_lines.extend(hex_in_line)
                
    if current_char is not None:
        chars[current_char] = char_lines

    print(f"Parsed {len(chars)} characters from file.")
    
    # We need ASCII 32 to 126 inclusive
    out_lines = []
    for c in range(32, 127):
        if c in chars:
            val_list = chars[c]
            if len(val_list) != 16:
                print(f"Warning: Character {c} has {len(val_list)} lines instead of 16!")
                # Pad or truncate to 16
                val_list = (val_list + ['00']*16)[:16]
            for v in val_list:
                out_lines.append(v.lower())
        else:
            print(f"Error: Character {c} not found in font data!")
            # Add dummy zeros
            out_lines.extend(['00']*16)

    # Write to font8x16.hex
    output_path = "/Users/vuhieunghia/Desktop/NCKH/rtl/display/font8x16.hex"
    with open(output_path, "w") as f:
        for val in out_lines:
            f.write(val + "\n")
            
    print(f"Successfully wrote {len(out_lines)} hex values ({len(out_lines)//16} characters) to {output_path}")

if __name__ == "__main__":
    main()

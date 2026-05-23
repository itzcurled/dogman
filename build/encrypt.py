import sys
import os

def encrypt_file(input_file, output_header, key):
    with open(input_file, 'rb') as f:
        data = bytearray(f.read())
    
    for i in range(len(data)):
        data[i] ^= key

    with open(output_header, 'w') as f:
        f.write('#pragma once\n')
        f.write('const unsigned char payload[] = {\n')
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            f.write('    ' + ', '.join(f'0x{b:02x}' for b in chunk) + ',\n')
        f.write('};\n')
        f.write(f'const unsigned int payload_size = {len(data)};\n')
        f.write(f'const unsigned char payload_key = 0x{key:02x};\n')

if __name__ == '__main__':
    encrypt_file(sys.argv[1], sys.argv[2], 0x42)

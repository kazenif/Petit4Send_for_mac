"""Independent P4SEND122.PRG screenshot layout reference, stdlib only.
Run from repository root. Writes PNG directly using stdlib zlib.
"""
import pathlib, struct, zlib
root=pathlib.Path('Tests/Petit4SendCoreTests/Fixtures'); root.mkdir(exist_ok=True)
data=bytes((i*73+i//257)%256 for i in range(181384))
crc=0xffff
for b in data:
    crc ^= b
    for _ in range(8): crc=(crc>>1) ^ (0xc7ed if crc&1 else 0)
crc ^= 0xffff
(root/'expected.bin').write_bytes(data)
for index, offset in enumerate(range(0,len(data),181380)):
    payload=data[offset:offset+181380]
    header=struct.pack('<III36sBBBBIHH',0x505a5332,len(data),crc,b'DAT:REFERENCE',2,index,0xa7,0,len(payload),720,720)
    stream=header+bytes(b^0xa7 for b in payload)
    # Interpret the serialized stream as a single LSB-first integer, as BASIC's 32-bit words do.
    encoded=int.from_bytes(stream,'little')
    pixels=bytearray(1280*720*3)
    levels=[0,43,85,128,170,213,255]
    for group in range((len(stream)*8+13)//14):
        value=(encoded>>(group*14))&16383
        x,y=divmod(group*5,720)
        for k in range(5):
            color=levels[value%7]; value//=7
            p=((y+k)*1280+x)*3
            pixels[p:p+3]=bytes([color])*3
    # Write an sRGB PNG directly with no resampling or color transform.
    def chunk(kind,payload):
        return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload))
    scan=b''.join(b'\0'+pixels[y*3840:(y+1)*3840] for y in range(720))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1280,720,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b'')
    (root/f'page-{index+1}.png').write_bytes(png)

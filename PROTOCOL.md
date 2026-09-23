# P4SEND 1.2.2 protocol notes

Sources: local `P4SEND122.PRG`; local `Petit4Send.exe` .NET IL. No online specification was assumed. `Tools/inspect_dotnet.py` prints selected MethodDef indices. Relevant methods: 38 DetectSerialStart; 40 buttonSend_Click; 43 SendThreadMain; 46 nCrInvIndex; 70 GetEmbeddedInformation; 71 DecodeBitmap; 73 ConvertFiles; 75 LZ; 76 UnLZ.

## USB byte stream

All multibyte integers are little endian.

| Stream offset | Length | Meaning |
|---|---:|---|
| 0 | 16 | zero preamble |
| 16 | 50 | bytes equal to 1 |
| 66 | 1 | zero sync delimiter |
| 67 | 36 | four-byte type prefix + 32-byte ASCII name (zero-padded) |
| 103 | 4 | uncompressed byte count |
| 107 | 2 | GRP width, otherwise zero |
| 109 | 2 | GRP height, otherwise zero |
| 111 | 1 | compression: 0 raw, 1 LZSS |
| 112 | 4 | transmitted payload byte count |
| 116 | variable | payload |
| after payload | 2 | CRC over original uncompressed bytes |
| after CRC | 16 | zero tail |

TXT is UTF-16LE with no BOM. DAT is raw bytes. GRP is row-major BGRA, excluding dimensions from the payload.

## Serial packets

9600 baud, 8 data bits, no parity, one stop bit; DTR asserted. Initial synchronization sends one zero byte repeatedly and waits for a reply byte. Original code ignores the value of the reply. At most four 12-byte packets are in flight; one byte of acknowledgement is consumed per packet. This is acknowledgement from the Arduino path, not end-to-end acknowledgement from Switch.

Packet: command; six HID keycodes; modifiers; mouse buttons; three zero bytes. Command is 3 for automatic sync, or `2 + 4*syncKey` for 0...24. The 195 keycode values agree byte-for-byte between the BASIC program and the executable's static data.

Starting at clock 0, consume 37 LSB-first stream bits. Rank the lower 36 bits in the combinatorial number system with six distinct indices selected from 0...194. HID keys are emitted in descending index order, matching the Windows implementation. Modifier byte is `((clock&1)<<3)|(clock&2)|((value>>34)&4)`. Every even clock also consumes the following five bits and retains them as mouse buttons across the next odd frame; mouse bits 3 and 4 are swapped. Thus two frames transfer 79 bits. Switch reads retained mouse bits before the keys on odd clocks. End-of-stream partial frames are zero padded. End/release reports use no keys and modifiers 10, 2, 8, 0.

## Sync Key detection

MethodDef 41 `buttonDetectSyncKey_Click` opens the same 9600 8N1/DTR connection and performs DetectSerialStart. It writes a 12-byte packet `01 00 00 00 00 00 00 00 00 00 00 00`, consumes one acknowledgement byte, waits 4000 ms, then writes a 12-byte all-zero packet twice, each followed by one acknowledgement. Arduino generates the detection pattern; the Switch program displays the key. The acknowledgement does not contain the detected key value.

The Mac version runs this off the main UI thread and checks cancellation during the wait. Both stop packets are attempted even after cancellation or a communication failure, with bounded acknowledgement timeouts. Failure to deliver stop packets on a disconnected device cannot guarantee stopping the pattern; reconnect the device in that case.

## LZSS and CRC

LSB-first tokens: flag 0 + eight literal bits, or flag 1 + ten bits of distance-minus-one + five bits of length-minus-one. History is a 1024-byte zero-initialized ring. References may overlap. Encoder uses matches of 3...32 bytes. Byte-packed output is padded to 32-bit words for Switch. Decoder stops at the original byte count (padding is not file content).

CRC starts at FFFF, reflected polynomial C7ED, final XOR FFFF. `123456789` gives 0B3A. This directly reproduces BASIC's CALC_CRCTBL/CALC_CRC; it should not be substituted with an unrelated similarly named CRC variant.

## Screenshot stream

Leftmost 720×720 pixels of a 1280×720 image. Traverse down each column, then right. Five pixels form a little-endian base-7 number; append its low 14 bits to an LSB-first byte stream. Grayscale values are 0,43,85,128,170,213,255. Windows quantization thresholds on the green channel are 22,64,107,149,191,234.

| Header offset | Length | Meaning |
|---|---:|---|
| 0 | 4 | integer 505A5332 (bytes 32 53 5A 50) |
| 4 | 4 | uncompressed size |
| 8 | 4 | CRC16 stored in 32-bit field |
| 12 | 36 | ASCII type:name |
| 48 | 1 | number of pages |
| 49 | 1 | zero-based page index |
| 50 | 1 | XOR mask for this page's payload |
| 51 | 1 | compression |
| 52 | 4 | this page's payload length |
| 56 | 2 | encoded area width (720) |
| 58 | 2 | encoded area height (720) |

Capacity: 720×720×14/5/8 = 181440 bytes including a 60-byte header, i.e. 181380 payload bytes per full page. The misleading 194400 comment in BASIC is not used. Header and payload share the same bit stream with no alignment gap. Undo each page's XOR, order by index, concatenate, then decompress and verify CRC. GRP screenshot payload includes a four-byte width/height prefix, unlike USB GRP payload.

BASIC's raw fallback writes only complete 32-bit words. A raw screenshot of a file whose size is not a multiple of four can consequently lose trailing bytes in the source program; the Mac app reports a length/CRC error rather than inventing bytes. BASIC page count is one byte; transfers requiring more than 255 pages cannot be represented reliably by this format.

## Validation limits

The 15 XCTest cases include a two-page, 181384-byte fixture generated independently by Python, including the 181380-byte page boundary, bit packing, mask removal, reverse ordering, and CRC. They do not replace USB hardware testing or validation against an actual Switch-produced JPEG. No hardware was flashed or serial transfer started during implementation.

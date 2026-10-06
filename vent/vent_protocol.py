"""Roof-vent remote (LT8920, 2.4 GHz) frame encoder - see docs/architecture/vent-rf-integration.md.

Run `python3 vent/vent_protocol.py` to check the encoder against every frame captured on the
remote's U1->U2 SPI bus (2026-10-05).
"""

# LT8920 setup used by the remote (registers written by U1 at power-up)
SYNC_WORD = (0x0516, 0x0001, 0x5A5A, 0x1982)  # r36..r39; 32-bit mode uses r36 + r39
CHANNELS = (6, 26, 62, 78)  # LT8920 channels, f = 2402 + ch MHz
REMOTE_ID = (0x5F, 0x18, 0x02, 0x00, 0x0E)  # this remote; presumably learned by the vent when paired


def crc16_kermit(data, crc=0x0000):
    """LT8920 hardware CRC (r41 seed 00) over length byte + payload; sent low byte first."""
    for x in data:
        crc ^= x
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def fifo_bytes(power, fan_level, fan_out=True, opening=False, closing=False, rain=False, remote_id=REMOTE_ID):
    """Bytes U1 writes to the LT8920 FIFO (length byte + 9-byte payload)."""
    if not 0 <= fan_level <= 10:
        raise ValueError("fan_level is 0..10 (x10 %)")
    flags = power << 7 | rain << 6 | closing << 5 | opening << 4
    fan = fan_out << 7 | fan_level
    frame = [9, *remote_id, flags, 0xCF, fan]
    return frame + [sum(frame) & 0xFF]


def air_frame(*args, **kwargs):
    """FIFO bytes + hardware CRC, i.e. what follows the sync word + 4-bit trailer on air (LSB first)."""
    frame = fifo_bytes(*args, **kwargs)
    crc = crc16_kermit(frame)
    return frame + [crc & 0xFF, crc >> 8]


# (state, FIFO bytes + on-air CRC) exactly as captured on the SPI bus
CAPTURED = [
    (dict(power=1, fan_level=0), "09 5F 18 02 00 0E 80 CF 80 5F 9B A1"),
    (dict(power=0, fan_level=0, closing=True), "09 5F 18 02 00 0E 20 CF 80 FF AC A6"),
    *((dict(power=1, fan_level=n), f"09 5F 18 02 00 0E 80 CF {0x80 + n:02X} {0x5F + n:02X} {crc}")
      for n, crc in [(1, "37 71"), (2, "D6 4A"), (3, "95 61"), (4, "14 3D"), (5, "73 50"), (6, "92 6B"),
                     (7, "D1 40"), (8, "90 D2"), (9, "BF 33"), (10, "5E 08")]),
    (dict(power=1, fan_level=0, fan_out=False), "09 5F 18 02 00 0E 80 CF 00 DF 5F A9"),
    (dict(power=1, fan_level=0, opening=True), "09 5F 18 02 00 0E 90 CF 80 6F B9 53"),
    (dict(power=1, fan_level=0, closing=True), "09 5F 18 02 00 0E A0 CF 80 7F CA 0F"),
    (dict(power=1, fan_level=0, closing=True, rain=True), "09 5F 18 02 00 0E E0 CF 80 BF 71 DF"),
]

if __name__ == "__main__":
    bad = 0
    for state, seen in CAPTURED:
        got = " ".join(f"{b:02X}" for b in air_frame(**state))
        bad += got != seen
        print(f"{'ok ' if got == seen else 'BAD'} {got}  {state}")
    print(f"{len(CAPTURED) - bad}/{len(CAPTURED)} captured frames reproduced")
    raise SystemExit(bad != 0)

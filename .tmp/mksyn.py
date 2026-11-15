# 生成一帧合法的 v3 结果帧（34 字节），用来离线验证 tools/uart_parse.py
def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def be16(v):
    return [(v >> 8) & 0xFF, v & 0xFF]

f = [0xA5, 0x5A]
f.append(0x81)                      # v3 + valid
f += be16(400)                      # cx
f += be16(240)                      # cy
f += be16(400)                      # ax
f += be16(200)                      # ay
f.append(120)                       # w
f.append(243)                       # area >> 7
f.append(201)                       # fill_q8
f.append(1)                         # blob_cnt
f += be16(16)                       # vx_q4 = 1.0 px/frame
f += be16(0)                        # vy_q4
f += be16(416)                      # px
f += be16(200)                      # py
f += be16(200)                      # dist_cm
f += be16(10)                       # drop_px
f += be16(416)                      # fx
f += be16(200)                      # fy
f.append(5)                         # seq
f += be16(crc16(f[2:32]))
assert len(f) == 34, len(f)
print(" ".join("%02X" % b for b in f))

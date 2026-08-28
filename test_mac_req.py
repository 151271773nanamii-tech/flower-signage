import serial
import time
import binascii

PORT = "/dev/cu.usbserial-110"
BAUDRATE = 115200

# ============================================================
# CRC-16/CCITT
# ============================================================

def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    return binascii.crc_hqx(data, init)


# ============================================================
# MAC request packet
#
# 現時点では候補パケット。
# USB Storage切替などの書込み系コマンドは送らない。
# ============================================================

def make_mac_request() -> bytes:
    # Header
    packet = bytearray([
        0xA5,
        0xFA,

        # MAC request command candidate
        0x09,
        0x02,

        # payload
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    ])

    crc = crc16_ccitt(packet)

    # CRC little endian
    packet.append(crc & 0xFF)
    packet.append((crc >> 8) & 0xFF)

    return bytes(packet)


def hex_string(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


def main():
    packet = make_mac_request()

    print("================================")
    print("BLE tag MAC request test")
    print("================================")
    print(f"Port : {PORT}")
    print(f"Baud : {BAUDRATE}")
    print(f"TX   : {hex_string(packet)}")
    print()

    try:
        with serial.Serial(
            port=PORT,
            baudrate=BAUDRATE,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=2.0,
            write_timeout=2.0,
        ) as ser:

            # 古い受信データを捨てる
            ser.reset_input_buffer()
            ser.reset_output_buffer()

            time.sleep(0.3)

            print("[1] Serial port opened")

            # MAC取得要求
            written = ser.write(packet)
            ser.flush()

            print(f"[2] Sent {written} bytes")

            # 少し待つ
            time.sleep(0.5)

            # 応答取得
            response = ser.read(256)

            if not response:
                print("[3] No response")
                print()
                print(
                    "タグから応答がありませんでした。"
                    "\nこの場合でもタグ故障とは限りません。"
                    "\nパケット形式・CRC・コマンドの"
                    "エンディアンを再確認します。"
                )
                return

            print(f"[3] RX length = {len(response)}")
            print(f"[3] RX = {hex_string(response)}")

            print()
            print("Raw response:")
            print(response)

    except serial.SerialException as e:
        print()
        print("SERIAL ERROR")
        print(e)

    except Exception as e:
        print()
        print("ERROR")
        print(e)


if __name__ == "__main__":
    main()
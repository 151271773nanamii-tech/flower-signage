import serial
import time
import binascii
import os

PORT = "/dev/cu.usbserial-110"
BAUDRATE = 115200


def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    return binascii.crc_hqx(data, init)


def hex_string(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


def make_usb_storage_request() -> bytes:
    packet = bytearray([
        0xA5,
        0xFA,

        # USB Storage mode request
        0x09,
        0x03,

        # payload
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    ])

    crc = crc16_ccitt(packet)

    packet.append(crc & 0xFF)
    packet.append((crc >> 8) & 0xFF)

    return bytes(packet)


def show_volumes():
    print()
    print("Current /Volumes:")

    try:
        for name in os.listdir("/Volumes"):
            print(f"  {name}")
    except Exception as e:
        print(f"Cannot read /Volumes: {e}")


def main():
    packet = make_usb_storage_request()

    print("================================")
    print("BLE tag USB Storage mode test")
    print("================================")
    print(f"Port : {PORT}")
    print(f"Baud : {BAUDRATE}")
    print(f"TX   : {hex_string(packet)}")

    show_volumes()

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

            ser.reset_input_buffer()
            ser.reset_output_buffer()

            time.sleep(0.3)

            print()
            print("[1] Serial port opened")

            written = ser.write(packet)
            ser.flush()

            print(f"[2] Sent {written} bytes")

            time.sleep(0.5)

            response = ser.read(256)

            if response:
                print(
                    f"[3] RX length = {len(response)}"
                )
                print(
                    f"[3] RX = {hex_string(response)}"
                )
            else:
                print(
                    "[3] No serial response"
                )

        print()
        print(
            "[4] Waiting for USB storage..."
        )

        # USB mode切替後の再認識を待つ
        for i in range(10):
            time.sleep(1)

            serial_exists = os.path.exists(
                PORT
            )

            volumes = os.listdir(
                "/Volumes"
            )

            print(
                f"[{i + 1}s] "
                f"serial={serial_exists}, "
                f"volumes={volumes}"
            )

    except serial.SerialException as e:
        print()
        print("SERIAL ERROR")
        print(e)

    except Exception as e:
        print()
        print("ERROR")
        print(e)

    show_volumes()


if __name__ == "__main__":
    main()
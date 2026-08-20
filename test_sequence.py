import binascii
import os
import time
from datetime import datetime

import serial


PORT = "/dev/cu.usbserial-110"
BAUDRATE = 115200

STORAGE_WAIT_SECONDS = 15


# ============================================================
# CRC-16/CCITT
# init = 0x0000
# ============================================================

def crc16_ccitt(
    data: bytes,
    init: int = 0x0000,
) -> int:
    return binascii.crc_hqx(
        data,
        init,
    )


# ============================================================
# HEX表示
# ============================================================

def hex_string(
    data: bytes,
) -> str:
    return " ".join(
        f"{b:02X}"
        for b in data
    )


# ============================================================
# 共通12-byte packet
#
# A5 FA
# 09 CMD
# payload 6 bytes
# CRC 2 bytes
# ============================================================

def make_packet(
    command: int,
    payload=None,
) -> bytes:
    if payload is None:
        payload = [0] * 6

    if len(payload) != 6:
        raise ValueError(
            "payload must be exactly 6 bytes"
        )

    packet = bytearray(
        [
            0xA5,
            0xFA,
            0x09,
            command,
            *payload,
        ]
    )

    crc = crc16_ccitt(
        packet,
    )

    # CRC little endian
    packet.append(
        crc & 0xFF
    )

    packet.append(
        (crc >> 8) & 0xFF
    )

    return bytes(
        packet
    )


# ============================================================
# TIME SYNC
#
# payload:
# year-2000
# month
# day
# hour
# minute
# second
# ============================================================

def make_time_sync_packet() -> bytes:
    now = datetime.now()

    year = now.year - 2000

    if not 0 <= year <= 255:
        raise ValueError(
            f"Unsupported year: {now.year}"
        )

    payload = [
        year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
    ]

    print(
        "TIME payload:",
        payload,
    )

    return make_packet(
        0x01,
        payload,
    )


# ============================================================
# MAC REQUEST
# ============================================================

def make_mac_request() -> bytes:
    return make_packet(
        0x02,
    )


# ============================================================
# USB STORAGE
# ============================================================

def make_usb_storage_request() -> bytes:
    return make_packet(
        0x03,
    )


# ============================================================
# TIME SYNC
# ============================================================

def time_sync(
    ser,
) -> bool:
    packet = make_time_sync_packet()

    print()
    print(
        "--------------------------------"
    )
    print(
        "1. TIME SYNC"
    )
    print(
        "--------------------------------"
    )

    ser.reset_input_buffer()

    print(
        "TX:",
        hex_string(packet),
    )

    ser.write(
        packet
    )

    ser.flush()

    time.sleep(
        0.5
    )

    response = ser.read(
        12
    )

    if len(response) != 12:
        print(
            "TIME SYNC: no valid response"
        )

        return False

    print(
        "RX:",
        hex_string(response),
    )

    if response[0:4] != bytes(
        [
            0xA5,
            0xFA,
            0x09,
            0xA1,
        ]
    ):
        print(
            "TIME SYNC: unexpected response"
        )

        return False

    status = response[4]

    print(
        f"Status: 0x{status:02X}"
    )

    if status != 0:
        print(
            "TIME SYNC: ERROR"
        )

        return False

    print(
        "TIME SYNC: SUCCESS"
    )

    return True


# ============================================================
# MAC REQUEST
# ============================================================

def read_mac(
    ser,
):
    packet = make_mac_request()

    print()
    print(
        "--------------------------------"
    )
    print(
        "2. MAC REQUEST"
    )
    print(
        "--------------------------------"
    )

    ser.reset_input_buffer()

    print(
        "TX:",
        hex_string(packet),
    )

    ser.write(
        packet
    )

    ser.flush()

    time.sleep(
        0.5
    )

    response = ser.read(
        12
    )

    if len(response) != 12:
        print(
            "MAC REQUEST: no valid response"
        )

        return None

    print(
        "RX:",
        hex_string(response),
    )

    if response[0:4] != bytes(
        [
            0xA5,
            0xFA,
            0x09,
            0xA2,
        ]
    ):
        print(
            "MAC REQUEST: unexpected response"
        )

        return None

    # A2の後ろ6byteがMAC
    mac_bytes = response[4:10]

    mac = ":".join(
        f"{b:02X}"
        for b in mac_bytes
    )

    print(
        f"MAC = {mac}"
    )

    return mac


# ============================================================
# USB STORAGE COMMAND
#
# 切替成功時はUART自体が消える可能性があるので
# 応答なしを即失敗扱いしない
# ============================================================

def request_usb_storage(
    ser,
):
    packet = make_usb_storage_request()

    print()
    print(
        "--------------------------------"
    )
    print(
        "3. USB STORAGE"
    )
    print(
        "--------------------------------"
    )

    ser.reset_input_buffer()

    print(
        "TX:",
        hex_string(packet),
    )

    ser.write(
        packet
    )

    ser.flush()

    time.sleep(
        0.3
    )

    try:
        response = ser.read(
            12
        )
    except serial.SerialException:
        # Storage切替でシリアルが消えた可能性
        response = b""

    if response:
        print(
            "RX:",
            hex_string(response),
        )

        if (
            len(response) >= 5
            and response[0:4]
            == bytes(
                [
                    0xA5,
                    0xFA,
                    0x09,
                    0xA3,
                ]
            )
        ):
            print(
                f"A3 value: "
                f"0x{response[4]:02X}"
            )
    else:
        print(
            "RX: no response "
            "(this can be normal)"
        )


# ============================================================
# STORAGE DETECTION
# ============================================================

def wait_for_storage(
    volumes_before,
):
    print()
    print(
        "Waiting for USB storage..."
    )

    for second in range(
        1,
        STORAGE_WAIT_SECONDS + 1,
    ):
        time.sleep(
            1
        )

        serial_exists = os.path.exists(
            PORT
        )

        try:
            volumes_now = set(
                os.listdir(
                    "/Volumes"
                )
            )
        except Exception as e:
            print(
                f"[{second:02d}s] "
                f"/Volumes error: {e}"
            )

            continue

        new_volumes = (
            volumes_now
            - volumes_before
        )

        print(
            f"[{second:02d}s] "
            f"serial={serial_exists} "
            f"volumes={sorted(volumes_now)}"
        )

        if new_volumes:
            for volume in sorted(new_volumes):
                path = f"/Volumes/{volume}"

                print()
                print("USB STORAGE FOUND")
                print(f"PATH: {path}")

                # macOSのマウント完了を少し待つ
                print("Waiting for filesystem ready...")

                for retry in range(10):
                    time.sleep(1)

                    try:
                        files = os.listdir(path)

                        print(
                            f"Filesystem ready "
                            f"after {retry + 1}s"
                        )

                        return path

                    except PermissionError:
                        print(
                            f"Filesystem not ready: "
                            f"{retry + 1}/10"
                        )

                    except OSError as e:
                        print(
                            f"Filesystem wait: "
                            f"{retry + 1}/10 "
                            f"{e}"
                        )

                print(
                    "ERROR: storage mounted but "
                    "filesystem could not be accessed"
                )

                return None

    print()
    print(
        "USB STORAGE NOT FOUND"
    )

    return None


# ============================================================
# MAIN
# ============================================================

def main():
    print(
        "================================"
    )
    print(
        "BLE tag USB initialization test"
    )
    print(
        "================================"
    )

    print(
        f"Port : {PORT}"
    )

    print(
        f"Baud : {BAUDRATE}"
    )

    if not os.path.exists(
        PORT
    ):
        print()
        print(
            "ERROR: serial port not found"
        )

        return

    try:
        volumes_before = set(
            os.listdir(
                "/Volumes"
            )
        )
    except Exception as e:
        print(
            f"ERROR reading /Volumes: {e}"
        )

        return

    print(
        "Volumes BEFORE:",
        sorted(volumes_before),
    )

    mac = None

    try:
        ser = serial.Serial(
            port=PORT,
            baudrate=BAUDRATE,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.0,
            write_timeout=2.0,
        )

        print()
        print(
            "Serial port opened"
        )

        time.sleep(
            0.3
        )

        # ====================================================
        # 1. TIME
        # ====================================================

        if not time_sync(
            ser
        ):
            print()
            print(
                "Sequence stopped."
            )

            ser.close()

            return

        time.sleep(
            0.3
        )

        # ====================================================
        # 2. MAC
        # ====================================================

        mac = read_mac(
            ser
        )

        if mac is None:
            print()
            print(
                "MAC acquisition failed."
            )

            ser.close()

            return

        time.sleep(
            0.3
        )

        # ====================================================
        # 3. STORAGE
        # ====================================================

        request_usb_storage(
            ser
        )

        try:
            ser.close()
        except Exception:
            pass

    except serial.SerialException as e:
        print()
        print(
            "SERIAL ERROR"
        )
        print(
            e
        )

        return

    # ========================================================
    # Storage detect
    # ========================================================

    storage_path = wait_for_storage(
        volumes_before
    )

    print()
    print(
        "================================"
    )
    print(
        "RESULT"
    )
    print(
        "================================"
    )

    print(
        f"MAC: {mac}"
    )

    if storage_path is None:
        print(
            "Storage: NOT FOUND"
        )

        return

    print(
        f"Storage: {storage_path}"
    )

    # ========================================================
    # user_info確認
    # ========================================================

    user_info_path = os.path.join(
        storage_path,
        "user_info.txt",
    )

    if os.path.exists(
        user_info_path
    ):
        print(
            "user_info.txt: FOUND"
        )
    else:
        print(
            "user_info.txt: NOT FOUND"
        )

    # ========================================================
    # LOG確認
    # ========================================================

    try:
        files = os.listdir(
            storage_path
        )

        log_files = [
            name
            for name in files
            if name.upper().startswith(
                "LOG"
            )
            and name.upper().endswith(
                ".TXT"
            )
        ]

        print(
            f"LOG count: "
            f"{len(log_files)}"
        )

    except Exception as e:
        print(
            f"Cannot inspect storage: {e}"
        )

    print()
    print(
        "TEST COMPLETE"
    )


if __name__ == "__main__":
    main()
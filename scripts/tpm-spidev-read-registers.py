#!/usr/bin/env python3
"""Read TPM TIS-over-SPI registers through Linux spidev.

This is a bring-up diagnostic tool. It intentionally talks to the SPI device
directly instead of using the kernel TPM stack.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import os
import struct
from dataclasses import dataclass


SPI_IOC_MAGIC = ord("k")
SPI_IOC_WR_MODE = 0x40016B01
SPI_IOC_WR_BITS_PER_WORD = 0x40016B03
SPI_IOC_WR_MAX_SPEED_HZ = 0x40046B04

IOC_NRBITS = 8
IOC_TYPEBITS = 8
IOC_SIZEBITS = 14
IOC_NRSHIFT = 0
IOC_TYPESHIFT = IOC_NRSHIFT + IOC_NRBITS
IOC_SIZESHIFT = IOC_TYPESHIFT + IOC_TYPEBITS
IOC_DIRSHIFT = IOC_SIZESHIFT + IOC_SIZEBITS
IOC_WRITE = 1


class SpiIocTransfer(ctypes.Structure):
    _fields_ = [
        ("tx_buf", ctypes.c_uint64),
        ("rx_buf", ctypes.c_uint64),
        ("len", ctypes.c_uint32),
        ("speed_hz", ctypes.c_uint32),
        ("delay_usecs", ctypes.c_uint16),
        ("bits_per_word", ctypes.c_uint8),
        ("cs_change", ctypes.c_uint8),
        ("tx_nbits", ctypes.c_uint8),
        ("rx_nbits", ctypes.c_uint8),
        ("word_delay_usecs", ctypes.c_uint8),
        ("pad", ctypes.c_uint8),
    ]


def spi_ioc_message(count: int) -> int:
    size = ctypes.sizeof(SpiIocTransfer) * count
    return (
        (IOC_WRITE << IOC_DIRSHIFT)
        | (SPI_IOC_MAGIC << IOC_TYPESHIFT)
        | (0 << IOC_NRSHIFT)
        | (size << IOC_SIZESHIFT)
    )


@dataclass(frozen=True)
class Register:
    name: str
    address: int
    length: int


REGISTERS = [
    Register("ACCESS_0", 0x0000, 1),
    Register("INT_ENABLE_0", 0x0008, 4),
    Register("INTF_CAPS_0", 0x0014, 4),
    Register("STS_0", 0x0018, 4),
    Register("DID_VID_0", 0x0F00, 4),
    Register("RID_0", 0x0F04, 1),
]


def configure_spi(fd: int, speed_hz: int, mode: int, bits_per_word: int) -> None:
    fcntl.ioctl(fd, SPI_IOC_WR_MODE, struct.pack("B", mode))
    fcntl.ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, struct.pack("B", bits_per_word))
    fcntl.ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, struct.pack("I", speed_hz))


def transfer(fd: int, chunks: list[tuple[bytes | None, int]], speed_hz: int) -> list[bytes]:
    transfers = []
    rx_buffers = []
    tx_buffers = []

    for tx_bytes, rx_len in chunks:
        if tx_bytes is None:
            length = rx_len
            tx_addr = 0
        else:
            length = len(tx_bytes)
            tx_buf = ctypes.create_string_buffer(tx_bytes, length)
            tx_buffers.append(tx_buf)
            tx_addr = ctypes.addressof(tx_buf)

        rx_buf = ctypes.create_string_buffer(length)
        rx_buffers.append(rx_buf)

        transfers.append(
            SpiIocTransfer(
                tx_buf=tx_addr,
                rx_buf=ctypes.addressof(rx_buf),
                len=length,
                speed_hz=speed_hz,
                delay_usecs=0,
                bits_per_word=8,
                cs_change=0,
                tx_nbits=0,
                rx_nbits=0,
                word_delay_usecs=0,
                pad=0,
            )
        )

    transfer_array = (SpiIocTransfer * len(transfers))(*transfers)
    fcntl.ioctl(fd, spi_ioc_message(len(transfers)), transfer_array)
    return [bytes(rx_buf.raw) for rx_buf in rx_buffers]


def read_register(fd: int, address: int, length: int, wait_bytes: int, speed_hz: int) -> tuple[bytes, bytes, bytes]:
    header = bytes([0x80 | (length - 1), 0xD4, (address >> 8) & 0xFF, address & 0xFF])
    chunks: list[tuple[bytes | None, int]] = [(header, len(header))]

    for _ in range(wait_bytes):
        chunks.append((None, 1))

    chunks.append((None, length))

    rx = transfer(fd, chunks, speed_hz)
    header_rx = rx[0]
    wait_rx = b"".join(rx[1:-1])
    data_rx = rx[-1]
    return header_rx, wait_rx, data_rx


def fmt_bytes(data: bytes) -> str:
    return data.hex(" ") if data else "-"


def fmt_value(data: bytes) -> str:
    if len(data) == 1:
        return f"u8=0x{data[0]:02x}"
    if len(data) == 4:
        return f"le32=0x{int.from_bytes(data, 'little'):08x} be32=0x{int.from_bytes(data, 'big'):08x}"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/spidev3.0")
    parser.add_argument("--speed", type=int, default=1_000_000)
    parser.add_argument("--mode", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--bits", type=int, default=8)
    parser.add_argument("--wait", type=int, default=0, help="number of dummy wait bytes before reading data")
    parser.add_argument("--scan-wait", type=int, default=None, help="scan wait byte counts from 0 through N")
    args = parser.parse_args()

    wait_values = range(args.wait, args.wait + 1)
    if args.scan_wait is not None:
        wait_values = range(0, args.scan_wait + 1)

    fd = os.open(args.device, os.O_RDWR)
    try:
        configure_spi(fd, args.speed, args.mode, args.bits)
        print(f"device={args.device} speed={args.speed} mode=0x{args.mode:x} bits={args.bits}")

        for wait in wait_values:
            print(f"\nwait_bytes={wait}")
            for reg in REGISTERS:
                header_rx, wait_rx, data_rx = read_register(fd, reg.address, reg.length, wait, args.speed)
                print(
                    f"{reg.name:12s} addr=0x{reg.address:04x} "
                    f"header_rx=[{fmt_bytes(header_rx)}] "
                    f"wait_rx=[{fmt_bytes(wait_rx)}] "
                    f"data=[{fmt_bytes(data_rx)}] {fmt_value(data_rx)}"
                )
    finally:
        os.close(fd)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

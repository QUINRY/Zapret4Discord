"""Evaluate the installed packet filter offline; no packets are sent."""
import ctypes
import ipaddress
import json
import os
import pathlib
import socket
import struct
import sys

installed_root = pathlib.Path(os.environ.get('ProgramData', r'C:\ProgramData')) / 'ZapretDiscordOnly'
root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (installed_root if installed_root.exists() else pathlib.Path(__file__).resolve().parent)
scope = json.loads((root / 'scope.json').read_text(encoding='utf-8-sig'))
filter_text = (root / 'discord.filter.txt').read_bytes()
dll = ctypes.WinDLL(str(root / 'runtime' / 'WinDivert.dll'), use_last_error=True)
compile_filter = dll.WinDivertHelperCompileFilter
compile_filter.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_uint)]
compile_filter.restype = ctypes.c_int
error = ctypes.c_char_p()
position = ctypes.c_uint()
if not compile_filter(filter_text, 0, None, 0, ctypes.byref(error), ctypes.byref(position)):
    raise RuntimeError(f'Filter rejected at {position.value}: {error.value!r}')
evaluate = dll.WinDivertHelperEvalFilter
evaluate.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p]
evaluate.restype = ctypes.c_int

def packet(destination, port=443, payload=b'hello', protocol=6):
    target = ipaddress.ip_address(destination)
    source = ipaddress.ip_address('192.0.2.2' if target.version == 4 else '2001:db8::2')
    if protocol == 6:
        transport = struct.pack('!HHLLBBHHH', 55000, port, 1, 1, 0x50, 0x18, 65535, 0, 0) + payload
    else:
        transport = struct.pack('!HHHH', 55000, port, 8 + len(payload), 0) + payload
    if target.version == 4:
        return struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(transport), 1, 0, 64, protocol, 0, source.packed, target.packed) + transport
    return struct.pack('!IHBB16s16s', 6 << 28, len(transport), protocol, 64, source.packed, target.packed) + transport

def matches(destination, port=443, payload=b'hello', protocol=6, interface=None, outbound=True):
    data = packet(destination, port, payload, protocol)
    address = ctypes.create_string_buffer(80)
    flags = ((1 << 17) if outbound else 0) | ((1 << 20) if ':' in destination else 0)
    struct.pack_into('<qIIII', address, 0, 0, flags, 0, interface or scope['InterfaceIndexes'][0], 0)
    buffer = ctypes.create_string_buffer(data)
    return bool(evaluate(filter_text, buffer, len(data), address))

discovery = struct.pack('!HHI', 1, 70, 12345) + bytes(66)
discord_ip = next(address for address in scope['DiscordAddresses'] if ':' not in address)
excluded_interface = next(index for index in range(1, 65536) if index not in scope['InterfaceIndexes'])
cases = [
    ('Discord HTTPS captured', matches(discord_ip)),
    ('Discord discovery captured', matches('8.8.8.8', 50000, discovery, 17)),
    ('Other HTTPS excluded', not matches('1.1.1.1')),
    ('Generic UDP excluded', not matches('8.8.8.8', 50000, b'random', 17)),
    ('STUN excluded', not matches('8.8.8.8', 50000, bytes.fromhex('000100002112a442') + bytes(12), 17)),
    ('UDP 443 excluded', not matches('8.8.8.8', 443, discovery, 17)),
    ('Private network excluded', not matches('10.0.0.1', 50000, discovery, 17)),
    ('IPv6 Discord discovery captured', matches('2606:4700:4700::1111', 50000, discovery, 17)),
    ('Private IPv6 excluded', not matches('fd00::1', 50000, discovery, 17)),
    ('Link-local IPv6 excluded', not matches('fe80::1', 50000, discovery, 17)),
    ('Unlisted adapter TCP excluded', not matches(discord_ip, interface=excluded_interface)),
    ('Unlisted adapter UDP excluded', not matches('8.8.8.8', 50000, discovery, 17, interface=excluded_interface)),
]
for vpn_ip in scope['VpnExcluded']:
    cases.extend([
        ('FortiClient gateway TCP excluded', not matches(vpn_ip)),
        ('FortiClient gateway UDP excluded', not matches(vpn_ip, 50000, discovery, 17)),
    ])
for name, passed in cases:
    print(f'{"PASS" if passed else "FAIL"}: {name}')
if not all(passed for _, passed in cases):
    raise SystemExit(1)
print(f'{len(cases)} offline filter checks passed.')

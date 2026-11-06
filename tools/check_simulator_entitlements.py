"""检查模拟器程序每个架构中实际使用的钥匙串授权。"""

import argparse
import json
import plistlib
import struct
from pathlib import Path


def architecture_slices(binary):
    if binary[:4] == bytes.fromhex("cafebabe"):
        count = struct.unpack_from(">I", binary, 4)[0]
        for index in range(count):
            cpu, _, offset, size, _ = struct.unpack_from(">IIIII", binary, 8 + index * 20)
            yield cpu, binary[offset:offset + size]
    else:
        yield struct.unpack_from("<I", binary, 4)[0], binary


def simulated_entitlements(binary):
    if binary[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("模拟器程序必须为 64 位 Mach-O 格式")
    offset = 32
    command_count = struct.unpack_from("<I", binary, 16)[0]
    for _ in range(command_count):
        command, size = struct.unpack_from("<II", binary, offset)
        if command == 0x19:
            section_count = struct.unpack_from("<I", binary, offset + 64)[0]
            for index in range(section_count):
                section = offset + 72 + index * 80
                name = binary[section:section + 16].rstrip(b"\0")
                segment = binary[section + 16:section + 32].rstrip(b"\0")
                if name == b"__entitlements" and segment == b"__TEXT":
                    length = struct.unpack_from("<Q", binary, section + 40)[0]
                    start = struct.unpack_from("<I", binary, section + 48)[0]
                    return plistlib.loads(binary[start:start + length].rstrip(b"\0"))
        offset += size
    raise ValueError("模拟器主程序缺少实际运行所需的授权段")


def check_binary(binary, bundle_identifier):
    expected = "SIMULATOR." + bundle_identifier
    architectures = []
    entitlements = None
    for cpu, content in architecture_slices(binary):
        value = simulated_entitlements(content)
        if value.get("application-identifier") != expected:
            raise ValueError("模拟器应用身份与预期不一致")
        if expected not in value.get("keychain-access-groups", []):
            raise ValueError("模拟器缺少本应用的钥匙串访问组")
        if entitlements is not None and value != entitlements:
            raise ValueError("不同架构的模拟器授权不一致")
        entitlements = value
        architectures.append(cpu)
    if 0x100000C not in architectures:
        raise ValueError("模拟器包必须支持 ARM64")
    return architectures, entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    info = plistlib.loads((arguments.app / "Info.plist").read_bytes())
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise ValueError("只检查 iOS 模拟器应用，不处理真机签名")
    binary = (arguments.app / info["CFBundleExecutable"]).read_bytes()
    architectures, entitlements = check_binary(binary, info["CFBundleIdentifier"])
    if arguments.output:
        arguments.output.write_bytes(plistlib.dumps(entitlements))
    print(json.dumps({"授权检查": "通过", "架构": [hex(value) for value in architectures],
                      "应用身份": entitlements["application-identifier"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()

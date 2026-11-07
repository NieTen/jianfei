"""静态检查 IPA 中的 HealthKit 签名授权及描述文件，可在 Windows 运行。"""

import argparse
import fnmatch
import json
import plistlib
import struct
import zipfile
from pathlib import Path


HEALTH_KEY = "com.apple.developer.healthkit"


def architecture_slices(binary):
    magic = binary[:4]
    if magic in (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
        wide = magic == bytes.fromhex("cafebabf")
        count = struct.unpack_from(">I", binary, 4)[0]
        for index in range(count):
            row = struct.unpack_from(">IIQQII" if wide else ">IIIII", binary, 8 + index * (32 if wide else 20))
            offset, size = row[2], row[3]
            if offset + size > len(binary):
                raise ValueError("程序架构范围无效")
            yield binary[offset:offset + size]
    else:
        yield binary


def signed_entitlements(binary):
    magic = binary[:4]
    if magic not in (bytes.fromhex("cffaedfe"), bytes.fromhex("cefaedfe")):
        raise ValueError("不支持的 Mach-O 格式")
    offset = 32 if magic == bytes.fromhex("cffaedfe") else 28
    command_count = struct.unpack_from("<I", binary, 16)[0]
    for _ in range(command_count):
        command, size = struct.unpack_from("<II", binary, offset)
        if size < 8 or offset + size > len(binary):
            raise ValueError("程序加载命令无效")
        if command == 0x1D:
            start, length = struct.unpack_from("<II", binary, offset + 8)
            if start + length > len(binary):
                raise ValueError("签名范围无效")
            signature = binary[start:start + length]
            marker, total, count = struct.unpack_from(">III", signature)
            if marker != 0xFADE0CC0 or total > len(signature):
                raise ValueError("签名数据无效")
            for index in range(count):
                slot, location = struct.unpack_from(">II", signature, 12 + index * 8)
                if slot == 5:
                    kind, blob_size = struct.unpack_from(">II", signature, location)
                    if kind != 0xFADE7171 or location + blob_size > total:
                        raise ValueError("签名授权数据无效")
                    return plistlib.loads(signature[location + 8:location + blob_size])
            raise ValueError("签名没有可读取的 XML 授权声明")
        offset += size
    raise ValueError("主程序没有代码签名，重签名工具可能无法取得 HealthKit 声明")


def profile_payload(data):
    # 只读取 CMS 内的公开描述信息，不把这项静态检查当作 Apple 证书链验证。
    start = data.find(b"<?xml")
    end = data.find(b"</plist>", start)
    if start < 0 or end < 0:
        raise ValueError("无法读取描述文件")
    return plistlib.loads(data[start:end + len(b"</plist>")])


def check_ipa(path, allow_prepared=False):
    targets = []
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA 完整性校验失败")
        names = set(archive.namelist())
        for prefix in ["Payload/BingJian.app/", "Payload/BingJian.app/Watch/BingJianWatch.app/"]:
            info = plistlib.loads(archive.read(prefix + "Info.plist"))
            executable = archive.read(prefix + info["CFBundleExecutable"])
            entitlements = [signed_entitlements(value) for value in architecture_slices(executable)]
            if not entitlements or not all(value.get(HEALTH_KEY) is True for value in entitlements):
                raise ValueError(info["CFBundleName"] + " 的实际签名缺少 HealthKit 授权")
            profile_path = prefix + "embedded.mobileprovision"
            has_profile = profile_path in names
            if has_profile:
                profile = profile_payload(archive.read(profile_path))["Entitlements"]
                if profile.get(HEALTH_KEY) is not True:
                    raise ValueError(info["CFBundleName"] + " 的描述文件没有允许 HealthKit")
                for value in entitlements:
                    identity = value.get("application-identifier", "")
                    if not identity.endswith("." + info["CFBundleIdentifier"]) or not fnmatch.fnmatchcase(identity, profile.get("application-identifier", "")):
                        raise ValueError("签名、描述文件和应用标识不一致")
            elif not allow_prepared:
                raise ValueError(info["CFBundleName"] + " 尚无个人描述文件，请检查重签名后的 IPA")
            targets.append({"应用": info["CFBundleName"], "架构数": len(entitlements), "HealthKit声明": True, "含个人描述文件": has_profile})
    return {"检查": "通过", "范围": "签名授权静态检查，不验证 Apple 证书链或真机运行", "目标": targets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--allow-prepared", action="store_true", help="允许尚未加入个人描述文件的重签名准备包")
    args = parser.parse_args()
    try:
        print(json.dumps(check_ipa(args.ipa, args.allow_prepared), ensure_ascii=False))
    except (ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit("HealthKit 检查失败：" + str(error))


if __name__ == "__main__":
    main()

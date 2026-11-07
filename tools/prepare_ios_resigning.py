"""为待重签名的 iPhone 与 Watch 应用保留 HealthKit 权限声明。"""

import argparse
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    targets = [
        (args.app / "Watch" / "BingJianWatch.app", root / "ios/BingJianWatch/BingJianWatch.entitlements"),
        (args.app, root / "ios/BingJian/Resigning.entitlements"),
    ]
    for target, entitlements in targets:
        if not target.is_dir() or not entitlements.is_file():
            raise SystemExit("应用或 HealthKit 授权声明不存在")
        # 临时签名只是携带权限声明；安装时仍需个人签名和 Apple 签发的描述文件。
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der",
                        "--entitlements", str(entitlements), str(target)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(target)], check=True)
    print("iPhone 与 Watch 已保留重签名所需的 HealthKit 声明，仍须个人签名安装")


if __name__ == "__main__":
    main()

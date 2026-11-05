#!/usr/bin/env python3
"""
Inzx APK Stripper Script
Strips unneeded ABI native libraries (.so) and signature files from a Universal APK
to produce lightweight single-architecture APKs (arm64-v8a, armeabi-v7a, x86_64).

Usage:
    python3 tool/strip_apk.py <input_universal.apk> <output_stripped.apk> <abi_to_keep>

Examples:
    python3 tool/strip_apk.py app-universal-release.apk app-arm64-v8a-release.apk arm64-v8a
    python3 tool/strip_apk.py app-universal-release.apk app-armeabi-v7a-release.apk armeabi-v7a
    python3 tool/strip_apk.py app-universal-release.apk app-x86_64-release.apk x86_64
"""

import sys
import os
import zipfile

VALID_ABIS = {'arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'}

def print_banner():
    print("\033[1;36m=== Inzx APK Stripper ===\033[0m\n")

def parse_args():
    if len(sys.argv) < 4:
        print("\033[1;31mError: Missing required arguments.\033[0m\n")
        print("Usage:")
        print("  python3 strip_apk.py <input.apk> <output.apk> <abi_to_keep>\n")
        print("Examples:")
        print("  python3 strip_apk.py universal.apk inzx-arm64-v8a.apk arm64-v8a")
        print("  python3 strip_apk.py universal.apk inzx-armeabi-v7a.apk armeabi-v7a")
        print("  python3 strip_apk.py universal.apk inzx-x86_64.apk x86_64\n")
        sys.exit(1)

    in_apk = sys.argv[1]
    out_apk = sys.argv[2]
    abi_to_keep = sys.argv[3].lower()

    if not os.path.isfile(in_apk):
        print(f"\033[1;31mError: Input APK '{in_apk}' does not exist.\033[0m")
        sys.exit(1)

    if abi_to_keep not in VALID_ABIS:
        print(f"\033[1;33mWarning: '{abi_to_keep}' is not in standard ABI list {VALID_ABIS}\033[0m")

    return in_apk, out_apk, abi_to_keep

def should_keep(filename, abi_to_keep):
    # Remove old signature files (META-INF/*.SF, *.RSA, *.DSA, *.MF)
    if filename.startswith('META-INF/'):
        if (filename.endswith('.SF') or 
            filename.endswith('.RSA') or 
            filename.endswith('.DSA') or 
            filename.endswith('.MF')):
            return False

    # Filter native library folders under lib/
    if filename.startswith('lib/'):
        # Only keep the specified ABI folder in lib/
        if not filename.startswith(f'lib/{abi_to_keep}/'):
            return False

    return True

def strip_apk(in_apk, out_apk, abi_to_keep):
    print(f"\033[1;33mInput APK:\033[0m  {in_apk}")
    print(f"\033[1;33mOutput APK:\033[0m {out_apk}")
    print(f"\033[1;33mKeeping ABI:\033[0m  {abi_to_keep}\n")

    input_size = os.path.getsize(in_apk) / (1024 * 1024)
    print(f"Reading input APK ({input_size:.2f} MB)...")

    kept_count = 0
    removed_count = 0

    with zipfile.ZipFile(in_apk, 'r') as zin:
        with zipfile.ZipFile(out_apk, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                if should_keep(item.filename, abi_to_keep):
                    # Native libs and resources.arsc MUST use ZIP_STORED (method 0)
                    # because extractNativeLibs=false requires the loader to mmap
                    # them directly from the APK. zipalign then page-aligns them.
                    if item.filename.startswith('lib/') or item.filename == 'resources.arsc':
                        item.compress_type = zipfile.ZIP_STORED
                    data = zin.read(item.filename)
                    zout.writestr(item, data)
                    kept_count += 1
                else:
                    removed_count += 1

    output_size = os.path.getsize(out_apk) / (1024 * 1024)
    saved_size = input_size - output_size

    print(f"\n\033[1;32mSuccessfully stripped APK!\033[0m")
    print(f"  - Kept files:     {kept_count}")
    print(f"  - Removed files:  {removed_count}")
    print(f"  - Original size:  {input_size:.2f} MB")
    print(f"  - Stripped size:  {output_size:.2f} MB")
    print(f"  - Reduced by:     {saved_size:.2f} MB ({(saved_size / input_size) * 100:.1f}% smaller)\n")

def main():
    print_banner()
    in_apk, out_apk, abi_to_keep = parse_args()
    strip_apk(in_apk, out_apk, abi_to_keep)

if __name__ == '__main__':
    main()

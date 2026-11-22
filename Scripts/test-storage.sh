#!/bin/bash
# Settings ▸ Storage (Apelind/Session/Storage/StorageKeeper): what each area of
# the data folder costs, what an area that is absent or replaced by a link
# answers, which folders an emptying leaves alone, which areas it refuses, and
# what `busy` calls busy.
#
# The walk and the removal are the code the host runs. On a Mac and in CI the
# script compiles the same sources with the same rewrite; on the device there
# is no `swift build`, so every source they reach is copied into one scratch
# module exactly as test-file-browser.sh does: package imports go and Swift 6's
# trailing comma goes (the device's swiftc is 5.7).
#
# Mac:    bash Scripts/test-storage.sh
# Device: bash Scripts/test-storage.sh --device <tool.entitlements>
set -euo pipefail

# The path the toolchain can open: on roothide `pwd -P` answers `/rootfs/…`,
# and the compilers cannot write there.
root="$(cd "$(dirname "$0")/.." && pwd -P)"
root="${root#/rootfs}"
cd "$root"

compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

mkdir -p build
work="$(mktemp -d build/storage-checks.XXXXXX)"
mkdir -p "$work/tmp"
# The checks make their scratch folders from NSTemporaryDirectory, so TMPDIR
# points at this run's own folder, handed over as the real absolute path.
export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT

mapfile -t sources < <(
    ls Packages/ApelinKit/Sources/ApelinCore/*.swift
    ls Packages/ApelinKit/Sources/ApelinProtocol/*.swift
    find Packages/ApelinKit/Sources/ApelinProtocol -mindepth 2 -name '*.swift' | sort
    echo Apelind/Session/Storage/StorageKeeper.swift
    echo Tests/Storage/StorageChecks.swift
)

python3 - "$work" "${sources[@]}" <<'PY'
import os
import re
import sys

work = sys.argv[1]
seen = set()
files = []
for path in sys.argv[2:]:
    if path in seen:
        continue
    seen.add(path)
    name = path.replace("/", "__")
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"^import (ApelinCore|ApelinProtocol)\n", "", text, flags=re.M)
    text = text.replace("compactMap(\\.self)", "compactMap { $0 }")
    text = re.sub(r",(\s*[\)\]\}])", r"\1", text)
    target = os.path.join(work, name)
    open(target, "w", encoding="utf-8").write(text)
    files.append(target)
open(os.path.join(work, "files.txt"), "w").write("\n".join(files))
PY

"${compiler[@]}" -swift-version 5 -Onone -parse-as-library \
    -o "$work/storage-checks" $(<"$work/files.txt")
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/storage-checks"
fi
"$work/storage-checks"

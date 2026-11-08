#!/bin/zsh
# Copies the Windows sources to the test laptop (D:\snowdrift\src) and builds there.
set -e
cd "$(dirname "$0")"
ssh -o BatchMode=yes tuf 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force D:\snowdrift\src\src,D:\snowdrift\src\assets | Out-Null"' 2>/dev/null
scp -q -o BatchMode=yes Cargo.toml build.rs build.ps1 tuf:D:/snowdrift/src/
scp -q -o BatchMode=yes src/*.rs tuf:D:/snowdrift/src/src/
scp -q -o BatchMode=yes assets/* tuf:D:/snowdrift/src/assets/
ssh -o BatchMode=yes tuf 'powershell -NoProfile -ExecutionPolicy Bypass -File D:\snowdrift\src\build.ps1' 2>&1 | grep -v -E "post-quantum|store now|upgraded"

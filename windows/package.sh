#!/bin/zsh
# After ./sync.sh: puts the built exe in a clean folder on the laptop (D:\snowdrift\Snowdrift, for
# trying it at the desk) and zips it here as dist/Snowdrift-windows-<version>.zip.
set -e
cd "$(dirname "$0")"
version=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)
ssh -o BatchMode=yes tuf 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force D:\snowdrift\Snowdrift | Out-Null; Copy-Item D:\snowdrift\target\release\snowdrift.exe D:\snowdrift\Snowdrift\Snowdrift.exe -Force"' 2>/dev/null \
  || echo "note: D:\\snowdrift\\Snowdrift\\Snowdrift.exe is running, left as is (quit it and rerun to update it)"

rm -rf dist && mkdir -p dist/Snowdrift
scp -q -o BatchMode=yes tuf:D:/snowdrift/target/release/snowdrift.exe dist/Snowdrift/Snowdrift.exe
(cd dist && zip -qr "Snowdrift-windows-$version.zip" Snowdrift)
ls -l dist/*.zip

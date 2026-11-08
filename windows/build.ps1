# Builds Snowdrift on the test laptop. Everything stays in D:\snowdrift (toolchain, Cargo cache, build output);
# PATH is changed for this PowerShell process only.
$ErrorActionPreference = 'Stop'
$env:PATH = "D:\snowdrift\rust\bin;$env:PATH"
$env:CARGO_HOME = 'D:\snowdrift\cargo-home'
$env:CARGO_TARGET_DIR = 'D:\snowdrift\target'
Set-Location 'D:\snowdrift\src'
cargo build --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

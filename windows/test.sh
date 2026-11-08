#!/bin/zsh
# Runs the headless checks on the test laptop (after ./sync.sh). PowerShell, because cmd doesn't wait
# for a GUI-subsystem exe or show its output; piping makes it do both.
cd "$(dirname "$0")"
ssh -o BatchMode=yes tuf 'powershell -NoProfile -Command "cd D:\snowdrift; $e=\".\target\release\snowdrift.exe\"; $bad=0; & $e --selftest | Out-String; $bad+=$LASTEXITCODE; & $e --track-test | Out-String; $bad+=$LASTEXITCODE; & $e --render-test D:\snowdrift\render.bmp | Out-String; $bad+=$LASTEXITCODE; if ($bad) { \"FAILED\" } else { \"all checks passed\" }"' 2>&1 | grep -v -E "post-quantum|store now|upgraded"

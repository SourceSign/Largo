#!/bin/zsh
# Builds Largo/LargoDemo.m4a, the demo song shipped with the app (all sounds synthesized, royalty-free).
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
python3 Design/make-demo-song.py "$tmp/demo.wav"
swift Design/tag-audio.swift "$tmp/demo.wav" Largo/LargoDemo.m4a "Largo Demo" "Largo" \
    Largo/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png
rm -rf "$tmp"

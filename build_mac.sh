#!/bin/bash

cd "$(dirname "$0")"

odin run ./sauce/build -file -- target:mac && ./build/mac_debug/game.exe && rm build.bin

#!/bin/zsh
cd -- "${0:A:h}"
if [[ ! -d build/Citadel.app ]]; then
    ./scripts/build-app.sh
fi
open build/Citadel.app

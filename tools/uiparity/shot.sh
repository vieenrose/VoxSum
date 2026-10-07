#!/bin/bash
# Real-iPhone screenshot via the Mac: tools/uiparity/shot.sh out.png   (needs ~/.kc on the Mac; device = iPhone 14 Pro Max)
set -e
M=prime_rd3@100.121.162.68; D=437D2454-02D7-538A-8308-DB7E18D86161
ssh $M 'security unlock-keychain -p "$(cat ~/.kc)" ~/Library/Keychains/login.keychain-db; xcrun devicectl device capture screenshot --device '$D' --destination ~/shot.png >/dev/null'
scp -q $M:shot.png "${1:-shot.png}"

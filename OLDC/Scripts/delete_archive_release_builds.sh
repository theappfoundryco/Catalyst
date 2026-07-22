rm -rf ~/Desktop/Catalyst/build/Catalyst.xcarchive \
       ~/Desktop/Catalyst/build/export \
       ~/Desktop/Catalyst/build/Catalyst.dmg
rm -rf ~/Desktop/Catalyst/build
rm -rf ~/Library/Developer/Xcode/DerivedData/Catalyst-*
rm -rf ~/Desktop/Catalyst/build
find ~/Library/Developer/Xcode/Archives -maxdepth 2 -name 'Catalyst *.xcarchive' -exec rm -rf {} +
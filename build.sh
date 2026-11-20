#!/bin/zsh
set -eu

if [[ $# -ne 1 || "$1" != /* || "$1" != *.app || -e "$1" || -L "$1" || ! -d "${1:h}" ]]; then
  print -u2 'Usage: zsh build.sh /absolute/path/to/GCP\ Billing\ Meter.app'
  print -u2 'The destination must be new and its parent directory must exist.'
  exit 64
fi

source_directory=${0:A:h}
destination=$1
staging=$(/usr/bin/mktemp -d "${destination:h}/.gcp-billing-meter-build.XXXXXXXX")
trap '/bin/rm -rf -- "$staging"' EXIT
bundle="$staging/${destination:t}"
executable="$bundle/Contents/MacOS/GCPBillingMeter"
resources="$bundle/Contents/Resources"
iconset="$staging/GCPBillingMeter.iconset"
sources=("$source_directory"/Sources/*.swift)

/bin/mkdir -p "$bundle/Contents/MacOS" "$resources" "$iconset"
/bin/cp "$source_directory/Sources/Info.plist" "$bundle/Contents/Info.plist"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source_directory/Assets/app-icon.png" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  pixels=$((size * 2))
  /usr/bin/sips -z "$pixels" "$pixels" "$source_directory/Assets/app-icon.png" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$resources/GCPBillingMeter.icns"

compile_meter() {
  /usr/bin/swiftc -O -swift-version 5 -target "$1-apple-macosx14.0" "${sources[@]}" -o "$2"
}

if [[ ${GCP_BILLING_METER_UNIVERSAL:-0} == 1 ]]; then
  compile_meter arm64 "$staging/GCPBillingMeter-arm64"
  compile_meter x86_64 "$staging/GCPBillingMeter-x86_64"
  /usr/bin/lipo -create "$staging/GCPBillingMeter-arm64" "$staging/GCPBillingMeter-x86_64" -output "$executable"
else
  compile_meter "$(/usr/bin/uname -m)" "$executable"
fi

/usr/bin/codesign --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/bin/mv -n "$bundle" "${destination:h}/"
if [[ -e "$bundle" ]]; then
  print -u2 'The destination appeared during the build. Choose a new output path.'
  exit 73
fi

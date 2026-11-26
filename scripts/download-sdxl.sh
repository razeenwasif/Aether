#!/bin/zsh
# Downloads Apple's 4.5-bit palettized SDXL base (Core ML, compiled for
# Swift) into Photon's Models folder: only the compiled files, 3.36 GB, each
# checked against its published size. Into a .partial folder first, renamed
# when every file is there, so a half-done download is never taken for a
# model. Run again to finish one that stopped.
#
# The app's own download (the flow inspector's Runs on section) does the
# same; this is for doing it from a shell.
set -euo pipefail

BASE="https://huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization/resolve/main/coreml-stable-diffusion-xl-base_mbp_4_50_palettized/compiled"
MODELS="$HOME/Library/Application Support/Photon/Models"
NAME="SDXL base (4.5-bit)"
DEST="$MODELS/$NAME"
PART="$DEST.partial"

if [[ -d "$DEST" ]]; then
  echo "already installed: $DEST"
  exit 0
fi
mkdir -p "$PART"

# path, size in bytes
FILES=(
  "TextEncoder.mlmodelc/analytics/coremldata.bin" 207
  "TextEncoder.mlmodelc/coremldata.bin" 825
  "TextEncoder.mlmodelc/metadata.json" 2710
  "TextEncoder.mlmodelc/model.mil" 188382
  "TextEncoder.mlmodelc/weights/weight.bin" 246145536
  "TextEncoder2.mlmodelc/analytics/coremldata.bin" 207
  "TextEncoder2.mlmodelc/coremldata.bin" 825
  "TextEncoder2.mlmodelc/metadata.json" 2711
  "TextEncoder2.mlmodelc/model.mil" 491456
  "TextEncoder2.mlmodelc/weights/weight.bin" 1389367424
  "Unet.mlmodelc/analytics/coremldata.bin" 243
  "Unet.mlmodelc/coremldata.bin" 1338
  "Unet.mlmodelc/metadata.json" 4431
  "Unet.mlmodelc/model.mil" 2491351
  "Unet.mlmodelc/weights/weight.bin" 1450049728
  "VAEDecoder.mlmodelc/analytics/coremldata.bin" 207
  "VAEDecoder.mlmodelc/coremldata.bin" 773
  "VAEDecoder.mlmodelc/metadata.json" 2467
  "VAEDecoder.mlmodelc/model.mil" 168425
  "VAEDecoder.mlmodelc/weights/weight.bin" 197977216
  "VAEEncoder.mlmodelc/analytics/coremldata.bin" 207
  "VAEEncoder.mlmodelc/coremldata.bin" 783
  "VAEEncoder.mlmodelc/metadata.json" 2494
  "VAEEncoder.mlmodelc/model.mil" 138263
  "VAEEncoder.mlmodelc/weights/weight.bin" 68338112
  "merges.txt" 524657
  "vocab.json" 862328
)

for ((i = 1; i <= ${#FILES}; i += 2)); do
  file=${FILES[i]}
  size=${FILES[i+1]}
  out="$PART/$file"
  if [[ -f "$out" && $(stat -f %z "$out") == "$size" ]]; then
    continue
  fi
  mkdir -p "$(dirname "$out")"
  echo "fetching $file ($size bytes)"
  curl -fL --retry 5 --retry-delay 3 -C - -o "$out" "$BASE/$file"
  got=$(stat -f %z "$out")
  if [[ "$got" != "$size" ]]; then
    echo "size mismatch for $file: $got, expected $size" >&2
    exit 1
  fi
done

cat > "$PART/photon-model.json" <<'JSON'
{
  "name": "SDXL base (4.5-bit)",
  "answersTo": ["sd_xl_base_1.0.safetensors", "sd_xl_base_1.0_0.9vae.safetensors"],
  "source": "huggingface.co/apple/coreml-stable-diffusion-mixed-bit-palettization, coreml-stable-diffusion-xl-base_mbp_4_50_palettized/compiled"
}
JSON
mv "$PART" "$DEST"
echo "installed: $DEST"

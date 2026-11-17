#!/bin/bash
# Downloads official inference weights locally; never sends notes or starts training.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$root/JIBIJI/Recognition/PaddleModels"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$destination"
base="https://huggingface.co/PaddlePaddle"
# Pinned source revisions are recorded below so the model pack is reproducible.
for entry in 'det JibijiTextDetection' 'rec JibijiTextRecognition'; do
  read -r kind name <<< "$entry"
  # Use revisions stored in the checked-in pack manifest, not the moving main branch.
  revision="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["revision"])' "$root/scripts/paddle-model-pack.json" "$kind")"
  url="$base/PP-OCRv6_small_${kind}_onnx/resolve/$revision"
  curl --fail --location --retry 2 "$url/inference.onnx" -o "$work/$name.onnx"
  if [[ "$kind" == rec ]]; then
    curl --fail --location --retry 2 "$url/inference.yml" -o "$work/recognition.yml"
    /usr/bin/ruby -ryaml -rjson -e 's=YAML.safe_load(File.read(ARGV[0]), aliases: true); File.write(ARGV[1],JSON.generate(s.fetch("PostProcess").fetch("character_dict")))' "$work/recognition.yml" "$work/JibijiTextDictionary.json"
  fi
  /usr/bin/python3 -c 'import hashlib,json,sys; expected=json.load(open(sys.argv[1]))[sys.argv[2]]["sha256"]; actual=hashlib.sha256(open(sys.argv[3],"rb").read()).hexdigest(); assert actual==expected,"Model checksum mismatch"' "$root/scripts/paddle-model-pack.json" "$kind" "$work/$name.onnx"
done
/usr/bin/python3 -c 'import hashlib,json,sys; expected=json.load(open(sys.argv[1]))["rec"]["dictionary_sha256"]; actual=hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest(); assert actual==expected,"Dictionary checksum mismatch"' "$root/scripts/paddle-model-pack.json" "$work/JibijiTextDictionary.json"
cp "$work/JibijiTextDetection.onnx" "$destination/"
cp "$work/JibijiTextRecognition.onnx" "$destination/"
cp "$work/JibijiTextDictionary.json" "$destination/"
echo 'PaddleOCR v6 Small model pack installed. Rebuild JIBIJI.'

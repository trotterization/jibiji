# Pick up JIBIJI with Claude Code

Feature scope is frozen. The work now is to stabilize existing behavior, then polish the UI. The app already exists, so don't start a new prototype.

1. Open Xcode once on your Mac. Clone this repository or pull the latest main (or the branch you were handed).
2. Open Claude Code in the repo folder. Run /memory and confirm CLAUDE.md is listed.
3. Get one assigned stabilization task (an issue or PR) and paste the prompt below. Give Claude normal tool approvals for the task branch and a draft PR as needed.

> Read CLAUDE.md and START-HERE.md, then the current repo state and my assigned issue or PR: <link>. Do only that one stabilization task, on one branch and one PR. Add no features. Report simulator and physical iPad results separately. Stop before merging.

The first shared objective, a physical-iPad end-to-end run, is in [CLAUDE.md](CLAUDE.md).

## Optional local recognition models

The Pinyin OCR models are not in the repo (gitignored). The app builds and runs without them. Without them, the optional Paddle features, which exist in Debug builds only, report the model as missing. Ordinary suggestions keep using PencilKit, which is less accurate on tone marks. Vision is a separate manual diagnostic and isn't a fallback.

To enable them, put these files in `JIBIJI/Recognition/` with exactly these names:

- `PinyinRecognition.onnx` and `PinyinRecognitionDictionary.json` (PP-OCRv5 server)
- `PinyinMobileRecognition.onnx` and `PinyinMobileRecognitionDictionary.json` (PP-OCRv5 mobile)

Official sources (each lists `inference.onnx` and `inference.yml`):

- Mobile: https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_rec_onnx/tree/main
- Server: https://huggingface.co/PaddlePaddle/PP-OCRv5_server_rec_onnx/tree/main

Rename `inference.onnx` to the model name above. For each dictionary, export the YAML's `PostProcess.character_dict` as a JSON array in its original order (details in [docs/prototype/M0-first-prototype.md](docs/prototype/M0-first-prototype.md)). Don't commit these files.

To run on your own iPad, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your own Team ID and bundle ID prefix.

See [CLAUDE.md](CLAUDE.md) for the product and team instructions.

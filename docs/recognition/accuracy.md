# Handwriting accuracy work

## Current implementation and evidence

The simulator lacks Simplified Chinese stroke recognition. The fallback reads local ink regions using Vision and, in Debug builds with the optional mobile model installed, PaddleOCR. Neither service uploads the note. Original ink is preserved.

The PP-OCRv5 mobile output dictionary contains 18,383 entries, including Chinese, Latin text, and symbols. This is output coverage, not an accuracy measurement. Suggestions are no longer limited to the seven-entry meanings dictionary: uncertain readings can be reviewed and edited directly.

The decoder now retains five CTC prefix beams instead of using only greedy decoding. Blank paths and repeated symbols are accumulated in log probability space. These alternatives come from model output, not a hardcoded list of expected characters. Candidate correctness remains unverified until the student confirms it.

Local comparisons used the user's saved ink, kept in the gitignored replay file. PP-OCRv5 server and PP-OCRv6 medium were also tested; neither consistently resolved the difficult regions. They were not substituted into the app simply because they were larger or newer. Beam decoding recovered 牛 as an alternative in one region where greedy decoding returned 年牛. 我 remains unresolved. This small sample is a regression example, not a representative accuracy benchmark.

The optional models and the user's original ink are not committed. Follow START-HERE for the local v5 model setup. Recognition remains an early prototype, including Debug-only Paddle integration.

## Broad-coverage training route

Use handwriting samples with explicit character labels and writer identities. Random literature scans and handwriting fonts are not a substitute for labeled human handwriting. Font renders may supplement training but must not be reported as human-handwriting accuracy.

CASIA-HWDB and CASIA-OLHWDB provide roughly 3.9 million isolated samples over 7,356 classes (7,185 Chinese characters plus symbols) per offline/online collection, plus handwritten text data. The online trajectories are particularly relevant to PencilKit input. The free terms are academic research only; obtain commercial rights before using these data to train Jibiji's product model. No CASIA data have been downloaded or used in training here.

1. Secure dataset rights and record permitted uses, sources, hashes, writer IDs, character coverage, and exclusions in a data manifest.
2. Hold out entire writers for validation and testing. Keep the user's regression ink separate; never train on it and then report it as held-out accuracy.
3. Establish baseline character error rate for continuous text, top-1 and top-5 accuracy for isolated characters, and cold/warm p50/p95 latency. Report Simplified Chinese, Traditional Chinese, pinyin tones, and English separately.
4. Fine-tune a pretrained broad-coverage recognizer, rather than training millions of samples from scratch on the user's Mac. Use licensed writer variations and realistic thin-pen, scale, slant, and spacing augmentation. Evaluate trajectory-aware models alongside image recognition because PencilKit retains stroke order.
5. Validate uncommon characters using an explicit coverage list. A large output alphabet does not establish that every Han character is supported, and an unseen class cannot be recovered by adding more samples of common classes.
6. Export the best checkpoint for on-device inference, benchmark on a physical iPad, and compare to the baseline before replacing the model. Retain alternatives and uncertainty instead of silently modifying handwriting.

Training has not been run. Remaining prerequisites are commercially usable labeled data, a training environment with sufficient compute, and a held-out evaluation set. No paid compute has been provisioned.

## Sources

- CASIA dataset and counts: https://nlpr.ia.ac.cn/databases/handwriting/home.html
- CASIA use conditions: https://www.nlpr.ia.ac.cn/databases/handwriting/Application_form.html
- Online stroke data: https://nlpr.ia.ac.cn/databases/handwriting/Online_database.html
- PP-OCRv5 model and handwriting description: https://www.paddleocr.ai/v3.0.0/en/version3.x/algorithm/PP-OCRv5/PP-OCRv5.html
- PP-OCRv6 model: https://huggingface.co/PaddlePaddle/PP-OCRv6_medium_rec_onnx

## Local checks

Run the JIBIJITests target, including the exhaustive CTC decoder comparison and repeat/blank handling checks. The opt-in production replay test compares local recognizers when JIBIJITests/LocalPinyinReplay.drawing exists; that file is gitignored. Do not commit personal classroom notes or embed them in public test output.

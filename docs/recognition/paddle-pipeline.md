# PaddleOCR v6 Small integration preview

## Running it

1. Run `scripts/setup-paddle-models.sh` on the Mac. It fetches the official v6 Small detection and recognition ONNX models plus the recognition dictionary. Weight revisions and SHA-256 hashes are pinned in `scripts/paddle-model-pack.json`. Notes never leave the device.
2. Build the JIBIJI Xcode scheme. Models are local, gitignored resources; they are not committed to this public repository.
3. Open a notebook page, then **Check recognition**. In the **PaddleOCR v6 · on-device preview** section, tap **Compare v6 reading**.
4. The optional **Use v6 for suggestions and cards** switch routes both consumers through the new pipeline. Leave it off to keep the existing automatic reader. The cover, original strokes, and existing annotations are unchanged.

The preview remains opt-in because it has not demonstrated a consistent accuracy improvement on the local handwritten replay. A larger language list is not proof of accurate handwriting recognition.

## Implementation

`PaddleTextPipeline` implements local image rendering, model-configured BGR normalization, text detection, DB thresholding, contours, minimum-area oriented rectangles, expansion, perspective-corrected crops, and CTC text recognition. It preserves the mapping from image boxes to page coordinates and returns provisional readings. Low-scoring recognition results are omitted. Sessions and unchanged-page results are reused. A missing pack or inference failure is surfaced as a recoverable error without changing ink.

Apple Vision provides contour extraction and Core Image provides perspective correction. This avoids the upstream demo's OpenCV dependency. The native rectangle expansion is an adaptation of DB postprocessing, not a claim of bit-for-bit parity with the upstream OpenCV/Clipper implementation. The recognition output currently uses greedy CTC decoding with mean character scores, rather than the older optional mobile reader's five-beam decoding. Its scores are model scores, not calibrated probabilities of correctness.

Default parameters match the downloaded detector config: threshold 0.2, box threshold 0.45, unclip ratio 1.4, and a maximum of 3,000 contours. Recognition uses 48-pixel-high inputs with normalized zero padding. ONNX Runtime uses two CPU threads. Core ML acceleration and physical-iPad performance have not been validated.

## Evidence and limits

- Native v6 model loading and recognition passed a synthetic Chinese ink check; the sample was read as 大人.
- The local saved handwriting replay returned 大, 人, and a wrong reading 半 in one observed run, about 1.28 seconds including fresh pipeline setup. Other written regions were missed. This is one regression sample, not a broad accuracy claim or a controlled latency benchmark.
- Replay files and image artifacts remain local and gitignored. They are not training data or held-out population-level benchmarks.
- A later manual check on the updated notebook page returned 大、人、牛 among mixed results in approximately 2.38 seconds. This was a different page revision, so it is not a controlled comparison against the earlier replay. 我 was still not reliably recognized.
- Debug and Release simulator builds passed. The 104 logic tests passed with one existing known simulator Chinese-support issue; the cover and pipeline comparison UI tests passed.
- The official iOS demo built for the Intel simulator after overriding obsolete dependency deployment targets. Its OpenCV dependency excludes arm64 simulator builds, and this Mac's installed runtime did not accept its Intel test destination. Therefore no upstream-demo replay accuracy result was obtained. The reported replay above is the native Jibiji adaptation.
- Automated tests check detector-box expansion, oriented geometry, BGR normalization and padding, CTC blank/repeat behavior, model execution, page coordinates, and unchanged-page caching. A UI test checks access to the comparison without enabling it globally.
- Default recognition is deliberately unchanged. Native-provider coverage, real handwriting accuracy, rotated/vertical writing, peak memory, cancellation during long inference, and physical-iPad latency still need broader validation before promoting this preview.

## Official sources and licenses

- Current iOS deployment: https://www.paddleocr.ai/main/en/version3.x/inference_deployment/cross_platform/ios_deployment.html
- Upstream engine reference: https://github.com/PaddlePaddle/PaddleOCR/tree/dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf/deploy/ios_demo
- Detection weights: https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx
- Recognition weights: https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx
- PaddleOCR source and model repository license: Apache-2.0. Preserve applicable notices when redistributing a production model pack. This integration does not copy or link OpenCV/Clipper sources into Jibiji.

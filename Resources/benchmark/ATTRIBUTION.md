# LibriSpeech benchmark fixture

This directory contains human speech from **LibriSpeech dev-clean**, utterance
`1272-128104-0000`, reader 1272. LibriSpeech was prepared by Vassil Panayotov with
assistance from Daniel Povey, from LibriVox audiobooks.

- Publisher and license: [OpenSLR SLR12](https://www.openslr.org/12), **CC BY 4.0**.
- License terms: <https://creativecommons.org/licenses/by/4.0/>.
- Audio and unmodified reference mirror: [Hugging Face fixture dataset](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy/tree/5be91486e11a2d616f4ec5db8d3fd248585ac07a), `clean/validation`, row 0.
- Retrieved October 4, 2026 via the dataset viewer's row audio URL. No full corpus was downloaded.
- Source FLAC SHA-256: `4e25e22555cd16e90edb0a3b49fdcf1fe652b2a1250ab643634db33895c75b41` (120,041 bytes).
- Modification: converted to mono 16 kHz signed 16-bit PCM WAV using the existing macOS `afconvert` utility. Speech and reference were not edited.
- WAV SHA-256: `c85401f70630847182fc5852d28ced0910629f5207ae38aa6a1464fd3daa3bfa` (191,456 bytes; 5.855 seconds).

The reference, provenance and audio hash are in `benchmark-fixture.json`.
This short, single-speaker read-speech fixture checks actual inference and
provides repeatable latency/resource measurements. Its WER does **not** establish
accuracy on spontaneous dictation, different accents, noise or long recordings.
Repeated runs are timing repetitions, not independent accuracy samples.

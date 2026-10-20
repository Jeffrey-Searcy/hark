# Third-party notices

Hark's own code is under the MIT license (see LICENSE). Hark also uses the
software and models below.

## Shipped inside Hark.app (release build)

| Component | Version | License | Source |
|---|---|---|---|
| whisper.cpp and ggml | 1.9.5 | MIT | https://github.com/ggml-org/whisper.cpp |
| uv | 0.9.27 | MIT (dual-licensed MIT / Apache-2.0; used under MIT) | https://github.com/astral-sh/uv |

## Downloaded by Hark's setup window on first launch

These are fetched, unmodified, from their original publishers and stored in
`~/Library/Application Support/Hark`. They are not part of the Hark download.

| Component | License | Source |
|---|---|---|
| Whisper large-v3-turbo model (GGML format) | MIT (OpenAI) | https://huggingface.co/ggerganov/whisper.cpp |
| Silero VAD v5.1.2 model (GGML format) | MIT | https://huggingface.co/ggml-org/whisper-vad |
| Kokoro-82M v1.0 voice model and voices | Apache-2.0 | https://github.com/thewh1teagle/kokoro-onnx |
| CPython 3.12.12 (python-build-standalone) | PSF-2.0 | https://github.com/astral-sh/python-build-standalone |
| kokoro-onnx 0.6.1 | MIT | https://github.com/thewh1teagle/kokoro-onnx |
| trafilatura 2.3.1, courlan, htmldate | Apache-2.0 | https://github.com/adbar/trafilatura |
| onnxruntime 1.31.0 | MIT | https://github.com/microsoft/onnxruntime |
| numpy | BSD-3-Clause (and others) | https://numpy.org |
| phonemizer 3.4.0 | GPL-3.0 | https://github.com/bootphon/phonemizer |
| espeakng-loader 0.2.4 (contains espeak-ng) | no license stated for the wrapper; espeak-ng is GPL-3.0 | https://github.com/thewh1teagle/espeakng-loader, https://github.com/espeak-ng/espeak-ng |
| Other Python packages | see `reader-requirements.txt` for the full pinned list | https://pypi.org |

phonemizer and espeak-ng are licensed under the GNU GPL version 3. Hark does not
include, link, or modify them: they are installed from PyPI into a separate Python
environment and run in their own process. Their full source code is available at
the links above.

---

## whisper.cpp / ggml license

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## uv license

```
MIT License

Copyright (c) 2025 Astral Software Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

# Third-Party Notices

This inventory records the exact source, license evidence, distribution status,
and reviewed notice obligation for UtterInk's resolved Swift packages and
runtime-downloaded speech assets. The authoritative package lock is
`Packages/UtterInkKit/Package.resolved`; the authoritative speech asset
inventory is `Config/speech-model-catalog.json`.

## Swift Package Dependencies

| Identity | Version | Revision | Source URL | License | License URL | Distribution Status | Notice Obligation | Review Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| keyboardshortcuts | 2.4.0 | 1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27 | https://github.com/sindresorhus/KeyboardShortcuts | MIT | https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/license | shipped-in-app | include-license-and-copyright | reviewed |
| swift-argument-parser | 1.8.2 | 6a52f3251125d74daf04fcbd5e6f08a75d074382 | https://github.com/apple/swift-argument-parser.git | Apache-2.0 | https://github.com/apple/swift-argument-parser/blob/6a52f3251125d74daf04fcbd5e6f08a75d074382/LICENSE.txt | resolved-only-not-shipped | none-not-shipped | reviewed |
| swift-asn1 | 1.7.1 | a9a5efd40eaf558a2bcd48d64b1d1646be686008 | https://github.com/apple/swift-asn1.git | Apache-2.0 | https://github.com/apple/swift-asn1/blob/a9a5efd40eaf558a2bcd48d64b1d1646be686008/LICENSE.txt | resolved-only-not-shipped | none-not-shipped | reviewed |
| swift-collections | 1.6.0 | a0cb0954ecb21e4e31b0070e6ed5674e8556685a | https://github.com/apple/swift-collections.git | Apache-2.0 | https://github.com/apple/swift-collections/blob/a0cb0954ecb21e4e31b0070e6ed5674e8556685a/LICENSE.txt | shipped-in-app | include-license | reviewed |
| swift-crypto | 4.5.0 | 1b6b2e274e85105bfa155183145a1dcfd63331f1 | https://github.com/apple/swift-crypto.git | Apache-2.0 | https://github.com/apple/swift-crypto/blob/1b6b2e274e85105bfa155183145a1dcfd63331f1/LICENSE.txt | shipped-in-app | include-license-and-notice | reviewed |
| swift-jinja | 2.3.6 | 0b67ecb79139f6addef8699eff3622808aa6c7dc | https://github.com/huggingface/swift-jinja.git | Apache-2.0 | https://github.com/huggingface/swift-jinja/blob/0b67ecb79139f6addef8699eff3622808aa6c7dc/LICENSE | shipped-in-app | include-license | reviewed |
| swift-transformers | 1.1.9 | 150169bfba0889c229a2ce7494cf8949f18e6906 | https://github.com/huggingface/swift-transformers.git | Apache-2.0 | https://github.com/huggingface/swift-transformers/blob/150169bfba0889c229a2ce7494cf8949f18e6906/LICENSE | shipped-in-app | include-license | reviewed |
| whisperkit | 0.18.0 | e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef | https://github.com/argmaxinc/WhisperKit | MIT | https://github.com/argmaxinc/WhisperKit/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/LICENSE | shipped-in-app | include-license-and-copyright | reviewed |
| yyjson | 0.12.0 | 8b4a38dc994a110abaec8a400615567bd996105f | https://github.com/ibireme/yyjson.git | MIT | https://github.com/ibireme/yyjson/blob/8b4a38dc994a110abaec8a400615567bd996105f/LICENSE | shipped-in-app | include-license-and-copyright | reviewed |

Speech model weights and tokenizer assets are downloaded directly from their
pinned upstream sources at runtime. They are not stored in this repository and
are not included in an UtterInk DMG.

## Runtime-Downloaded Speech Models

| Model ID | Model Revision | Model Source URL | Model License | Model License URL | Tokenizer Revision | Tokenizer Source URL | Tokenizer License | Tokenizer License URL | Distribution Status | Repository Content | DMG Content | Notice Obligation | Review Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base | 43ee8a5c2b72fb120079a4fb4a93f6e82057164a | https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-base | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md | e37978b90ca9030d5170a5c07aadb050351a65bb | https://huggingface.co/openai/whisper-base/tree/e37978b90ca9030d5170a5c07aadb050351a65bb | Apache-2.0 | https://huggingface.co/openai/whisper-base/blob/e37978b90ca9030d5170a5c07aadb050351a65bb/README.md | runtime-download-only | no | no | none-runtime-download-only | reviewed |
| small | 43ee8a5c2b72fb120079a4fb4a93f6e82057164a | https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-small | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md | 973afd24965f72e36ca33b3055d56a652f456b4d | https://huggingface.co/openai/whisper-small/tree/973afd24965f72e36ca33b3055d56a652f456b4d | Apache-2.0 | https://huggingface.co/openai/whisper-small/blob/973afd24965f72e36ca33b3055d56a652f456b4d/README.md | runtime-download-only | no | no | none-runtime-download-only | reviewed |
| large-v3 | 43ee8a5c2b72fb120079a4fb4a93f6e82057164a | https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-large-v3 | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md | 06f233fe06e710322aca913c1bc4249a0d71fce1 | https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1 | Apache-2.0 | https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/README.md | runtime-download-only | no | no | none-runtime-download-only | reviewed |

## License Texts and Attributions

The full Apache License 2.0 text appears in the repository-root `LICENSE`
file. It applies to the Apache-2.0 dependencies listed above. SwiftCrypto's
upstream NOTICE text is reproduced in the repository-root `NOTICE` file.

### KeyboardShortcuts

MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### WhisperKit

MIT License

Copyright (c) 2024 argmax, inc.

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

### yyjson

MIT License

Copyright (c) 2020 YaoYuan <ibireme@gmail.com>

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

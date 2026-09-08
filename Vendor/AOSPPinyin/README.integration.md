# AOSP PinyinIME integration

## Source and license

The C++ decoder is vendored from [AOSP PinyinIME](https://android.googlesource.com/platform/packages/inputmethods/PinyinIME) at commit
`49aebad1c1cfbbcaa9288ffed5161e79e57c3679`. This is a historical AOSP decoder,
not the current Google keyboard.

- [UPSTREAM.json](UPSTREAM.json) records each upstream file's original size and
  SHA-256 **before local patches**.
- `jni/include/` and `jni/share/` contain the decoding core. `jni/Android.mk` is
  retained for provenance; the iOS build does not execute it or use JNI/Android UI.
- [NOTICE](NOTICE) contains the Apache 2.0 notice; `MODULE_LICENSE_APACHE2` is the
  upstream license marker. Preserve the notice in distributed acknowledgments.
- [dict_pinyin.dat](../../Resources/dict_pinyin.dat) is the unmodified upstream
  `res/raw/dict_pinyin.dat`: 1,068,442 bytes, SHA-256
  `6bf0bbde4e3134cce38d08524a9f4dc1af40435243c8e36b38eb68d1e14462b2`.
- `tests/`, [PinyinDecoder.h](../../Keyboard/PinyinDecoder.h),
  [PinyinDecoder.mm](../../Keyboard/PinyinDecoder.mm), and
  [NineKeyPinyinDecoder.swift](../../Keyboard/NineKeyPinyinDecoder.swift) are local
  integration code, not upstream AOSP files.

## Local patches

The five modified upstream files contain marked integration changes:

| Files | Change |
| --- | --- |
| `jni/share/userdict.cpp` | Make Android logging optional on Apple; use a no-op performance-log macro. |
| `jni/share/matrixsearch.cpp`, `jni/share/ngram.cpp` | Correct debug format conversions for `size_t` with `%zu`. |
| `jni/include/matrixsearch.h`, `jni/include/spellingtrie.h` | Add read-only candidate and spelling cost accessors for bounded T9 ranking. |

These patches leave the native decoding algorithm and dictionary data unchanged.
When updating the dependency, review these patches against the new upstream files
and update the pinned commit, hashes, dictionary, and notices together.

## Build integration

The [project generator](../../scripts/generate-project.py) includes the 16
`jni/share/*.cpp` files, Objective-C++ bridge, Swift T9 adapter, and bundled
system dictionary in both keyboard extensions. It uses C++17, libc++, ARC,
Foundation, and the [bridging header](../../Keyboard/Keyboard-Bridging-Header.h).
Files under `tests/` are command-line test programs and must not enter App targets.

## Decoder API boundaries

`PinyinDecoder` is synchronous and **main-thread-only**. Each controller owns an
independent composition snapshot, backed by one process-wide native engine.
Instances must use the same system/user dictionary pair; an incompatible pair
fails without replacing a valid engine. Releasing one controller does not close
another controller's engine. Completed selections flush user-dictionary learning;
composition snapshots remain in memory.

Pass the entire ASCII letter/apostrophe buffer to `update(pinyin:)`. Candidate
indices belong to that instance's last returned snapshot. Selection rebuilds the
instance's search and resolves the displayed candidate text; it does not reuse
another controller's index or automatically commit text. A partial selection stays
in composition. Edits within an already fixed prefix clear that fixed selection.

Only when `isComplete` is true should the controller insert `commitText`, retain
`remainingPinyin`, call `reset()`, and compose the retained suffix again. The wrapper
accepts at most 256 ASCII characters and the native engine processes at most nine
syllables per segment. Invalid/oversized input returns no candidates while retaining
the original input. **Never discard a returned suffix.** Up to 80 candidates are
returned; candidate 0 can cover a full decoded sentence, while others may cover
only its next word or character.

The bridge decodes each unselected suffix independently. Fixed Chinese text is
preserved, but suffix ranking does not incorporate the earlier sentence context.
`spellingTable()` and `probe(pinyin:candidateLimit:)` are read-only lookups;
probing neither chooses a word nor learns from it.

## Nine-key adapter

`NineKeyPinyinDecoder` maps 2–9 to telephone letter groups and searches the actual
bundled spelling table. Apostrophes separate syllables, and a final incomplete
syllable is supported. Ranking uses the native spelling and candidate costs.

`update(digits:)` takes the complete buffer; `selectSpelling(at:)` narrows the first
unselected syllable without consuming digits; `selectCandidate(at:)` selects a real
dictionary candidate. Commit only on `isComplete`, then reset and recompose
`remainingDigits`. Partial selections remain in composition, and edits into the
fixed digit prefix clear that selection.

Search bounds are 64 input characters, 24 characters per current segment, a
48-path beam, 64 probes per rebuild, eight candidates per probe, 40 displayed
candidates, 16 spelling choices, and a 128-entry in-memory probe cache. The native
nine-syllable limit can shorten a segment further. Invalid/oversized input and
unprocessed suffixes are retained. Beam search is approximate; ambiguous input may
need spelling disambiguation or shorter selections.

## Verification

From the repository root, run:

```sh
scripts/test-pinyin.sh
```

The script builds the real C++/Objective-C++ bridge and Swift T9 adapter with the
bundled dictionary. It runs the bridge lifecycle/selection and T9 composition
regressions with AddressSanitizer; native code also uses UndefinedBehaviorSanitizer.
Synthetic user dictionaries are isolated and removed after the run. Build products
are under `build/tests/pinyin/`, or the configured `EHK_BUILD_DIR`.

These host tests do not establish iPhone typing latency, keyboard registration,
full App behavior, or modern contextual prediction quality. Device integration
still needs separate validation. `tests/bridge_benchmark.mm` is an optional local
microbenchmark, not a device performance guarantee.

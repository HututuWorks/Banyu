#import "PinyinDecoder.h"
#include "../Vendor/AOSPPinyin/jni/include/pinyinime.h"
#include "../Vendor/AOSPPinyin/jni/include/matrixsearch.h"
#include "../Vendor/AOSPPinyin/jni/include/spellingtrie.h"
#include <algorithm>

using namespace ime_pinyin;
extern "C" MatrixSearch *matrix_search;

@interface PinyinSpelling ()
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, readwrite) double score;
@end
@implementation PinyinSpelling
@end
@interface PinyinProbeCandidate ()
@property(nonatomic, copy, readwrite) NSString *text;
@property(nonatomic, readwrite) double score;
@property(nonatomic, readwrite) NSInteger consumedPinyinLength;
@end
@implementation PinyinProbeCandidate
@end
@interface PinyinProbeResult ()
@property(nonatomic, copy, readwrite) NSArray<PinyinProbeCandidate *> *candidates;
@property(nonatomic, readwrite) NSInteger decodedLength;
@end
@implementation PinyinProbeResult
@end

@interface PinyinResult ()
@property(nonatomic, copy, readwrite) NSArray<NSString *> *candidates;
@property(nonatomic, copy, readwrite) NSString *fixedText;
@property(nonatomic, copy, readwrite) NSString *remainingPinyin;
@property(nonatomic, readwrite) BOOL isComplete;
@property(nonatomic, copy, readwrite) NSString *commitText;
@end
@implementation PinyinResult
@end

// AOSP also has global spelling/scoring tables behind MatrixSearch. Keep one
// loaded engine for this extension process, rather than repeatedly reopening
// it or pretending separate MatrixSearch objects isolate those globals.
// Composing state belongs to the Objective-C instances below, never this pair.
static NSString *engineDictionaryPath;
static NSString *engineUserDictionaryPath;
static NSArray<PinyinSpelling *> *engineSpellings;
static NSString *preparedPinyin;
static size_t preparedCandidateCount;

static void ResetNativeSearch() {
    preparedPinyin = nil;
    preparedCandidateCount = 0;
    im_reset_search();
}

// Only pristine searches are reusable. All choices/resets invalidate this key;
// ownership never determines reuse, so overlapping controllers remain isolated.
static size_t SearchUnfixedPinyin(NSString *pinyin) {
    if ([preparedPinyin isEqual:pinyin]) return preparedCandidateCount;
    ResetNativeSearch();
    preparedCandidateCount = im_search(pinyin.UTF8String, pinyin.length);
    preparedPinyin = [pinyin copy];
    return preparedCandidateCount;
}

@implementation PinyinDecoder {
    NSString *_pinyin;
    NSString *_fixedPinyin;
    NSString *_fixedText;
    PinyinResult *_lastResult;
}

- (nullable instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                            userDictionaryPath:(NSString *)userDictionaryPath {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    self = [super init];
    if (!self) return nil;
    NSString *systemPath = dictionaryPath.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *userPath = userDictionaryPath.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (![NSFileManager.defaultManager isReadableFileAtPath:systemPath]) return nil;
    NSString *parent = userPath.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:parent
                               withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    if (![NSFileManager.defaultManager isWritableFileAtPath:parent]) return nil;
    BOOL userPathIsDirectory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:userPath isDirectory:&userPathIsDirectory] &&
        (userPathIsDirectory || ![NSFileManager.defaultManager isWritableFileAtPath:userPath])) return nil;
    if (engineDictionaryPath) {
        // A different profile must not replace another session's dictionary.
        // This app uses one fixed bundle/user dictionary pair.
        if (![engineDictionaryPath isEqual:systemPath] ||
            ![engineUserDictionaryPath isEqual:userPath]) return nil;
    } else {
        if (!im_open_decoder(systemPath.fileSystemRepresentation, userPath.fileSystemRepresentation)) {
            im_close_decoder();
            return nil;
        }
        engineDictionaryPath = [systemPath copy];
        engineUserDictionaryPath = [userPath copy];
    }
    _pinyin = @"";
    _fixedPinyin = @"";
    _fixedText = @"";
    return self;
}

// No per-session close: releasing an old controller must not close the engine
// used by a new controller. One loaded dictionary lives until process exit;
// completed selections explicitly flush learning.

- (void)reset {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    _pinyin = @"";
    _fixedPinyin = @"";
    _fixedText = @"";
    _lastResult = nil;
    // Other sessions reconstruct their own input before touching candidates.
    ResetNativeSearch();
}

- (PinyinResult *)emptyResult {
    PinyinResult *result = [PinyinResult new];
    result.candidates = @[];
    result.fixedText = _fixedText;
    result.remainingPinyin = [_pinyin substringFromIndex:_fixedPinyin.length];
    result.commitText = @"";
    result.isComplete = NO;
    return result;
}

- (size_t)prepareSearch {
    NSString *remaining = [_pinyin substringFromIndex:_fixedPinyin.length];
    // im_add_letter is an upstream stub. Decode the actual complete unselected
    // suffix, so another controller's native composing state cannot leak in.
    return SearchUnfixedPinyin(remaining);
}

- (NSString *)candidateAtIndex:(size_t)index {
    char16 buffer[128] = {};
    if (!im_get_candidate(index, buffer, 128)) return nil;
    size_t length = 0;
    while (length < 127 && buffer[length] != 0) length++;
    NSString *text = [NSString stringWithCharacters:(const unichar *)buffer length:length];
    return index == 0 ? [_fixedText stringByAppendingString:text] : text;
}

- (PinyinResult *)updateWithPinyin:(NSString *)pinyin {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    _pinyin = [pinyin.lowercaseString copy];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz'"];
    if (_pinyin.length == 0 || _pinyin.length > 256 ||
        [_pinyin rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        _fixedPinyin = @"";
        _fixedText = @"";
        ResetNativeSearch();
        _lastResult = [self emptyResult];
        return _lastResult;
    }
    // Editing inside a fixed syllable invalidates that fixed prefix. An edit
    // or append after it retains the chosen Chinese text exactly.
    if (![_pinyin hasPrefix:_fixedPinyin]) {
        _fixedPinyin = @"";
        _fixedText = @"";
    }
    size_t count = [self prepareSearch];
    _lastResult = [self resultWithCandidateCount:count afterSelection:NO];
    return _lastResult;
}

- (PinyinResult *)selectCandidateAtIndex:(NSInteger)index {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    // A duplicate callback before reset must not commit/learn a sentence twice.
    if (_lastResult.isComplete) return [self emptyResult];
    if (index < 0 || (NSUInteger)index >= _lastResult.candidates.count) {
        return _lastResult ?: [self emptyResult];
    }
    NSString *expected = _lastResult.candidates[(NSUInteger)index];
    if (_pinyin.length == _fixedPinyin.length && _fixedText.length > 0) {
        PinyinResult *result = [self emptyResult];
        result.candidates = @[_fixedText];
        result.isComplete = YES;
        result.commitText = _fixedText;
        _lastResult = result;
        im_flush_cache();
        return result;
    }
    size_t count = [self prepareSearch];
    size_t resolved = count;
    for (size_t candidate = 0; candidate < std::min(count, (size_t)80); candidate++) {
        if ([[self candidateAtIndex:candidate] isEqual:expected]) {
            resolved = candidate;
            break;
        }
    }
    if (resolved == count) {
        // Learning in another session can reorder/remove candidates. Refresh
        // this session's choices instead of inserting a different word.
        _lastResult = [self resultWithCandidateCount:count afterSelection:NO];
        return _lastResult;
    }
    count = im_choose(resolved);
    preparedPinyin = nil;
    _lastResult = [self resultWithCandidateCount:count afterSelection:YES];
    if (_lastResult.isComplete) im_flush_cache();
    ResetNativeSearch();
    return _lastResult;
}

- (PinyinResult *)resultWithCandidateCount:(size_t)count afterSelection:(BOOL)didSelect {
    if (count == 0) {
        PinyinResult *result = [self emptyResult];
        if (_fixedText.length > 0 && result.remainingPinyin.length == 0) {
            result.candidates = @[_fixedText];
        }
        return result;
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (size_t index = 0; index < std::min(count, (size_t)80); index++) {
        NSString *candidate = [self candidateAtIndex:index];
        if (!candidate) break;
        [candidates addObject:candidate];
    }
    if (candidates.count == 0) return [self emptyResult];
    const uint16 *starts = nullptr;
    size_t syllableCount = im_get_spl_start_pos(starts);
    size_t selectedCount = im_get_fixed_len();
    size_t decodedLength = 0;
    im_get_sps_str(&decodedLength);
    NSString *wholeSentence = candidates.firstObject;
    BOOL complete = didSelect && selectedCount > 0 && selectedCount == syllableCount;
    size_t consumed = complete ? decodedLength :
        ((starts && selectedCount <= syllableCount) ? starts[selectedCount] : 0);
    consumed = std::min(consumed, (size_t)(_pinyin.length - _fixedPinyin.length));
    if (didSelect && selectedCount > 0) {
        _fixedText = [wholeSentence substringToIndex:
            std::min((size_t)wholeSentence.length, _fixedText.length + selectedCount)];
        _fixedPinyin = [_pinyin substringToIndex:_fixedPinyin.length + consumed];
    }
    PinyinResult *result = [PinyinResult new];
    result.candidates = candidates;
    result.fixedText = _fixedText;
    result.remainingPinyin = [_pinyin substringFromIndex:_fixedPinyin.length];
    result.isComplete = complete;
    result.commitText = complete ? wholeSentence : @"";
    return result;
}

- (NSArray<PinyinSpelling *> *)spellingTable {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    if (!engineSpellings) {
        NSMutableArray<PinyinSpelling *> *spellings = [NSMutableArray array];
        SpellingTrie &trie = SpellingTrie::get_instance();
        for (size_t offset = 0; offset < trie.get_spelling_num(); offset++) {
            uint16 identifier = static_cast<uint16>(kFullSplIdStart + offset);
            PinyinSpelling *item = [PinyinSpelling new];
            item.text = [NSString stringWithUTF8String:trie.get_spelling_str(identifier)].lowercaseString;
            item.score = trie.spelling_score(identifier);
            [spellings addObject:item];
        }
        engineSpellings = [spellings copy];
    }
    return engineSpellings;
}

- (PinyinProbeResult *)probePinyin:(NSString *)pinyin candidateLimit:(NSInteger)limit {
    NSAssert(NSThread.isMainThread, @"PinyinDecoder must run on the main thread");
    PinyinProbeResult *result = [PinyinProbeResult new];
    result.candidates = @[];
    NSString *normalized = pinyin.lowercaseString;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz'"];
    if (normalized.length == 0 || normalized.length > 64 || limit <= 0 ||
        [normalized rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return result;
    size_t count = SearchUnfixedPinyin(normalized);
    size_t decodedLength = 0;
    im_get_sps_str(&decodedLength);
    result.decodedLength = decodedLength;
    const uint16 *starts = nullptr;
    size_t syllables = im_get_spl_start_pos(starts);
    NSMutableArray<PinyinProbeCandidate *> *candidates = [NSMutableArray array];
    for (size_t index = 0; index < std::min(count, (size_t)std::min(limit, (NSInteger)80)); index++) {
        char16 buffer[128] = {};
        if (!im_get_candidate(index, buffer, 128)) break;
        size_t length = 0;
        while (length < 127 && buffer[length] != 0) length++;
        PinyinProbeCandidate *candidate = [PinyinProbeCandidate new];
        candidate.text = [NSString stringWithCharacters:(const unichar *)buffer length:length];
        candidate.score = matrix_search->candidate_score(index);
        candidate.consumedPinyinLength = index == 0 ? decodedLength :
            ((starts && length <= syllables) ? starts[length] : 0);
        [candidates addObject:candidate];
    }
    result.candidates = candidates;
    return result;
}
@end

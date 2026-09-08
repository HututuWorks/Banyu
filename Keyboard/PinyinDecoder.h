#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Official dictionary spelling and its native frequency cost (lower is better).
@interface PinyinSpelling : NSObject
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, readonly) double score;
@end

/// A read-only dictionary candidate; probing does not select or learn a word.
@interface PinyinProbeCandidate : NSObject
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, readonly) double score;
@property(nonatomic, readonly) NSInteger consumedPinyinLength;
@end

@interface PinyinProbeResult : NSObject
@property(nonatomic, copy, readonly) NSArray<PinyinProbeCandidate *> *candidates;
@property(nonatomic, readonly) NSInteger decodedLength;
@end

/// A real AOSP decoder snapshot. Candidate indices match selectCandidate(at:).
@interface PinyinResult : NSObject
@property(nonatomic, copy, readonly) NSArray<NSString *> *candidates;
@property(nonatomic, copy, readonly) NSString *fixedText;
@property(nonatomic, copy, readonly) NSString *remainingPinyin;
@property(nonatomic, readonly) BOOL isComplete;
@property(nonatomic, copy, readonly) NSString *commitText;
@end

/// Independent composing sessions backed by one process-wide AOSP engine.
/// Call synchronously on the main thread; multiple live instances are supported.
/// All instances must use the same bundled dictionary and writable user path.
@interface PinyinDecoder : NSObject
- (nullable instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                            userDictionaryPath:(NSString *)userDictionaryPath
    NS_SWIFT_NAME(init(dictionaryPath:userDictionaryPath:));
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Pass the entire original composing buffer, including already fixed syllables.
/// Never commits text automatically. Invalid input returns no candidates.
- (PinyinResult *)updateWithPinyin:(NSString *)pinyin NS_SWIFT_NAME(update(pinyin:));

/// On completion, commit commitText, reset, then compose remainingPinyin again.
/// remainingPinyin may be nonempty when the engine reaches its segment limit.
- (PinyinResult *)selectCandidateAtIndex:(NSInteger)index NS_SWIFT_NAME(selectCandidate(at:));
- (void)reset;

/// Shared immutable spelling inventory from the bundled real AOSP dictionary.
- (NSArray<PinyinSpelling *> *)spellingTable;

/// Bounded stateless lookup, isolated from this instance's composing snapshot.
- (PinyinProbeResult *)probePinyin:(NSString *)pinyin candidateLimit:(NSInteger)limit
    NS_SWIFT_NAME(probe(pinyin:candidateLimit:));
@end

NS_ASSUME_NONNULL_END

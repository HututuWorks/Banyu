#import <Foundation/Foundation.h>
#import "../../../Keyboard/PinyinDecoder.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        PinyinDecoder *decoder = [[PinyinDecoder alloc]
            initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[2])];
        Require(decoder != nil, @"open official dictionary");
        for (NSArray<NSString *> *example in @[@[@"nihao", @"你好"], @[@"wokuaidaole", @"我快到了"], @[@"zhongguo", @"中国"]]) {
            [decoder reset];
            PinyinResult *result = [decoder updateWithPinyin:example[0]];
            Require([result.candidates containsObject:example[1]], @"expected real dictionary candidate");
            NSInteger index = [result.candidates indexOfObject:example[1]];
            result = [decoder selectCandidateAtIndex:index];
            Require(result.isComplete && [result.commitText isEqual:example[1]], @"selected candidate commits complete text");
            Require(result.remainingPinyin.length == 0, @"no dropped/leftover pinyin");
        }
        [decoder reset];
        PinyinResult *result = [decoder updateWithPinyin:@"wokuaidaole"];
        NSInteger wo = [result.candidates indexOfObject:@"我"];
        Require(wo != NSNotFound, @"single-word alternative exists");
        result = [decoder selectCandidateAtIndex:wo];
        Require(!result.isComplete && [result.fixedText isEqual:@"我"], @"first segment fixed without committing");
        Require([result.remainingPinyin isEqual:@"kuaidaole"], @"remaining syllables preserved");
        result = [decoder updateWithPinyin:@"wokuaidaole"];
        Require([result.fixedText isEqual:@"我"], @"same-buffer update preserves fixed choice");
        result = [decoder selectCandidateAtIndex:0];
        Require(result.isComplete && [result.commitText isEqual:@"我快到了"], @"segmented selection completes full sentence");

        [decoder reset];
        result = [decoder updateWithPinyin:@"nihao"];
        NSInteger ni = [result.candidates indexOfObject:@"你"];
        Require(ni != NSNotFound, @"single character candidate exists");
        result = [decoder selectCandidateAtIndex:ni];
        result = [decoder updateWithPinyin:@"nihaoma"];
        Require([result.fixedText isEqual:@"你"], @"append preserves fixed prefix");
        result = [decoder updateWithPinyin:@"n"];
        Require(result.fixedText.length == 0 && result.candidates.count > 0, @"delete into fixed syllable resets selection safely");

        [decoder reset];
        [decoder updateWithPinyin:@"nihao"];
        result = [decoder updateWithPinyin:@"niha"];
        Require(!result.isComplete && result.candidates.count > 0, @"delete recomputes candidates");
        result = [decoder updateWithPinyin:@"nihao🙂"];
        Require(result.candidates.count == 0 && result.remainingPinyin.length > 0, @"invalid input is not silently dropped");

        NSString *remaining = @"nihaonihaonihaonihaonihaonihao";
        NSMutableString *committed = [NSMutableString string];
        for (NSInteger round = 0; remaining.length > 0 && round < 8; round++) {
            [decoder reset];
            result = [decoder updateWithPinyin:remaining];
            Require(result.candidates.count > 0, @"long input retains decodable prefix");
            result = [decoder selectCandidateAtIndex:0];
            Require(result.isComplete && result.remainingPinyin.length < remaining.length, @"long input makes progress");
            [committed appendString:result.commitText];
            remaining = result.remainingPinyin;
        }
        Require(remaining.length == 0 && committed.length == 12, @"long input preserves all syllables across segments");

        // Two controllers can overlap during a host-app transition. Their
        // displayed indices and selected prefixes must remain their own.
        PinyinDecoder *second = [[PinyinDecoder alloc]
            initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[2])];
        Require(second != nil, @"second live session opens");
        for (NSInteger round = 0; round < 32; round++) {
            [decoder reset];
            [second reset];
            PinyinResult *firstResult = [decoder updateWithPinyin:@"wokuaidaole"];
            NSInteger firstChoice = [firstResult.candidates indexOfObject:@"我"];
            Require(firstChoice != NSNotFound, @"first session offers partial choice");
            PinyinResult *secondResult = [second updateWithPinyin:@"nihaoma"];
            NSInteger secondChoice = [secondResult.candidates indexOfObject:@"你"];
            Require(secondChoice != NSNotFound, @"second session offers different partial choice");
            // Select from a snapshot after the other session changed the core.
            firstResult = [decoder selectCandidateAtIndex:firstChoice];
            Require([firstResult.fixedText isEqual:@"我"] &&
                    [firstResult.remainingPinyin isEqual:@"kuaidaole"], @"first snapshot survives second update");
            secondResult = [second selectCandidateAtIndex:secondChoice];
            Require([secondResult.fixedText isEqual:@"你"] &&
                    [secondResult.remainingPinyin isEqual:@"haoma"], @"second snapshot survives first selection");
            firstResult = [decoder updateWithPinyin:@"wokuaidaole"];
            secondResult = [second updateWithPinyin:@"nihao"];
            Require([firstResult.fixedText isEqual:@"我"] &&
                    [secondResult.fixedText isEqual:@"你"], @"interleaved updates keep distinct fixed prefixes");
            firstResult = [decoder selectCandidateAtIndex:0];
            Require(firstResult.isComplete && [firstResult.commitText isEqual:@"我快到了"], @"first session finishes independently");
            [decoder reset];
            secondResult = [second selectCandidateAtIndex:0];
            Require(secondResult.isComplete && [secondResult.commitText isEqual:@"你好"], @"reset of first does not erase second");
            Require(![second selectCandidateAtIndex:0].isComplete, @"duplicate selection cannot commit again");
        }

        [second reset];
        result = [second updateWithPinyin:@"nihaoma"];
        result = [second selectCandidateAtIndex:[result.candidates indexOfObject:@"你"]];
        result = [second updateWithPinyin:@"ni"];
        Require([result.fixedText isEqual:@"你"] && [result.candidates.firstObject isEqual:@"你"], @"delete to fixed boundary retains selectable Chinese");
        result = [second selectCandidateAtIndex:0];
        Require(result.isComplete && [result.commitText isEqual:@"你"], @"fixed boundary can commit");
        [second reset];
        [second updateWithPinyin:@"zhongguo"];
        __weak PinyinDecoder *oldSession = decoder;
        decoder = nil;
        Require(oldSession == nil, @"older session actually deallocates");
        result = [second selectCandidateAtIndex:0];
        Require(result.isComplete && [result.commitText isEqual:@"中国"], @"destroying older session does not close newer engine");

        for (NSInteger round = 0; round < 32; round++) {
            @autoreleasepool {
                PinyinDecoder *temporary = [[PinyinDecoder alloc]
                    initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[2])];
                Require(temporary != nil, @"replacement controller opens while older session lives");
                [second reset];
                [second updateWithPinyin:@"nihao"];
                [temporary updateWithPinyin:@"wokuaidaole"];
                __weak PinyinDecoder *released = temporary;
                temporary = nil;
                Require(released == nil, @"newer temporary session actually deallocates");
                result = [second selectCandidateAtIndex:0];
                Require(result.isComplete && [result.commitText isEqual:@"你好"], @"destroying newer session does not erase older composition");
            }
        }
        PinyinDecoder *invalid = [[PinyinDecoder alloc]
            initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[1])];
        Require(invalid == nil, @"different dictionary profile rejected without replacing shared engine");
        [second reset];
        [second updateWithPinyin:@"nihao"];
        result = [second selectCandidateAtIndex:0];
        Require(result.isComplete && [result.commitText isEqual:@"你好"], @"failed init does not close valid engine");
        second = nil;
        PinyinDecoder *reopened = [[PinyinDecoder alloc]
            initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[2])];
        Require(reopened != nil, @"new controller opens after all previous sessions release");
        [reopened updateWithPinyin:@"wokuaidaole"];
        result = [reopened selectCandidateAtIndex:0];
        Require(result.isComplete && [result.commitText isEqual:@"我快到了"], @"replacement session decodes normally");
        puts("PASS: real dictionary, selections, edits, invalid input, long suffix, interleaved sessions, release orders, retry");
    }
    return 0;
}

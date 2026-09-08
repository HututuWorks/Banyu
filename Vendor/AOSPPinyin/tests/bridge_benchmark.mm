#import <Foundation/Foundation.h>
#import "../../../Keyboard/PinyinDecoder.h"
#include <algorithm>
#include <chrono>
#include <vector>

static void Report(const char *label, std::vector<double> values) {
    std::sort(values.begin(), values.end());
    printf("%s count=%zu median_ms=%.3f p95_ms=%.3f max_ms=%.3f\n", label, values.size(),
           values[values.size()/2], values[values.size()*95/100], values.back());
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        PinyinDecoder *decoder = [[PinyinDecoder alloc] initWithDictionaryPath:@(argv[1]) userDictionaryPath:@(argv[2])];
        if (!decoder) return 3;
        using Clock = std::chrono::steady_clock;
        std::vector<double> updates, selections;
        for (int round = 0; round < 100; round++) {
            [decoder reset];
            NSString *input = @"wokuaidaole";
            for (NSUInteger end = 1; end <= input.length; end++) {
                auto start = Clock::now();
                [decoder updateWithPinyin:[input substringToIndex:end]];
                updates.push_back(std::chrono::duration<double, std::milli>(Clock::now()-start).count());
            }
            auto start = Clock::now();
            [decoder selectCandidateAtIndex:0];
            selections.push_back(std::chrono::duration<double, std::milli>(Clock::now()-start).count());
        }
        Report("qwerty_update", updates);
        Report("qwerty_selection_including_flush", selections);
    }
}

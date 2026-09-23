#import "agent_stats.h"
#include <signal.h>
#include <string.h>
#include <sys/stat.h>

// Sources (see the research notes in docs/agent-stats.md):
//   ~/.claude/sessions/<pid>.json            live process → sessionId, tmux pane, start
//   ~/.claude/projects/*/<sessionId>.jsonl   transcript: titles, recap, usage per message
//   ~/Library/Caches/agent-belt/claude-statusline.json  plan quotas, teed by the statusline
//   ~/.codex/sessions/**/rollout-*.jsonl     token_count events carry Codex rate limits
// Transcripts are read incrementally; only lines with interesting markers are parsed.

@implementation MKSessionInfo
@end

static NSString *MKHome(NSString *path) { return [NSHomeDirectory() stringByAppendingPathComponent:path]; }
static id MKJSON(NSData *data) { return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; }
static NSDictionary *MKDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
static NSString *MKStr(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static double MKNum(id value) { return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0; }

// ---------------------------------------------------------------- pricing

// USD per million tokens, platform.claude.com/docs/en/about-claude/pricing (2026-09-23):
// input, cache write 5 min, cache write 1 h, cache read, output. Longest prefix first.
typedef struct { const char *prefix; double in, write5m, write1h, read, out; } MKPrice;
static const MKPrice mk_prices[] = {
    {"claude-fable-5-1", 10, 12.5, 20, 0.25, 50},
    {"claude-fable-5", 10, 12.5, 20, 1, 50},
    {"claude-opus-5-5", 4, 5, 8, 0.2, 20},
    {"claude-opus-5", 5, 6.25, 10, 0.5, 25},
    {"claude-opus-4-8", 5, 6.25, 10, 0.5, 25},
    {"claude-opus-4-6", 5, 6.25, 10, 0.5, 25},
    {"claude-sonnet-5", 2, 2.5, 4, 0.2, 10},
    {"claude-haiku-4-5", 1, 1.25, 2, 0.1, 5},
};

static const MKPrice *MKPriceFor(NSString *model) {
    for (size_t i = 0; i < sizeof mk_prices / sizeof *mk_prices; i++)
        if ([model hasPrefix:@(mk_prices[i].prefix)]) return &mk_prices[i];
    return NULL;
}

// ---------------------------------------------------------------- transcripts

@interface MKTranscript : NSObject
@property unsigned long long offset, inode;
@property NSMutableData *partial;
@property NSMutableSet<NSString *> *seen;   // message ids: one usage per message, not per block
@property NSString *aiTitle, *customTitle, *awaySummary, *lastPrompt;
@property unsigned long long tokens;
@property double cost;
@property BOOL unknownPrice;
@end
@implementation MKTranscript
@end

static NSMutableDictionary<NSString *, MKTranscript *> *mk_transcripts;

static BOOL MKHas(const char *line, size_t length, const char *marker) {
    return memmem(line, length, marker, strlen(marker)) != NULL;
}

static void MKTakeLine(MKTranscript *t, const char *line, size_t length) {
    const BOOL assistant = MKHas(line, length, "\"type\":\"assistant\"");
    if (!assistant && !MKHas(line, length, "\"ai-title\"") && !MKHas(line, length, "\"custom-title\"") &&
        !MKHas(line, length, "\"away_summary\"") && !MKHas(line, length, "\"last-prompt\"")) return;
    NSDictionary *record = MKDict(MKJSON([NSData dataWithBytesNoCopy:(void *)line length:length freeWhenDone:NO]));
    if (!record) return;
    NSString *type = MKStr(record[@"type"]);
    if ([type isEqual:@"ai-title"]) t.aiTitle = MKStr(record[@"aiTitle"]) ?: t.aiTitle;
    else if ([type isEqual:@"custom-title"]) t.customTitle = MKStr(record[@"customTitle"]) ?: t.customTitle;
    else if ([type isEqual:@"last-prompt"]) t.lastPrompt = MKStr(record[@"lastPrompt"]) ?: t.lastPrompt;
    else if ([type isEqual:@"system"] && [record[@"subtype"] isEqual:@"away_summary"])
        t.awaySummary = MKStr(record[@"content"]) ?: t.awaySummary;
    else if ([type isEqual:@"assistant"]) {
        NSDictionary *message = MKDict(record[@"message"]);
        NSString *identifier = MKStr(message[@"id"]), *model = MKStr(message[@"model"]);
        NSDictionary *usage = MKDict(message[@"usage"]);
        if (!identifier || !usage || !model || [model isEqual:@"<synthetic>"] || [t.seen containsObject:identifier]) return;
        [t.seen addObject:identifier];
        const double in = MKNum(usage[@"input_tokens"]), out = MKNum(usage[@"output_tokens"]);
        const double read = MKNum(usage[@"cache_read_input_tokens"]), written = MKNum(usage[@"cache_creation_input_tokens"]);
        NSDictionary *split = MKDict(usage[@"cache_creation"]);
        const double write1h = MKNum(split[@"ephemeral_1h_input_tokens"]);
        const double write5m = split ? MKNum(split[@"ephemeral_5m_input_tokens"]) : written;
        t.tokens += (unsigned long long)(in + out + read + written);
        const MKPrice *price = MKPriceFor(model);
        if (!price) { t.unknownPrice = YES; return; }
        double cost = (in * price->in + write5m * price->write5m + write1h * price->write1h +
                       read * price->read + out * price->out) / 1e6;
        if ([usage[@"inference_geo"] isEqual:@"us"]) cost *= 1.1;
        t.cost += cost;
    }
}

// Reads what was appended since last time; a replaced or truncated file starts over.
static MKTranscript *MKReadTranscript(NSString *path) {
    if (!mk_transcripts) mk_transcripts = [NSMutableDictionary dictionary];
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0) return nil;
    MKTranscript *t = mk_transcripts[path];
    if (!t || t.inode != info.st_ino || (unsigned long long)info.st_size < t.offset) {
        t = [MKTranscript new];
        t.inode = info.st_ino;
        t.partial = [NSMutableData data];
        t.seen = [NSMutableSet set];
        mk_transcripts[path] = t;
    }
    if ((unsigned long long)info.st_size == t.offset) return t;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    [file seekToFileOffset:t.offset];
    NSData *chunk = [file readDataToEndOfFile];
    [file closeFile];
    t.offset += chunk.length;
    [t.partial appendData:chunk];
    const char *bytes = t.partial.bytes;
    size_t length = t.partial.length, start = 0;
    for (size_t i = 0; i < length; i++)
        if (bytes[i] == '\n') {
            if (i > start) MKTakeLine(t, bytes + start, i - start);
            start = i + 1;
        }
    [t.partial replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    return t;
}

static NSMutableDictionary<NSString *, NSString *> *mk_transcript_paths;

static NSString *MKTranscriptPath(NSString *sessionId) {
    if (!mk_transcript_paths) mk_transcript_paths = [NSMutableDictionary dictionary];
    NSString *cached = mk_transcript_paths[sessionId];
    if (cached && [NSFileManager.defaultManager fileExistsAtPath:cached]) return cached;
    // The project directory encodes the cwd lossily and sessions may be relocated: search.
    NSString *projects = MKHome(@".claude/projects");
    for (NSString *project in [NSFileManager.defaultManager contentsOfDirectoryAtPath:projects error:nil]) {
        NSString *path = [[projects stringByAppendingPathComponent:project]
                          stringByAppendingPathComponent:[sessionId stringByAppendingPathExtension:@"jsonl"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return mk_transcript_paths[sessionId] = path;
    }
    return nil;
}

static MKSessionInfo *MKInfoForSession(NSString *sessionId, double startedAt) {
    NSString *path = MKTranscriptPath(sessionId);
    MKTranscript *main = path ? MKReadTranscript(path) : nil;
    if (!main) return nil;
    MKSessionInfo *info = [MKSessionInfo new];
    info.title = main.customTitle ?: main.aiTitle;
    NSString *recap = main.awaySummary ?: main.lastPrompt;
    recap = [[recap componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    info.recap = [recap stringByReplacingOccurrencesOfString:@" (disable recaps in /config)" withString:@""];
    info.startedAt = startedAt;
    info.tokens = main.tokens;
    info.cost = main.cost;
    BOOL unknown = main.unknownPrice;
    NSString *subagents = [[path stringByDeletingPathExtension] stringByAppendingPathComponent:@"subagents"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:subagents error:nil]) {
        if (![name hasSuffix:@".jsonl"]) continue;
        MKTranscript *sub = MKReadTranscript([subagents stringByAppendingPathComponent:name]);
        info.tokens += sub.tokens;
        info.cost += sub.cost;
        unknown = unknown || sub.unknownPrice;
    }
    info.costKnown = !unknown;
    return info;
}

NSDictionary<NSString *, MKSessionInfo *> *MKClaudeSessionInfo(void) {
    NSString *dir = MKHome(@".claude/sessions");
    NSMutableArray<NSDictionary *> *live = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name hasSuffix:@".json"]) continue;
        NSDictionary *session = MKDict(MKJSON([NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]]));
        pid_t pid = (pid_t)MKNum(session[@"pid"]);
        if (pid > 0 && kill(pid, 0) == 0 && MKStr(session[@"sessionId"])) [live addObject:session];
    }
    // A parked interactive session hands its work to a background process whose
    // jobId matches; that process owns the live transcript.
    NSMutableDictionary<NSString *, NSDictionary *> *byJob = [NSMutableDictionary dictionary];
    for (NSDictionary *session in live) if (MKStr(session[@"jobId"])) byJob[session[@"jobId"]] = session;
    NSMutableDictionary<NSString *, MKSessionInfo *> *result = [NSMutableDictionary dictionary];
    for (NSDictionary *session in live) {
        if ([session[@"kind"] isEqual:@"bg"]) continue;
        NSDictionary *owner = byJob[MKStr(session[@"parkedJobId"]) ?: @""] ?: session;
        MKSessionInfo *info = MKInfoForSession(owner[@"sessionId"], MKNum(session[@"startedAt"]) / 1000);
        if (!info) continue;
        if (!info.title && [@[@"user", @"auto"] containsObject:session[@"nameSource"] ?: @""]) info.title = MKStr(session[@"name"]);
        NSString *pane = [[MKStr(session[@"tmux"]) componentsSeparatedByString:@"."] lastObject];
        if ([pane hasPrefix:@"%"]) result[[@"pane:" stringByAppendingString:pane]] = info;
        NSString *handle = MKProcessEnv((pid_t)MKNum(session[@"pid"]), "ORCA_TERMINAL_HANDLE");
        if (handle.length) result[[@"orca:" stringByAppendingString:handle]] = info;
    }
    return result;
}

// ---------------------------------------------------------------- quotas

static NSString *MKPercent(NSDictionary *window, NSString *key, double resetsAt) {
    if (!window) return nil;
    double used = MKNum(window[key]);
    if (resetsAt > 0 && resetsAt < NSDate.date.timeIntervalSince1970) used = 0; // window already reset
    return [NSString stringWithFormat:@"%.0f%%", used];
}

static double MKEpoch(id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSISO8601DateFormatter *format = [NSISO8601DateFormatter new];
        format.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
        NSDate *date = [format dateFromString:value];
        if (!date) { format.formatOptions &= ~NSISO8601DateFormatWithFractionalSeconds; date = [format dateFromString:value]; }
        return date.timeIntervalSince1970;
    }
    return MKNum(value);
}

static NSString *MKClaudeQuota(void) {
    NSDictionary *status = MKDict(MKJSON([NSData dataWithContentsOfFile:MKHome(@"Library/Caches/agent-belt/claude-statusline.json")]));
    NSDictionary *limits = MKDict(status[@"rate_limits"]);
    NSDictionary *five = MKDict(limits[@"five_hour"]), *week = MKDict(limits[@"seven_day"]);
    NSString *a = MKPercent(five, @"used_percentage", MKEpoch(five[@"resets_at"]));
    NSString *b = MKPercent(week, @"used_percentage", MKEpoch(week[@"resets_at"]));
    if (!a && !b) return nil;
    return [NSString stringWithFormat:@"Claude 5h %@ · 7d %@", a ?: @"?", b ?: @"?"];
}

// The newest token_count event with primary/secondary windows, from the most
// recently written rollouts; cached per file modification time.
static NSString *MKCodexQuota(void) {
    static NSString *cachedLine, *cachedFile;
    static double cachedMtime;
    NSString *root = MKHome(@".codex/sessions");
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (int day = 0; day < 7; day++) {
        NSDateFormatter *format = [NSDateFormatter new];
        format.dateFormat = @"yyyy/MM/dd";
        NSString *dir = [root stringByAppendingPathComponent:[format stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * day]]];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
            if ([name hasPrefix:@"rollout-"]) [files addObject:[dir stringByAppendingPathComponent:name]];
    }
    [files sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *ma = [NSFileManager.defaultManager attributesOfItemAtPath:a error:nil].fileModificationDate;
        NSDate *mb = [NSFileManager.defaultManager attributesOfItemAtPath:b error:nil].fileModificationDate;
        return [mb compare:ma];
    }];
    for (NSString *file in [files subarrayWithRange:NSMakeRange(0, MIN(files.count, (NSUInteger)5))]) {
        double mtime = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileModificationDate.timeIntervalSince1970;
        if ([file isEqual:cachedFile] && mtime == cachedMtime) return cachedLine;
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:file];
        unsigned long long size = [handle seekToEndOfFile];
        [handle seekToFileOffset:size > 512 * 1024 ? size - 512 * 1024 : 0];
        NSString *tail = [[NSString alloc] initWithData:[handle readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        [handle closeFile];
        for (NSString *line in [[tail componentsSeparatedByString:@"\n"] reverseObjectEnumerator]) {
            if (![line containsString:@"\"rate_limits\""] || ![line containsString:@"\"primary\""]) continue;
            NSDictionary *payload = MKDict(MKDict(MKJSON([line dataUsingEncoding:NSUTF8StringEncoding]))[@"payload"]);
            NSDictionary *limits = MKDict(payload[@"rate_limits"]) ?: MKDict(MKDict(payload[@"info"])[@"rate_limits"]);
            NSDictionary *primary = MKDict(limits[@"primary"]), *secondary = MKDict(limits[@"secondary"]);
            if (!primary) continue;
            cachedLine = [NSString stringWithFormat:@"Codex 5h %@ · 7d %@",
                          MKPercent(primary, @"used_percent", MKNum(primary[@"resets_at"])) ?: @"?",
                          MKPercent(secondary, @"used_percent", MKNum(secondary[@"resets_at"])) ?: @"?"];
            cachedFile = file;
            cachedMtime = mtime;
            return cachedLine;
        }
    }
    return cachedLine;
}

NSString *MKQuotaLine(void) {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *claude = MKClaudeQuota(), *codex = MKCodexQuota();
    if (claude) [parts addObject:claude];
    if (codex) [parts addObject:codex];
    return parts.count ? [parts componentsJoinedByString:@"   "] : nil;
}

// ---------------------------------------------------------------- formatting

NSString *MKSessionStatsText(MKSessionInfo *info) {
    NSMutableArray *parts = [NSMutableArray array];
    if (info.startedAt > 0) {
        long minutes = (long)((NSDate.date.timeIntervalSince1970 - info.startedAt) / 60);
        [parts addObject:minutes < 60 ? [NSString stringWithFormat:@"%ld min", minutes]
                                      : [NSString stringWithFormat:@"%ld h %02ld", minutes / 60, minutes % 60]];
    }
    if (info.costKnown && info.cost > 0) [parts addObject:[[NSString stringWithFormat:@"$%.2f", info.cost]
                                                          stringByReplacingOccurrencesOfString:@"." withString:@","]];
    if (info.tokens) {
        double t = info.tokens;
        NSString *tokens = t >= 1e6 ? [NSString stringWithFormat:@"%.1fM tok", t / 1e6] : [NSString stringWithFormat:@"%.0fk tok", t / 1e3];
        [parts addObject:[tokens stringByReplacingOccurrencesOfString:@"." withString:@","]];
    }
    return [parts componentsJoinedByString:@" · "];
}

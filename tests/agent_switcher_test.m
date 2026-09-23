#import "../src/agent_switcher.m"
#include <assert.h>

static MKAgentTarget *target(NSString *key, NSString *bundle, BOOL selected) {
    MKAgentTarget *t = [MKAgentTarget new];
    t.key = key;
    t.bundle = bundle;
    t.selected = selected;
    return t;
}

int main(void) {
    // Environment is read by pid through sysctl, so it must be set before exec.
    if (!getenv("MK_TEST_MARK")) {
        setenv("MK_TEST_MARK", "switcher", 1);
        extern char **environ;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        proc_pidpath(getpid(), path, sizeof(path));
        execve(path, (char *[]){path, NULL}, environ);
        return 1;
    }
    @autoreleasepool {
        MKAgentTarget *a = target(@"a", @"orca", NO);
        MKAgentTarget *b = target(@"b", @"codex", NO);
        MKAgentTarget *c = target(@"c", @"claude", NO);
        NSArray *ring = @[a,b,c];
        assert(MKNextIndex(ring, nil, @"finder") == 0);
        assert(MKNextIndex(ring, @"a", @"orca") == 1);
        assert(MKNextIndex(ring, @"c", @"claude") == 0);
        assert(MKNextIndex(ring, @"b", @"finder") == 0);
        a.selected = YES;
        assert(MKNextIndex(ring, @"b", @"orca") == 1); // manual focus overrides history
        a.selected = NO;
        assert(MKNextIndex(@[a], @"a", @"orca") == 0);
        assert(MKNextIndex(@[], nil, @"orca") == 0);

        MKAgentTarget *replacement = target(@"a", @"orca", YES);
        NSArray *stable = MKStableRing(ring, @[c,replacement,b]);
        assert(stable.count == 3 && stable[0] == replacement && stable[1] == b && stable[2] == c);
        MKAgentTarget *d = target(@"d", @"orca", NO);
        stable = MKStableRing(ring, @[d,c,a]);
        assert(([stable isEqualToArray:@[a,c,d]])); // remove closed, append new, preserve order
        assert(MKStableRing(ring, @[]).count == 0);

        NSDictionary *live = @{@"handle":@"term_1", @"connected":@YES, @"orphaned":@NO};
        assert(MKLiveTerminal(live));
        NSMutableDictionary *changed = [live mutableCopy];
        changed[@"connected"] = @NO;
        assert(!MKLiveTerminal(changed));
        changed[@"connected"] = @YES;
        changed[@"orphaned"] = @YES;
        assert(!MKLiveTerminal(changed));
        assert(!MKLiveTerminal(@{}));

        assert([MKAgentCommand(@"claude") isEqual:@"claude"]);
        assert([MKAgentCommand(@"2.1.280") isEqual:@"claude"]); // Claude Code's process title
        assert([MKAgentCommand(@"codex") isEqual:@"codex"]);
        assert(MKAgentCommand(@"zsh") == nil);
        assert(MKAgentCommand(@"-zsh") == nil);
        assert(MKAgentCommand(@"2.1") == nil);
        assert(MKAgentCommand(@"vim") == nil);

        NSArray *rows = MKRows(@"work-a\tclaude\t2.1.280\nwork-b\tcodex\tzsh\nplain\t\tcodex\nsplit\t\tzsh\nsplit\t\tclaude\nbad\n");
        NSDictionary *agents = MKSessionAgents(rows);
        assert([agents[@"work-a"] isEqual:@"claude"]);
        assert(agents[@"work-b"] == nil); // agent exited, the `work` mark stays behind
        assert([agents[@"plain"] isEqual:@"codex"]);
        assert([agents[@"split"] isEqual:@"claude"]); // any pane of the session
        assert(agents.count == 3);

        assert([MKProcessEnv(getpid(), "MK_TEST_MARK") isEqual:@"switcher"]);
        assert(MKProcessEnv(getpid(), "MK_TEST_MISSING") == nil);

        assert([MKLiveSessionName(@"Em execução projeto") isEqual:@"projeto"]);
        assert([MKLiveSessionName(@"Idle project") isEqual:@"project"]);
        assert([MKLiveSessionName(@"Resposta não lida project") isEqual:@"project"]);
        assert(MKLiveSessionName(@"#1 · Mesclado project") == nil);
        assert(MKLiveSessionName(@"Mais opções para project") == nil);
        assert(MKLiveSessionName(@"New chat") == nil);
        assert(MKSessionTabGroup(@"Chat tabs"));
        assert(!MKSessionTabGroup(@"Período"));
        assert(!MKSessionTabGroup(@"Visualização de estatísticas"));

        puts("agent switcher: ring, tmux/Orca agent detection, process env and session filters OK");
    }
}

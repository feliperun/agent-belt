#import "../src/agent_switcher.m"
#include <assert.h>

void mk_scroll_down(int32_t lines) { (void)lines; } // lives in macos_shim.c
void mk_hud_show(const char *t, const char *d, int tone) { (void)t; (void)d; (void)tone; } // status_item.m
void mk_led_agents(int attention) { (void)attention; } // led.m
void mk_menu_show(const char *const *l, const char *const *d, const int *t, int c, int s, const char *f, int k) { (void)l; (void)d; (void)t; (void)c; (void)s; (void)f; (void)k; }
void mk_status_attention(int a) { (void)a; }
void mk_menu_hide(void) {}
const char *mk_update_line(void) { return NULL; }

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
        // Subprocesses get a UTF-8 locale even from launchd's empty environment.
        unsetenv("LANG"); unsetenv("LC_ALL");
        NSString *childEnv = [[NSString alloc] initWithData:MKRun(@"/usr/bin/env", @[]) encoding:NSUTF8StringEncoding];
        assert([childEnv containsString:@"LANG=en_US.UTF-8"]);
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

        NSString *why = nil;
        NSArray *hosts = @[@"macbook-pro", @"felipe-windows"];
        assert([MKWorkCommand(@"ok: {\"host\":\"felipe-windows\",\"agent\":\"codex\",\"repo\":\"coreum\",\"task\":\"login-bug\",\"prompt\":\"Investigue o login d'hoje\"}", hosts, &why, NULL)
                 isEqual:@"work felipe-windows login-bug coreum --agent codex --prompt 'Investigue o login d'\\''hoje'"]);
        assert([MKWorkCommand(@"{\"host\":null,\"agent\":\"CLAUDE\",\"repo\":\"x\",\"task\":\"t\",\"prompt\":\"\"}", hosts, &why, NULL) isEqual:@"work t x --agent claude"]);
        assert(!MKWorkCommand(@"{\"host\":\"marte\",\"repo\":\"x\",\"task\":\"t\"}", hosts, &why, NULL) && [why containsString:@"marte"]);
        assert(!MKWorkCommand(@"{\"repo\":null,\"task\":\"t\"}", hosts, &why, NULL) && [why containsString:@"repositório"]);
        assert(!MKWorkCommand(@"{\"repo\":\"x\",\"task\":\"tem espaço\"}", hosts, &why, NULL));
        assert(!MKWorkCommand(@"desculpe, não sei", hosts, &why, NULL));
        assert(!MKWorkCommand(@"{\"repo\":\"x; rm -rf ~\",\"task\":\"t\"}", hosts, &why, NULL)); // no shell injection via repo

        assert(MKMenuDecide(NO, INFINITY) == MKMenuShow);
        assert(MKMenuDecide(NO, 0.1) == MKMenuShow);   // hidden: any press shows
        assert(MKMenuDecide(YES, 1.0) == MKMenuMove);
        assert(MKMenuDecide(YES, 0.2) == MKMenuOpen);  // quick second press
        assert(MKMenuDecide(YES, 0.35) == MKMenuMove); // window is exclusive

        assert(MKTitleWorking(@"◐ Refatorar"));
        assert(MKTitleWorking(@"⠋ build"));
        assert(!MKTitleWorking(@"✳ Refatorar"));
        assert(!MKTitleWorking(@"work"));
        assert(!MKTitleWorking(@""));
        assert([MKCleanTitle(@"✳ Refatorar") isEqual:@"Refatorar"]);
        assert([MKCleanTitle(@"◑ Refatorar") isEqual:@"Refatorar"]);
        assert([MKCleanTitle(@"~/dev") isEqual:@"~/dev"]);

        assert(MKWaitingScreen(@"Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"));
        assert(MKWaitingScreen(@"Would you like to run the following command?\n› 1. Yes, proceed (y)\n"));
        assert(!MKWaitingScreen(@"Do you want me to also update the README?\n> "));
        assert(!MKWaitingScreen(@"❯ 1. Yes\n"));
        NSMutableString *old = [NSMutableString stringWithString:@"Do you want to proceed?\n❯ 1. Yes\n"];
        for (int i = 0; i < 30; i++) [old appendString:@"later output\n"];
        assert(!MKWaitingScreen(old)); // an answered prompt scrolled away

        NSDictionary *panes = MKSessionAgentPanes(MKRows(@"s1\tclaude\tzsh\t%1\tzsh\ns1\tclaude\t2.1.280\t%2\t✳ task\ns2\t\tvim\t%3\tvim\n"));
        assert([panes[@"s1"] isEqualToArray:(@[@"%2", @"✳ task"])]);
        assert(panes[@"s2"] == nil);

        MKAgentTarget *w = target(@"w", @"orca", NO), *x = target(@"x", @"orca", NO), *y = target(@"y", @"orca", NO);
        w.title = @"◐ busy"; x.title = @"✳ idle"; y.title = @"✳ idle";
        NSArray *agentRing = @[w, x, y];
        MKObserve(agentRing);
        assert(w.state == MKStateWorking && x.state == MKStateIdle);
        w.title = @"✳ done";
        MKObserve(agentRing);
        assert(w.state == MKStateDone); // working → idle = finished
        MKObserve(agentRing);
        assert(w.state == MKStateDone); // until visited
        assert(MKPickIndex(agentRing, @"x", @"orca") == 0); // finished beats plain next
        y.state = MKStateWaiting;
        assert(MKPickIndex(agentRing, @"x", @"orca") == 2); // waiting beats finished
        assert(MKPickIndex(agentRing, @"y", @"orca") == 0); // never the focused one
        w.state = y.state = MKStateIdle;
        assert(MKPickIndex(agentRing, @"x", @"orca") == 2); // plain ring order

        puts("agent switcher: ring, tmux/Orca agent detection, process env, session filters, agent states, priority and menu presses and voice commands OK");
    }
}

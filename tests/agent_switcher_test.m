#import "../src/agent_switcher.m"
#include <assert.h>
#import "../src/login_path.m"

void mk_scroll_down(int32_t lines) { (void)lines; } // lives in macos_shim.c
void mk_hud_show(const char *t, const char *d, int tone) { (void)t; (void)d; (void)tone; } // status_item.m
void mk_led_agents(int attention) { (void)attention; } // led.m
void mk_menu_show(const char *const *l, const char *const *d, const int *t, int c, int s, const char *f, int k) { (void)l; (void)d; (void)t; (void)c; (void)s; (void)f; (void)k; }
void mk_status_attention(int a) { (void)a; }
void mk_status_agents(int count) { (void)count; }
void mk_menu_hide(void) {}
void mk_create_panel_show(const char *t) { (void)t; } // create_panel.m
const char *mk_update_line(void) { return NULL; }

static MKAgentTarget *target(NSString *key, NSString *bundle, BOOL selected) {
    MKAgentTarget *t = [MKAgentTarget new];
    t.key = key;
    t.bundle = bundle;
    t.selected = selected;
    return t;
}

// The daemon takes the PATH of the user's login shell (rc files may print around it).
static void testLoginPath(void) {
    assert([MKParseLoginPath(@"hello\n__AGB_PATH__/a/bin:/usr/bin__AGB_PATH__") isEqual:@"/a/bin:/usr/bin"]);
    assert(MKParseLoginPath(@"no marks") == nil && MKParseLoginPath(@"__AGB_PATH__relative__AGB_PATH__") == nil);
    NSString *originalPath = @(getenv("PATH"));
    setenv("PATH", "/nonexistent", 1);
    setenv("SHELL", "/bin/sh", 1); // a login shell sets its own PATH
    mk_login_path();
    assert(strcmp(getenv("PATH"), "/nonexistent") && getenv("PATH")[0] == '/' && strstr(getenv("PATH"), "/usr/bin"));
    setenv("SHELL", "/usr/bin/false", 1); // no answer: the PATH stays
    setenv("PATH", "/nonexistent", 1);
    mk_login_path();
    assert(!strcmp(getenv("PATH"), "/nonexistent"));
    setenv("PATH", originalPath.UTF8String, 1);
}

int main(void) {
    // A terminal already attached to a session: `agb attach` from the app (a path with a space).
    assert([MKAttachKey(@"  4242 /Applications/Agent Belt.app/Contents/MacOS/agb attach report windows-pc") isEqual:@"windows-pc\treport"]);
    assert([MKAttachKey(@"77 /home/alice/.local/bin/agb attach -d api home-linux") isEqual:@"home-linux\tapi"]);
    assert(MKAttachKey(@"77 /usr/bin/agb attach api") == nil); // no machine: not a remote attach
    assert(MKAttachKey(@"77 ssh -t windows-pc agb attach api") == nil);
    // Environment is read by pid through sysctl, so it must be set before exec.
    if (!getenv("MK_TEST_MARK")) {
        setenv("MK_TEST_MARK", "switcher", 1);
        setenv("CMUX_SURFACE_ID", "D5459E3A-D004-46A7-A132-6EA1040E5FCC", 1);
        unsetenv("ORCA_TERMINAL_HANDLE");
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

        testLoginPath();

        // A terminal's host is told by its handle: Orca's read "term_…", cmux's are UUIDs.
        assert([MKHostBundle(@"term_ab12") isEqual:MKOrcaBundle]);
        assert([MKHostBundle(@"D5459E3A-D004-46A7-A132-6EA1040E5FCC") isEqual:MKCmuxBundle]);
        assert([MKHostedHandle(getpid()) isEqual:@"D5459E3A-D004-46A7-A132-6EA1040E5FCC"]);

        // The terminal new agents open in is a setting; cmux unless it says "orca".
        mk_agents_set_terminal("orca");
        assert([mk_terminal_bundle isEqual:MKOrcaBundle]);
        mk_agents_set_terminal("cmux");
        assert([mk_terminal_bundle isEqual:MKCmuxBundle]);
        mk_agents_set_terminal("unknown");
        assert([mk_terminal_bundle isEqual:MKCmuxBundle]);

        // cmux: terminal surfaces of every workspace, tagged with the workspace's id.
        NSDictionary *tree = @{@"windows": @[@{@"workspaces": @[
            @{@"id": @"W1", @"panes": @[@{@"surfaces": @[@{@"id": @"S1", @"type": @"terminal", @"title": @"✳ api"},
                                                         @{@"id": @"S2", @"type": @"browser"}]}]},
            @{@"id": @"W2", @"panes": @[@{@"surfaces": @[@{@"id": @"S3", @"type": @"terminal"}]}]}]}]};
        NSArray *surfaces = MKCmuxSurfaces(tree);
        assert(surfaces.count == 2);
        assert([surfaces[0][@"id"] isEqual:@"S1"] && [surfaces[0][@"workspace_id"] isEqual:@"W1"]);
        assert([surfaces[1][@"id"] isEqual:@"S3"] && [surfaces[1][@"workspace_id"] isEqual:@"W2"]);
        assert(MKCmuxSurfaces(nil).count == 0);

        // cmux's agent records: a dead process is no agent, the newest record of a surface wins.
        int alive = getpid();
        NSDictionary *records = MKCmuxAgents(@{@"sessions": @[
            @{@"surface_id": @"S1", @"agent": @"codex", @"pid": @(alive), @"updated_at_unix": @100, @"agent_lifecycle": @"idle"},
            @{@"surface_id": @"S1", @"agent": @"claude", @"pid": @(alive), @"updated_at_unix": @200, @"agent_lifecycle": @"running"},
            @{@"surface_id": @"S2", @"agent": @"claude", @"pid": @(2147483646), @"updated_at_unix": @300},
            @{@"surface_id": @"S3", @"agent": @"", @"pid": @(alive)}]});
        assert(records.count == 1 && [records[@"S1"][@"agent"] isEqual:@"claude"]);
        assert(MKCmuxAgents(nil).count == 0);
        assert([MKCmuxStatus(@"running") isEqual:@"busy"]);
        assert([MKCmuxStatus(@"needsInput") isEqual:@"waiting"]);
        assert([MKCmuxStatus(@"idle") isEqual:@"idle"] && [MKCmuxStatus(@"unknown") isEqual:@"idle"]);

        assert([MKLiveSessionName(@"Em execução projeto") isEqual:@"projeto"]);
        assert([MKLiveSessionName(@"Idle project") isEqual:@"project"]);
        assert([MKLiveSessionName(@"Resposta não lida project") isEqual:@"project"]);
        assert(MKLiveSessionName(@"#1 · Mesclado project") == nil);
        assert(MKLiveSessionName(@"Mais opções para project") == nil);
        assert(MKLiveSessionName(@"New chat") == nil);
        assert(MKSessionTabGroup(@"Chat tabs"));
        assert(!MKSessionTabGroup(@"Período"));
        assert(!MKSessionTabGroup(@"Visualização de estatísticas"));

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

        // A session opened from the menu is started by typing the line into the new
        // tab. It is never handed to `create --command`: Orca runs a creation command
        // when it adopts the tab, so a tab it keeps in the background opens on a bare
        // prompt with `agb attach` never called and the session never opens.
        NSArray<NSString *> *create = MKTabCreate(@"report @ windows-pc");
        assert(![create containsObject:@"--command"]);
        assert([create containsObject:@"--title"] && [create containsObject:@"report @ windows-pc"]);

        NSString *attach = @"'/Applications/Agent Belt.app/Contents/MacOS/agb' attach report windows-pc";
        NSArray<NSArray<NSString *> *> *run = MKTabRun(attach, @"report @ windows-pc", @"term_1");
        assert(run.count == 2);
        NSArray<NSString *> *send = run[0];
        assert([send[0] isEqual:@"terminal"] && [send[1] isEqual:@"send"]);
        assert([send containsObject:@"term_1"] && [send containsObject:@"--enter"]);
        NSString *line = send[[send indexOfObject:@"--text"] + 1];
        assert([line hasPrefix:@"printf '"]); // the line names the tab it runs in
        assert([line hasSuffix:attach]);
        assert([run[1] isEqualToArray:(@[@"terminal", @"switch", @"--terminal", @"term_1"])]);

        puts("agent switcher: ring, tmux/Orca agent detection, process env, session filters, agent states, priority and menu presses and voice commands OK");
    }
}

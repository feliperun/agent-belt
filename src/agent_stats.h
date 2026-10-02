#import <Foundation/Foundation.h>

// Per-session facts for the agent menu, read from the agents' own files.
@interface MKSessionInfo : NSObject
@property NSString *title;      // custom-title, else ai-title
@property NSString *recap;      // away_summary, else the last prompt
@property double startedAt;     // process start, epoch seconds
@property unsigned long long tokens; // input + cache + output, subagents included
@property double cost;          // USD at API list prices
@property BOOL costKnown;       // NO when a model has no known price
@property NSString *status;     // Claude Code's own state: busy, idle or waiting
@end

// Live Claude Code sessions keyed by "pane:<tmux pane id>" and "terminal:<Orca terminal handle or cmux surface id>".
NSDictionary<NSString *, MKSessionInfo *> *MKClaudeSessionInfo(void);
// "Claude 5h 23% · 7d 41%  ·  Codex 5h 5% · 7d 21%", or nil when nothing is known.
NSString *MKQuotaLine(void);
// "12 min · $3,40 · 1,2M tok"
NSString *MKSessionStatsText(MKSessionInfo *info);

// agent_switcher.m
NSString *MKProcessEnv(pid_t pid, const char *name);
NSString *MKHostedHandle(pid_t pid); // the Orca or cmux terminal a process runs in

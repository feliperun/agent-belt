#import <Foundation/Foundation.h>

// The agent list as last seen by the 5 s monitor, for the menu bar menu:
// dictionaries with title, detail, tone (0 idle, 1 working, 2 done, 3 waiting) and key.
NSArray<NSDictionary *> *MKAgentsSnapshot(void);
// Focuses the agent with that key (asynchronous).
void MKAgentsOpenKey(NSString *key);
// Plan quotas line for the menu, or nil.
NSString *MKAgentsQuotaLine(void);

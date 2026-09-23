// Stand-ins for the daemon pieces status_item.m calls, so its drawing code can
// run alone (overlay test, tools/render-*.m).
#import <Foundation/Foundation.h>
void mk_led_status(int s) { (void)s; }
void mk_agents_menu_click(void) {}
void mk_agents_menu_close(void) {}
void mk_agents_menu_open(int i) { (void)i; }
void mk_agents_bottom(void) {}
void mk_agents_menu_open_selected(void) {}
void mk_agents_menu_press(void) {}
void mk_agents_menu_step(int d) { (void)d; }
void mk_agents_next(int d) { (void)d; }
int mk_agents_menu_visible(void) { return 0; }
void mk_agents_voice_command(const char *t) { (void)t; }
void mk_open_privacy(const char *p) { (void)p; }
void mk_update_check_now(void) {}
const char *mk_update_available(void) { return NULL; }
const char *mk_app_version(void) { return "test"; }
int mk_update_run(const char *t) { (void)t; return 0; }
NSArray<NSDictionary *> *MKAgentsSnapshot(void) { return @[]; }
void MKAgentsOpenKey(NSString *k) { (void)k; }
NSString *MKAgentsQuotaLine(void) { return nil; }

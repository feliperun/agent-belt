#ifndef AGENT_BELT_KEYPAD_HID_H
#define AGENT_BELT_KEYPAD_HID_H

#include <IOKit/hid/IOHIDManager.h>
#include <stdint.h>

// Caller releases the matching array. No transport constraint on configured IDs.
CFArrayRef mk_keypad_matching(uint16_t vendor_id, uint16_t product_id, int include_f5);
int mk_keypad_is_device(IOHIDDeviceRef device, uint16_t vendor_id, uint16_t product_id);

#endif

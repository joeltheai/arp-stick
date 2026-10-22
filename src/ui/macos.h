#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void *context;
    uint32_t (*read)(void *context, uint32_t id);
    bool (*change)(void *context, uint32_t id, uint32_t value);
    const char *options[4][4];
    uint32_t counts[4];
} ArpStickUIConfig;

// The returned handle owns a retained NSView. All functions run on the main thread.
void *arp_ui_create(const ArpStickUIConfig *config);
void arp_ui_destroy(void *handle);
bool arp_ui_attach(void *handle, void *parent);
void arp_ui_show(void *handle, bool visible);
void arp_ui_refresh(void *handle);
int arp_ui_preview(const ArpStickUIConfig *config);

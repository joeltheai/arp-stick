#pragma once
#include <stdbool.h>
#include <stdint.h>

// Field indices shared by the Zig backend and the Cocoa editor.
typedef enum ArpStickField {
    ARP_FIELD_CHORD_NOTE = 0, // slot, voice -> -1 | 0..127
    ARP_FIELD_CHORD_VEL,      // slot, voice -> 0..200
    ARP_FIELD_LOCK_ON,        // voice
    ARP_FIELD_LOCK_NOTE,      // voice
    ARP_FIELD_CELL,           // lane, column
    ARP_FIELD_RESET,          // column
    ARP_FIELD_MUTE,           // column
    ARP_FIELD_LEN,            // lane
    ARP_FIELD_DIV,            // lane
    ARP_FIELD_RATE,
    ARP_FIELD_SWING,
    ARP_FIELD_RETRIG,
    ARP_FIELD_LINK,
    ARP_FIELD_CHORD_MODE,
    ARP_FIELD_CONSTRAINT,     // pitch class
    ARP_FIELD_PEN,            // degree 0..6
    ARP_FIELD_CUR_SLOT,
    ARP_FIELD_PATTERN,
    ARP_FIELD_FREE_ON,
    ARP_FIELD_FREE_HZ,        // hundredths of a hertz
    ARP_FIELD_WATCH_ON,
    ARP_FIELD_WATCHED,        // slot
    ARP_FIELD_NAME_CHAR,      // index
    ARP_FIELD_CUR_GRAPH,
    ARP_FIELD_SCALE_KEY,
    ARP_FIELD_SCALE_TYPE,
    ARP_FIELD_LEARNING,
    ARP_FIELD_LEARN_MODE,
    ARP_FIELD_LEARN_TIMER,
    ARP_FIELD_LEARN_COUNT,
    ARP_FIELD_LEARN_NOTE,     // index
    ARP_FIELD_PLAYING,
    ARP_FIELD_LAST_FIRED,
    ARP_FIELD_LAST_OUT,
    ARP_FIELD_ARP_COUNT,
    ARP_FIELD_SND_COUNT,
    ARP_FIELD_ACTIVE_SLOT,
    ARP_FIELD_PATTERN_USED,   // pattern index
} ArpStickField;

typedef enum ArpStickAction {
    ARP_ACTION_COPY_PATTERN = 1, // from, to
    ARP_ACTION_COPY_GRAPH,
    ARP_ACTION_PASTE_GRAPH,
    ARP_ACTION_RAND_GRAPH,
    ARP_ACTION_ARP_PRESET,       // preset
    ARP_ACTION_CHORD_PRESET,     // preset
    ARP_ACTION_SORT,             // mode
    ARP_ACTION_REMOVE_DUPS,
    ARP_ACTION_REMOVE_N,         // count
    ARP_ACTION_REMOVE_UNWATCHED,
    ARP_ACTION_CLEAR_ALL,
    ARP_ACTION_MAKE_THIRD,       // delta
    ARP_ACTION_TRANSFORM_PREVENT,
    ARP_ACTION_TRANSFORM_MATCH,  // slot
    ARP_ACTION_POPULATE_EMPTY,
    ARP_ACTION_COPY_CHORD,       // slot
    ARP_ACTION_PASTE_CHORD,      // slot
    ARP_ACTION_RAND_CHORD,       // slot
    ARP_ACTION_PREVIEW_CHORD,    // slot, channel
    ARP_ACTION_PANIC,
    ARP_ACTION_TOGGLE_LEARN,     // mode, timer
    ARP_ACTION_IMPORT_MIDI,      // slot
} ArpStickAction;

typedef enum ArpStickText {
    ARP_TEXT_CHORD_NAME = 0, // slot
    ARP_TEXT_RATE,           // rate index
    ARP_TEXT_PATTERN_NAME,   // pattern
    ARP_TEXT_NOTE,           // note
    ARP_TEXT_PC,             // pitch class
} ArpStickText;

typedef struct {
    void *context;
    int32_t (*read_param)(void *context, uint32_t id);
    bool (*write_param)(void *context, uint32_t id, int32_t value);
    int32_t (*read_field)(void *context, uint32_t field, uint32_t a, uint32_t b);
    bool (*write_field)(void *context, uint32_t field, uint32_t a, uint32_t b, int32_t value);
    bool (*action)(void *context, uint32_t action, int32_t a, int32_t b);
    void (*read_text)(void *context, uint32_t kind, uint32_t a, uint32_t b, char *buffer, uint32_t size);
    void (*begin_edit)(void *context);
    void (*end_edit)(void *context);
} ArpStickUIConfig;

// The returned handle owns a retained NSView. All functions run on the main thread.
void *arp_ui_create(const ArpStickUIConfig *config);
void arp_ui_destroy(void *handle);
bool arp_ui_attach(void *handle, void *parent);
void arp_ui_show(void *handle, bool visible);
void arp_ui_refresh(void *handle);
int arp_ui_preview(const ArpStickUIConfig *config);


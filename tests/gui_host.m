// Exercise the actual CLAP editor in a small Cocoa host, without opening a DAW.
#import <Cocoa/Cocoa.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t single_size(const clap_input_events_t *events);
static const clap_event_header_t *single_get(const clap_input_events_t *events, uint32_t index);
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "GUI FAIL line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)
static uint32_t flush_requests;
static uint32_t callback_requests;
static void request_callback(const clap_host_t *host) { (void)host; callback_requests++; }
static void request_flush(const clap_host_t *host) { (void)host; flush_requests++; }
static void rescan(const clap_host_t *host, clap_param_rescan_flags flags) { (void)host; (void)flags; }
static void clear(const clap_host_t *host, clap_id id, clap_param_clear_flags flags) { (void)host; (void)id; (void)flags; }
static const clap_host_params_t host_params = { .rescan = rescan, .clear = clear, .request_flush = request_flush };
static const void *get_extension(const clap_host_t *host, const char *id) {
    (void)host; return !strcmp(id, CLAP_EXT_PARAMS) ? &host_params : NULL;
}
static void request(const clap_host_t *host) { (void)host; }
static const clap_host_t host = {
    .clap_version = CLAP_VERSION_INIT, .name = "Arp Stick GUI test", .vendor = "local", .url = "", .version = "1",
    .get_extension = get_extension, .request_restart = request, .request_process = request, .request_callback = request_callback,
};
static uint32_t input_size(const clap_input_events_t *events) { (void)events; return 0; }
static const clap_event_header_t *input_get(const clap_input_events_t *events, uint32_t index) { (void)events; (void)index; return NULL; }
typedef struct { uint16_t types[128]; uint32_t ids[128]; double values[128]; unsigned count, budget; } output_t;
static bool output_push(const clap_output_events_t *events, const clap_event_header_t *event) {
    output_t *out = events->ctx;
    if (!out->budget) return false;
    out->budget--;
    CHECK(out->count < 128 && event->time == 0);
    unsigned index = out->count++;
    out->types[index] = event->type;
    if (event->type == CLAP_EVENT_PARAM_VALUE) {
        const clap_event_param_value_t *value = (const clap_event_param_value_t *)event;
        out->ids[index] = value->param_id; out->values[index] = value->value;
        CHECK(value->note_id == -1 && value->channel == -1 && value->port_index == -1 && value->key == -1);
    } else {
        CHECK(event->type == CLAP_EVENT_PARAM_GESTURE_BEGIN || event->type == CLAP_EVENT_PARAM_GESTURE_END);
        out->ids[index] = ((const clap_event_param_gesture_t *)event)->param_id;
    }
    return true;
}

typedef struct { uint8_t data[65536]; size_t position; } memory_t;
static int64_t write_state(const clap_ostream_t *stream, const void *buffer, uint64_t size) {
    memory_t *memory = stream->ctx;
    if (memory->position + size > sizeof(memory->data)) return -1;
    memcpy(memory->data + memory->position, buffer, size);
    memory->position += size;
    return (int64_t)size;
}

typedef void (*click_fn)(void *, double, double, uint32_t);
typedef void (*size_fn)(void *, uint32_t, uint32_t);
typedef void (*draw_fn)(void *);
typedef void (*import_fn)(void *, const char *);

int main(int argc, char **argv) {
    CHECK(argc == 2);
    @autoreleasepool {
        [NSApplication sharedApplication];
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        CHECK(library != NULL);
        click_fn click = (click_fn)dlsym(library, "arp_ui_click");
        click_fn drag = (click_fn)dlsym(library, "arp_ui_drag");
        click_fn release = (click_fn)dlsym(library, "arp_ui_release");
        size_fn set_size = (size_fn)dlsym(library, "arp_ui_set_size");
        draw_fn draw = (draw_fn)dlsym(library, "arp_ui_draw_now");
        import_fn import_midi = (import_fn)dlsym(library, "arp_ui_import_midi");
        CHECK(click && drag && release && set_size && draw && import_midi);

        const clap_plugin_entry_t *entry = dlsym(library, "clap_entry");
        CHECK(entry && entry->init(argv[1]));
        const clap_plugin_factory_t *factory = entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
        const clap_plugin_descriptor_t *desc = factory->get_plugin_descriptor(factory, 0);
        const clap_plugin_t *plugin = factory->create_plugin(factory, &host, desc->id);
        CHECK(plugin && plugin->init(plugin));
        const clap_plugin_gui_t *gui = plugin->get_extension(plugin, CLAP_EXT_GUI);
        const clap_plugin_params_t *params = plugin->get_extension(plugin, CLAP_EXT_PARAMS);
        const clap_plugin_state_t *state = plugin->get_extension(plugin, CLAP_EXT_STATE);
        CHECK(gui && params && state);
        const char *api = NULL; bool floating = true;
        CHECK(gui->get_preferred_api(plugin, &api, &floating) && !floating && !strcmp(api, "cocoa"));
        CHECK(!gui->is_api_supported(plugin, "win32", false));
        CHECK(!gui->is_api_supported(plugin, "cocoa", true));
        CHECK(!gui->create(plugin, "cocoa", true));
        CHECK(gui->create(plugin, api, false));
        CHECK(!gui->create(plugin, api, false));
        uint32_t width = 0, height = 0;
        CHECK(gui->get_size(plugin, &width, &height) && width == 960 && height == 640);
        CHECK(!gui->can_resize(plugin) && !gui->set_size(plugin, 1, 1));
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
        clap_window_t parent = { .api = api, .cocoa = (__bridge void *)container };
        CHECK(gui->set_parent(plugin, &parent) && container.subviews.count == 1);
        CHECK(gui->show(plugin));
        NSView *view = container.subviews.firstObject;
        CHECK(view.frame.size.width == 960 && view.frame.size.height == 640);
        draw((__bridge void *)view);

        // Click CHORD and verify a complete automation gesture survives a
        // one-event output buffer, including the callback retry path.
        click((__bridge void *)view, 328, 13, 0);
        CHECK(flush_requests == 1);
        clap_input_events_t input = { .size = input_size, .get = input_get };
        output_t recorded = { .budget = 1 };
        clap_output_events_t output = { .ctx = &recorded, .try_push = output_push };
        params->flush(plugin, &input, &output);
        CHECK(recorded.count == 1 && recorded.types[0] == CLAP_EVENT_PARAM_GESTURE_BEGIN);
        CHECK(callback_requests == 1);
        plugin->on_main_thread(plugin);
        CHECK(flush_requests == 2);
        recorded.budget = 1; params->flush(plugin, &input, &output);
        CHECK(recorded.count == 2 && recorded.types[1] == CLAP_EVENT_PARAM_VALUE);
        CHECK(callback_requests == 2);
        plugin->on_main_thread(plugin);
        CHECK(flush_requests == 3);
        recorded.budget = 1; params->flush(plugin, &input, &output);
        CHECK(recorded.count == 3 && recorded.types[2] == CLAP_EVENT_PARAM_GESTURE_END);
        double value = -1;
        CHECK(params->get_value(plugin, 0, &value) && value == 0);

        // Pattern letter, arp toggle, lane tab, grid drag, piano audition,
        // constraint cycle, panic, menu and free-clock controls.
        click((__bridge void *)view, 85, 43, 0);
        click((__bridge void *)view, 663, 13, 0);
        drag((__bridge void *)view, 663, 220, 0);
        release((__bridge void *)view, 663, 220, 0);
        click((__bridge void *)view, 418, 13, 0);
        click((__bridge void *)view, 442, 36, 0);       // PITCH tab
        draw((__bridge void *)view);
        click((__bridge void *)view, 905, 55, 0);       // pitch degree 1
        click((__bridge void *)view, 214, 36, 0);       // NOTE tab
        click((__bridge void *)view, 199, 196, 0);      // first grid cell
        drag((__bridge void *)view, 220, 220, 0);
        release((__bridge void *)view, 220, 220, 0);
        click((__bridge void *)view, 870, 55, 0);       // constraint C
        click((__bridge void *)view, 923, 235, 0);      // panic
        click((__bridge void *)view, 40, 482, 0);       // chord menu
        click((__bridge void *)view, 20, 400, 0);       // first menu item
        click((__bridge void *)view, 110, 482, 0);      // chord presets
        click((__bridge void *)view, 20, 400, 0);       // C major diatonic bank
        click((__bridge void *)view, 26, 299, 0);       // FREE clock
        draw((__bridge void *)view);
        recorded.budget = 100; params->flush(plugin, &input, &output);
        CHECK(recorded.count > 3);
        CHECK(params->get_value(plugin, 1, &value) && value == 0);
        CHECK(params->get_value(plugin, 2, &value) && value == -36);
        CHECK(params->get_value(plugin, 7, &value) && value == 1);

        // Host automation reaches the shared parameter state.
        clap_event_param_value_t automation = { .header = { .size = sizeof(automation), .type = CLAP_EVENT_PARAM_VALUE },
            .param_id = 7, .value = 5, .note_id = -1, .port_index = -1, .channel = -1, .key = -1 };
        clap_input_events_t automated = { .ctx = &automation, .size = single_size, .get = single_get };
        params->flush(plugin, &automated, &output);
        CHECK(params->get_value(plugin, 7, &value) && value == 5);
        draw((__bridge void *)view);

        // The preset bank written through the editor is visible in plugin state.
        memory_t memory = {0};
        clap_ostream_t ostream = { .ctx = &memory, .write = write_state };
        CHECK(state->save(plugin, &ostream) && memory.position > 4000);
        // magic(4) + version(2) + params(32) + curSlot(4) + watched(16) = 58
        CHECK(memory.data[58 + 48 * 8] == 48);
        CHECK(memory.data[58 + 48 * 8 + 1] == 52);
        CHECK(memory.data[58 + 48 * 8 + 2] == 55);

        // MIDI-file import writes chords into consecutive slots.
        static const uint8_t smf[] = {
            'M','T','h','d', 0,0,0,6, 0,0, 0,1, 1,0xe0,
            'M','T','r','k', 0,0,0,0x1d,
            0x00,0x90,60,100, 0x00,0x90,64,100, 0x00,0x90,67,100,
            0x83,0x60,0x80,60,0, 0x00,0x80,64,0, 0x00,0x80,67,0,
            0x00,0xff,0x2f,0x00,
        };
        FILE *midi_file = fopen("/tmp/arp-stick-gui-test.mid", "wb");
        CHECK(midi_file != NULL);
        CHECK(fwrite(smf, 1, sizeof(smf), midi_file) == sizeof(smf));
        fclose(midi_file);
        import_midi((__bridge void *)view, "/tmp/arp-stick-gui-test.mid");
        memory.position = 0;
        CHECK(state->save(plugin, &ostream));
        CHECK(memory.data[58 + 48 * 8] == 60);
        CHECK(memory.data[58 + 48 * 8 + 1] == 64);
        CHECK(memory.data[58 + 48 * 8 + 2] == 67);
        remove("/tmp/arp-stick-gui-test.mid");

        // Layout scales without cropping.
        set_size((__bridge void *)view, 480, 320);
        draw((__bridge void *)view);
        set_size((__bridge void *)view, 2304, 1536);
        draw((__bridge void *)view);
        set_size((__bridge void *)view, 960, 640);

        CHECK(gui->hide(plugin)); gui->destroy(plugin);
        CHECK(container.subviews.count == 0);
        CHECK(gui->create(plugin, api, false));
        CHECK(gui->set_parent(plugin, &parent));
        draw((__bridge void *)container.subviews.firstObject);
        gui->destroy(plugin); plugin->destroy(plugin); entry->deinit();
        puts("GUI test passed: 960x640 Cocoa editor, parameters, patterns, lanes, grid, piano, MIDI import, automation and scaling.");
    }
    return 0;
}

static uint32_t single_size(const clap_input_events_t *events) { (void)events; return 1; }
static const clap_event_header_t *single_get(const clap_input_events_t *events, uint32_t index) {
    return index == 0 ? (const clap_event_header_t *)events->ctx : NULL;
}

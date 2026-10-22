// Exercise the actual CLAP editor in a small Cocoa host, without opening a DAW.
#import <Cocoa/Cocoa.h>
#include <clap/clap.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static NSControl *control(NSView *view, NSInteger id) {
    for (NSView *child in view.subviews)
        if (([child isKindOfClass:NSSegmentedControl.class] || [child isKindOfClass:NSPopUpButton.class]) && ((NSControl *)child).tag == id)
            return (NSControl *)child;
    return nil;
}
static void choose(NSView *view, NSInteger id, NSInteger value) {
    NSControl *item = control(view, id);
    CHECK(item != nil);
    if ([item isKindOfClass:NSPopUpButton.class]) [(NSPopUpButton *)item selectItemAtIndex:value];
    else ((NSSegmentedControl *)item).selectedSegment = value;
    CHECK([item sendAction:item.action to:item.target]);
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    @autoreleasepool {
        [NSApplication sharedApplication];
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        CHECK(library != NULL);
        const clap_plugin_entry_t *entry = dlsym(library, "clap_entry");
        CHECK(entry && entry->init(argv[1]));
        const clap_plugin_factory_t *factory = entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
        const clap_plugin_descriptor_t *desc = factory->get_plugin_descriptor(factory, 0);
        const clap_plugin_t *plugin = factory->create_plugin(factory, &host, desc->id);
        CHECK(plugin && plugin->init(plugin));
        const clap_plugin_gui_t *gui = plugin->get_extension(plugin, CLAP_EXT_GUI);
        const clap_plugin_params_t *params = plugin->get_extension(plugin, CLAP_EXT_PARAMS);
        CHECK(gui && params);
        const char *api = NULL; bool floating = true;
        CHECK(gui->get_preferred_api(plugin, &api, &floating) && !floating && !strcmp(api, "cocoa"));
        CHECK(!gui->is_api_supported(plugin, "win32", false));
        CHECK(!gui->is_api_supported(plugin, "cocoa", true));
        CHECK(!gui->create(plugin, "cocoa", true));
        CHECK(gui->create(plugin, api, false));
        CHECK(!gui->create(plugin, api, false));
        uint32_t width = 0, height = 0;
        CHECK(gui->get_size(plugin, &width, &height) && width == 480 && height == 340);
        CHECK(!gui->can_resize(plugin) && !gui->set_size(plugin, 1, 1));
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
        clap_window_t parent = { .api = api, .cocoa = (__bridge void *)container };
        CHECK(gui->set_parent(plugin, &parent) && container.subviews.count == 1);
        CHECK(gui->show(plugin));
        NSView *view = container.subviews.firstObject;
        CHECK(((NSSegmentedControl *)control(view, 0)).selectedSegment == 1);
        choose(view, 0, 0);
        CHECK(flush_requests == 1);
        clap_input_events_t input = { .size = input_size, .get = input_get };
        output_t recorded = { .budget = 1 };
        clap_output_events_t output = { .ctx = &recorded, .try_push = output_push };
        // A one-event host buffer must still receive exactly one begin/value/end sequence.
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
        choose(view, 1, 1); choose(view, 2, 2); choose(view, 3, 1);
        recorded.budget = 100; params->flush(plugin, &input, &output);
        CHECK(flush_requests == 6 && recorded.count == 12);
        for (unsigned id = 0; id < 4; id++) {
            CHECK(recorded.types[id * 3] == CLAP_EVENT_PARAM_GESTURE_BEGIN);
            CHECK(recorded.types[id * 3 + 1] == CLAP_EVENT_PARAM_VALUE && recorded.ids[id * 3 + 1] == id);
            CHECK(recorded.types[id * 3 + 2] == CLAP_EVENT_PARAM_GESTURE_END);
        }
        CHECK(params->get_value(plugin, 1, &value) && value == 1);
        CHECK(params->get_value(plugin, 2, &value) && value == 2);
        CHECK(params->get_value(plugin, 3, &value) && value == 1);

        // Host automation flows back to the visible controls.
        clap_event_param_value_t automation = { .header = { .size = sizeof(automation), .type = CLAP_EVENT_PARAM_VALUE },
            .param_id = 1, .value = 2, .note_id = -1, .port_index = -1, .channel = -1, .key = -1 };
        // Reuse an input list with a one-event accessor below.
        extern uint32_t single_size(const clap_input_events_t *);
        extern const clap_event_header_t *single_get(const clap_input_events_t *, uint32_t);
        clap_input_events_t automated = { .ctx = &automation, .size = single_size, .get = single_get };
        params->flush(plugin, &automated, &output);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.07]];
        CHECK(((NSPopUpButton *)control(view, 1)).indexOfSelectedItem == 2);
        CHECK(gui->hide(plugin)); gui->destroy(plugin);
        CHECK(container.subviews.count == 0);
        CHECK(gui->create(plugin, api, false));
        CHECK(gui->set_parent(plugin, &parent));
        CHECK(((NSPopUpButton *)control(container.subviews.firstObject, 1)).indexOfSelectedItem == 2);
        gui->destroy(plugin); plugin->destroy(plugin); entry->deinit();
        // Cocoa keeps registered Objective-C classes for the lifetime of this process.
        // The process exits here; do not explicitly dlclose its editor implementation.
        puts("GUI test passed: Cocoa embedding, all controls, host automation, gesture backpressure, and editor recreation.");
    }
    return 0;
}
uint32_t single_size(const clap_input_events_t *events) { (void)events; return 1; }
const clap_event_header_t *single_get(const clap_input_events_t *events, uint32_t index) {
    return index == 0 ? events->ctx : NULL;
}

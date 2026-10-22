// A small headless host tests the actual shared library against the official C ABI.
#include <clap/clap.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); } } while (0)

static const void *host_extension(const clap_host_t *host, const char *id) { (void)host; (void)id; return NULL; }
static void host_request(const clap_host_t *host) { (void)host; }
static const clap_host_t host = {
    .clap_version = CLAP_VERSION_INIT, .name = "Arp Stick test host", .vendor = "local", .url = "", .version = "1",
    .get_extension = host_extension, .request_restart = host_request,
    .request_process = host_request, .request_callback = host_request,
};

typedef struct {
    const clap_event_header_t *events[16];
    uint32_t count;
} input_t;
static uint32_t input_size(const clap_input_events_t *list) { return ((input_t *)list->ctx)->count; }
static const clap_event_header_t *input_get(const clap_input_events_t *list, uint32_t i) {
    input_t *input = list->ctx;
    return i < input->count ? input->events[i] : NULL;
}
typedef struct {
    uint64_t time;
    uint8_t data[3];
} recorded_t;
typedef struct {
    recorded_t events[512];
    size_t count;
    uint64_t block_start;
    uint32_t last_time;
    uint32_t block_count;
} output_t;
static bool output_push(const clap_output_events_t *list, const clap_event_header_t *header) {
    output_t *output = list->ctx;
    CHECK(header->type == CLAP_EVENT_MIDI);
    CHECK(header->size == sizeof(clap_event_midi_t));
    CHECK(header->time < 512);
    CHECK(output->block_count == 0 || header->time >= output->last_time);
    output->last_time = header->time;
    output->block_count++;
    CHECK(output->count < 512);
    recorded_t *event = &output->events[output->count++];
    event->time = output->block_start + header->time;
    memcpy(event->data, ((const clap_event_midi_t *)header)->data, 3);
    return true;
}
static clap_event_midi_t midi(uint32_t time, uint8_t status, uint8_t key, uint8_t velocity) {
    return (clap_event_midi_t){ .header = { .size = sizeof(clap_event_midi_t), .time = time, .type = CLAP_EVENT_MIDI },
        .data = { status, key, velocity } };
}
static clap_event_param_value_t param(uint32_t time, uint32_t id, double value) {
    return (clap_event_param_value_t){ .header = { .size = sizeof(clap_event_param_value_t), .time = time, .type = CLAP_EVENT_PARAM_VALUE },
        .param_id = id, .note_id = -1, .port_index = -1, .channel = -1, .key = -1, .value = value };
}
typedef struct { uint8_t data[8]; size_t position; } memory_t;
static int64_t write_state(const clap_ostream_t *stream, const void *buffer, uint64_t size) {
    memory_t *memory = stream->ctx;
    size_t n = size > 2 ? 2 : (size_t)size; // Intentionally short writes.
    CHECK(memory->position + n <= sizeof(memory->data));
    memcpy(memory->data + memory->position, buffer, n); memory->position += n;
    return (int64_t)n;
}
static int64_t read_state(const clap_istream_t *stream, void *buffer, uint64_t size) {
    memory_t *memory = stream->ctx;
    size_t n = size > 2 ? 2 : (size_t)size;
    if (memory->position + n > sizeof(memory->data)) return 0;
    memcpy(buffer, memory->data + memory->position, n); memory->position += n;
    return (int64_t)n;
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    const clap_plugin_entry_t *entry = dlsym(library, "clap_entry");
    CHECK(entry && entry->init(argv[1]));
    // CLAP 1.2 requires repeatable entry initialization.
    CHECK(entry->init(argv[1]));
    CHECK(!entry->get_factory("unknown"));
    const clap_plugin_factory_t *factory = entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    CHECK(factory && factory->get_plugin_count(factory) == 1);
    CHECK(!factory->get_plugin_descriptor(factory, 1));
    const clap_plugin_descriptor_t *desc = factory->get_plugin_descriptor(factory, 0);
    CHECK(desc && !strcmp(desc->name, "Arp Stick"));
    CHECK(!factory->create_plugin(factory, &host, "unknown"));
    const clap_plugin_t *plugin = factory->create_plugin(factory, &host, desc->id);
    CHECK(plugin && plugin->init(plugin));
    const clap_plugin_params_t *params = plugin->get_extension(plugin, CLAP_EXT_PARAMS);
    const clap_plugin_state_t *state = plugin->get_extension(plugin, CLAP_EXT_STATE);
    const clap_plugin_note_ports_t *notes = plugin->get_extension(plugin, CLAP_EXT_NOTE_PORTS);
    const clap_plugin_audio_ports_t *audio = plugin->get_extension(plugin, CLAP_EXT_AUDIO_PORTS);
    CHECK(params && state && notes && audio && params->count(plugin) == 4);
    clap_note_port_info_t note_info;
    CHECK(notes->count(plugin, true) == 1 && notes->get(plugin, 0, true, &note_info));
    CHECK(note_info.supported_dialects == CLAP_NOTE_DIALECT_MIDI);
    CHECK(notes->get(plugin, 0, false, &note_info));
    clap_audio_port_info_t audio_info;
    CHECK(audio->get(plugin, 0, false, &audio_info) && audio_info.channel_count == 2);
    for (uint32_t i = 0; i < 4; i++) {
        clap_param_info_t info; char text[256]; double value;
        CHECK(params->get_info(plugin, i, &info));
        CHECK(params->get_value(plugin, i, &value));
        CHECK(params->value_to_text(plugin, i, value, text, sizeof(text)));
        CHECK(params->text_to_value(plugin, i, text, &value));
        CHECK(value == info.default_value);
    }
    CHECK(!plugin->activate(plugin, 0, 1, 512));
    CHECK(plugin->activate(plugin, 48000, 1, 512));
    CHECK(plugin->start_processing(plugin));
    input_t input = {0};
    output_t output = {0};
    clap_input_events_t in = { .ctx = &input, .size = input_size, .get = input_get };
    clap_output_events_t out = { .ctx = &output, .try_push = output_push };
    clap_event_transport_t transport = { .header = { .size = sizeof(transport), .type = CLAP_EVENT_TRANSPORT },
        .flags = CLAP_TRANSPORT_HAS_TEMPO | CLAP_TRANSPORT_IS_PLAYING, .tempo = 120 };
    float left[512], right[512], out_left[512] = {0}, out_right[512] = {0};
    for (size_t i = 0; i < 512; i++) { left[i] = 0.125f; right[i] = -0.25f; }
    float *inputs[] = {left, right}, *outputs[] = {out_left, out_right};
    clap_audio_buffer_t audio_in = { .data32 = inputs, .channel_count = 2 };
    clap_audio_buffer_t audio_out = { .data32 = outputs, .channel_count = 2 };
    clap_process_t process = { .steady_time = 0, .frames_count = 512, .transport = &transport,
        .audio_inputs = &audio_in, .audio_outputs = &audio_out, .audio_inputs_count = 1,
        .audio_outputs_count = 1, .in_events = &in, .out_events = &out };
    clap_event_midi_t on = midi(17, 0x90, 60, 100);
    input.events[0] = &on.header; input.count = 1;
    for (size_t block = 0; block < 48; block++) {
        output.block_start = block * 512; output.block_count = 0;
        process.steady_time = (int64_t)output.block_start;
        CHECK(plugin->process(plugin, &process) == CLAP_PROCESS_CONTINUE);
        input.count = 0;
    }
    CHECK(output.count == 5);
    CHECK(output.events[0].time == 17 && output.events[0].data[1] == 60);
    CHECK(output.events[1].time == 9017 && output.events[1].data[0] == 0x80);
    CHECK(output.events[2].time == 12017 && output.events[2].data[1] == 64);
    CHECK(output.events[4].time == 24017 && output.events[4].data[1] == 67);
    CHECK(!memcmp(left, out_left, sizeof(left)) && !memcmp(right, out_right, sizeof(right)));
    transport.flags &= ~CLAP_TRANSPORT_IS_PLAYING;
    output.block_count = 0;
    CHECK(plugin->process(plugin, &process) == CLAP_PROCESS_CONTINUE);
    CHECK(output.count == 6 && output.events[5].data[0] == 0x80);

    // Sample-offset automation and MIDI CC forwarding in chord mode.
    plugin->reset(plugin); output.count = 0; output.block_count = 0; output.block_start = 0;
    clap_event_param_value_t chord_mode = param(0, 0, 0), minor = param(32, 1, 1);
    clap_event_midi_t chord_on = midi(10, 0x93, 60, 90), cc = midi(20, 0xb3, 1, 64), off = midi(100, 0x83, 60, 0);
    input.events[0] = &chord_mode.header; input.events[1] = &chord_on.header; input.events[2] = &cc.header;
    input.events[3] = &minor.header; input.events[4] = &off.header; input.count = 5;
    CHECK(plugin->process(plugin, &process) == CLAP_PROCESS_CONTINUE);
    CHECK(output.count == 9);
    CHECK(output.events[0].time == 10 && output.events[0].data[0] == 0x93);
    CHECK(output.events[3].time == 20 && output.events[3].data[0] == 0xb3);
    CHECK(output.events[4].time == 32 && output.events[4].data[0] == 0x83 && output.events[4].data[1] == 64);
    CHECK(output.events[5].time == 32 && output.events[5].data[0] == 0x93 && output.events[5].data[1] == 63);
    CHECK(output.events[8].time == 100);
    plugin->stop_processing(plugin); plugin->deactivate(plugin);

    memory_t memory = {0};
    clap_ostream_t ostream = { .ctx = &memory, .write = write_state };
    clap_istream_t istream = { .ctx = &memory, .read = read_state };
    CHECK(state->save(plugin, &ostream) && memory.position == 8);
    const clap_plugin_t *copy = factory->create_plugin(factory, &host, desc->id);
    CHECK(copy && copy->init(copy));
    const clap_plugin_state_t *copy_state = copy->get_extension(copy, CLAP_EXT_STATE);
    const clap_plugin_params_t *copy_params = copy->get_extension(copy, CLAP_EXT_PARAMS);
    memory.position = 0; CHECK(copy_state->load(copy, &istream));
    double value; CHECK(copy_params->get_value(copy, 0, &value) && value == 0);
    CHECK(copy_params->get_value(copy, 1, &value) && value == 1);
    memory.data[4] = 255; memory.position = 0; CHECK(!copy_state->load(copy, &istream));
    CHECK(copy_params->get_value(copy, 0, &value) && value == 0);
    copy->destroy(copy); plugin->destroy(plugin);
    entry->deinit(); entry->deinit();
    dlclose(library);
    puts("CLAP smoke test passed: discovery, lifecycle, MIDI ports, timing, automation, audio passthrough, transport stop, and state round-trip.");
    return 0;
}

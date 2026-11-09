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
    const clap_event_header_t *events[32];
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
    recorded_t events[1024];
    size_t count;
    uint64_t block_start;
    uint32_t last_time;
    uint32_t block_count;
} output_t;
static bool output_push(const clap_output_events_t *list, const clap_event_header_t *header) {
    output_t *output = list->ctx;
    CHECK(header->type == CLAP_EVENT_MIDI);
    CHECK(header->size == sizeof(clap_event_midi_t));
    CHECK(header->time < 16384);
    CHECK(output->block_count == 0 || header->time >= output->last_time);
    output->last_time = header->time;
    output->block_count++;
    CHECK(output->count < 1024);
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
typedef struct { uint8_t data[65536]; size_t position; } memory_t;
static int64_t write_state(const clap_ostream_t *stream, const void *buffer, uint64_t size) {
    memory_t *memory = stream->ctx;
    size_t n = size > 3 ? 3 : (size_t)size; // Intentionally short writes.
    CHECK(memory->position + n <= sizeof(memory->data));
    memcpy(memory->data + memory->position, buffer, n); memory->position += n;
    return (int64_t)n;
}
static int64_t read_state(const clap_istream_t *stream, void *buffer, uint64_t size) {
    memory_t *memory = stream->ctx;
    size_t n = size > 3 ? 3 : (size_t)size;
    if (memory->position + n > sizeof(memory->data)) return 0;
    memcpy(buffer, memory->data + memory->position, n); memory->position += n;
    return (int64_t)n;
}

typedef struct {
    const clap_plugin_t *plugin;
    clap_process_t process;
    clap_input_events_t in;
    clap_output_events_t out;
    input_t input;
    output_t output;
    clap_event_transport_t transport;
    float left[16384], right[16384], out_left[16384], out_right[16384];
    float *inputs[2], *outputs[2];
} rig_t;

static void rig_init(rig_t *r, const clap_plugin_t *plugin) {
    memset(r, 0, sizeof(*r));
    r->plugin = plugin;
    r->input.count = 0;
    r->transport.header.size = sizeof(r->transport);
    r->transport.header.type = CLAP_EVENT_TRANSPORT;
    r->transport.flags = CLAP_TRANSPORT_HAS_TEMPO;
    r->transport.tempo = 120;
    r->in = (clap_input_events_t){ .ctx = &r->input, .size = input_size, .get = input_get };
    r->out = (clap_output_events_t){ .ctx = &r->output, .try_push = output_push };
    r->inputs[0] = r->left; r->inputs[1] = r->right;
    r->outputs[0] = r->out_left; r->outputs[1] = r->out_right;
    static clap_audio_buffer_t audio_in, audio_out;
    audio_in = (clap_audio_buffer_t){ .data32 = r->inputs, .channel_count = 2 };
    audio_out = (clap_audio_buffer_t){ .data32 = r->outputs, .channel_count = 2 };
    r->process = (clap_process_t){ .transport = &r->transport, .audio_inputs = &audio_in, .audio_outputs = &audio_out,
        .audio_inputs_count = 1, .audio_outputs_count = 1, .in_events = &r->in, .out_events = &r->out };
    for (size_t i = 0; i < 16384; i++) { r->left[i] = 0.125f; r->right[i] = -0.25f; }
}
static void rig_block(rig_t *r, uint32_t frames, uint64_t start, uint32_t event_count) {
    r->input.count = event_count;
    r->output.block_start = start;
    r->output.count = 0;
    r->output.block_count = 0;
    r->output.last_time = 0;
    r->process.frames_count = frames;
    r->process.steady_time = (int64_t)start;
    CHECK(r->plugin->process(r->plugin, &r->process) == CLAP_PROCESS_CONTINUE);
    r->input.count = 0;
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
    CHECK(params && state && notes && audio && params->count(plugin) == 8);
    clap_note_port_info_t note_info;
    CHECK(notes->count(plugin, true) == 1 && notes->get(plugin, 0, true, &note_info));
    CHECK(note_info.supported_dialects == CLAP_NOTE_DIALECT_MIDI);
    CHECK(notes->get(plugin, 0, false, &note_info));
    clap_audio_port_info_t audio_info;
    CHECK(audio->get(plugin, 0, false, &audio_info) && audio_info.channel_count == 2);
    const double defaults[8] = { 1, 1, 0, 0, 0, 0, 0, 0 };
    for (uint32_t i = 0; i < 8; i++) {
        clap_param_info_t info; char text[256]; double value;
        CHECK(params->get_info(plugin, i, &info));
        CHECK(info.min_value <= info.default_value && info.default_value <= info.max_value);
        CHECK(info.default_value == defaults[i]);
        CHECK(params->get_value(plugin, i, &value));
        CHECK(params->value_to_text(plugin, i, value, text, sizeof(text)));
        CHECK(params->text_to_value(plugin, i, text, &value));
        CHECK(value == info.default_value);
    }
    CHECK(!plugin->activate(plugin, 0, 1, 512));
    CHECK(plugin->activate(plugin, 48000, 1, 512));
    CHECK(plugin->start_processing(plugin));

    rig_t rig;
    rig_init(&rig, plugin);

    // ---- chord module: factory minor triad, preserved channel ----
    clap_event_param_value_t arp_off = param(0, 1, 0);
    clap_event_midi_t chord_root = midi(10, 0x93, 60, 90);
    rig.input.events[0] = &arp_off.header;
    rig.input.events[1] = &chord_root.header;
    rig_block(&rig, 512, 0, 2);
    CHECK(rig.output.count == 3);
    CHECK(rig.output.events[0].time == 10 && rig.output.events[0].data[0] == 0x93 && rig.output.events[0].data[1] == 60);
    CHECK(rig.output.events[1].data[1] == 63 && rig.output.events[2].data[1] == 67);
    clap_event_midi_t chord_release = midi(5, 0x83, 60, 0);
    rig.input.events[0] = &chord_release.header;
    rig_block(&rig, 512, 512, 1);
    CHECK(rig.output.count == 3 && (rig.output.events[0].data[0] & 0xf0) == 0x80);
    CHECK(!memcmp(rig.left, rig.out_left, 512 * sizeof(float)) && !memcmp(rig.right, rig.out_right, 512 * sizeof(float)));

    // ---- arp module: ascending free-clock 16ths and CC passthrough ----
    plugin->reset(plugin);
    clap_event_param_value_t chord_off = param(0, 0, 0), arp_on = param(0, 1, 1);
    clap_event_midi_t n1 = midi(0, 0x90, 60, 100), n2 = midi(0, 0x90, 52, 100), n3 = midi(0, 0x90, 55, 100);
    clap_event_midi_t cc = midi(5, 0xb0, 1, 64);
    rig.input.events[0] = &chord_off.header; rig.input.events[1] = &arp_on.header;
    rig.input.events[2] = &n1.header; rig.input.events[3] = &n2.header; rig.input.events[4] = &n3.header;
    rig.input.events[5] = &cc.header;
    rig_block(&rig, 6000, 0, 6);
    CHECK(rig.output.count == 2);
    CHECK(rig.output.events[0].data[1] == 52 && rig.output.events[0].time == 0);
    CHECK(rig.output.events[1].data[0] == 0xb0 && rig.output.events[1].time == 5);
    rig_block(&rig, 6000, 6000, 0);
    CHECK(rig.output.count == 2 && rig.output.events[0].data[0] == 0x80 && rig.output.events[0].data[1] == 52);
    CHECK(rig.output.events[1].data[0] == 0x90 && rig.output.events[1].data[1] == 55);
    rig_block(&rig, 6000, 12000, 0);
    CHECK(rig.output.count == 2 && rig.output.events[0].data[0] == 0x80 && rig.output.events[0].data[1] == 55);
    CHECK(rig.output.events[1].data[0] == 0x90 && rig.output.events[1].data[1] == 60);
    rig_block(&rig, 6000, 18000, 0);
    CHECK(rig.output.events[1].data[0] == 0x90 && rig.output.events[1].data[1] == 52);

    // ---- module change releases generated notes ----
    plugin->reset(plugin);
    clap_event_param_value_t chord_on = param(0, 0, 1), arp_disable = param(0, 1, 0);
    clap_event_midi_t late_root = midi(0, 0x90, 64, 80);
    rig.input.events[0] = &chord_off.header; rig.input.events[1] = &arp_on.header;
    rig.input.events[2] = &late_root.header;
    rig_block(&rig, 512, 0, 3);
    rig.input.events[0] = &chord_on.header; rig.input.events[1] = &arp_disable.header;
    rig_block(&rig, 512, 512, 2);
    size_t offs = 0;
    for (size_t i = 0; i < rig.output.count; i++) if ((rig.output.events[i].data[0] & 0xf0) == 0x80) offs++;
    CHECK(offs >= 1);

    // ---- MIDI remote: pattern select, chord-note edit, cell edit ----
    plugin->reset(plugin);
    rig.output.count = 0;
    clap_event_param_value_t r_chord = param(0, 0, 1), r_arp = param(0, 1, 0), r_remote = param(0, 6, 1);
    clap_event_midi_t remote_pattern = midi(0, 0xb2, 2, 0);
    clap_event_midi_t remote_note = midi(1, 0xb1, 101, 72);
    clap_event_midi_t remote_cell = midi(2, 0xb1, 3, 0);
    rig.input.events[0] = &r_chord.header; rig.input.events[1] = &r_arp.header; rig.input.events[2] = &r_remote.header;
    rig.input.events[3] = &remote_pattern.header; rig.input.events[4] = &remote_note.header; rig.input.events[5] = &remote_cell.header;
    rig_block(&rig, 64, 0, 6);
    double remote_value = -1;
    CHECK(params->get_value(plugin, 7, &remote_value) && remote_value == 2);

    // The edited voice is audible when the slot is triggered.
    clap_event_midi_t remote_verify = midi(0, 0x90, 60, 100);
    rig.input.events[0] = &remote_verify.header;
    rig_block(&rig, 64, 64, 1);
    bool heard_72 = false;
    for (size_t i = 0; i < rig.output.count; i++)
        if ((rig.output.events[i].data[0] & 0xf0) == 0x90 && rig.output.events[i].data[1] == 72) heard_72 = true;
    CHECK(heard_72);
    clap_event_midi_t remote_off = midi(0, 0x80, 60, 0);
    rig.input.events[0] = &remote_off.header;
    rig_block(&rig, 64, 128, 1);

    memory_t remote_memory = {0};
    clap_ostream_t remote_stream = { .ctx = &remote_memory, .write = write_state };
    CHECK(state->save(plugin, &remote_stream));
    // magic(4) + version(2) + params(32) + curSlot(4) + watched(16) = 58
    int32_t saved_slot = 0;
    memcpy(&saved_slot, remote_memory.data + 38, sizeof(saved_slot));
    CHECK(saved_slot >= 0 && saved_slot < 128);
    CHECK(remote_memory.data[58 + saved_slot * 8] == 72);

    // ---- test tone mixes a poly saw after the passthrough ----
    plugin->reset(plugin);
    rig.output.count = 0;
    clap_event_param_value_t t_tone = param(0, 4, 100);
    clap_event_midi_t tone_note = midi(0, 0x90, 60, 100);
    rig.input.events[0] = &r_chord.header; rig.input.events[1] = &r_arp.header; rig.input.events[2] = &t_tone.header;
    rig.input.events[3] = &tone_note.header;
    rig_block(&rig, 512, 0, 4);
    double tone_energy = 0;
    for (size_t i = 0; i < 512; i++) tone_energy += fabs(rig.out_left[i] - 0.125);
    CHECK(tone_energy > 1.0);
    clap_event_param_value_t t_off = param(0, 4, 0);
    rig.input.events[0] = &t_off.header;
    rig_block(&rig, 512, 512, 1);

    // ---- latch keeps the last chord until a new root ----
    plugin->reset(plugin);
    rig.output.count = 0;
    clap_event_param_value_t l_latch = param(0, 3, 1);
    clap_event_midi_t latch_on = midi(0, 0x90, 60, 100);
    clap_event_midi_t latch_off = midi(5, 0x80, 60, 0);
    rig.input.events[0] = &l_latch.header; rig.input.events[1] = &latch_on.header;
    rig_block(&rig, 128, 0, 2);
    CHECK(rig.output.count == 3);
    rig.input.events[0] = &latch_off.header;
    rig_block(&rig, 128, 128, 1);
    CHECK(rig.output.count == 0);
    clap_event_midi_t latch_next = midi(0, 0x90, 62, 100);
    rig.input.events[0] = &latch_next.header;
    rig_block(&rig, 128, 256, 1);
    CHECK(rig.output.count == 6); // three offs for slot 60 plus three ons for slot 62
    clap_event_param_value_t l_off = param(0, 3, 0);
    rig.input.events[0] = &l_off.header;
    rig_block(&rig, 64, 384, 1);

    // ---- state round-trip and corruption rejection ----
    clap_event_param_value_t pattern = param(0, 7, 3);
    rig.input.events[0] = &pattern.header;
    rig_block(&rig, 64, 0, 1);
    double value;
    CHECK(params->get_value(plugin, 7, &value) && value == 3);
    memory_t memory = {0};
    clap_ostream_t ostream = { .ctx = &memory, .write = write_state };
    clap_istream_t istream = { .ctx = &memory, .read = read_state };
    CHECK(state->save(plugin, &ostream) && memory.position > 4000);
    const clap_plugin_t *copy = factory->create_plugin(factory, &host, desc->id);
    CHECK(copy && copy->init(copy));
    const clap_plugin_state_t *copy_state = copy->get_extension(copy, CLAP_EXT_STATE);
    const clap_plugin_params_t *copy_params = copy->get_extension(copy, CLAP_EXT_PARAMS);
    memory.position = 0; CHECK(copy_state->load(copy, &istream));
    CHECK(copy_params->get_value(copy, 7, &value) && value == 3);
    // Every parameter's rendered text parses back, including "CH 6".
    clap_event_param_value_t out_six = param(0, 5, 6);
    rig.input.events[0] = &out_six.header;
    rig_block(&rig, 8, 0, 1);
    char channel_text[64];
    CHECK(params->get_value(plugin, 5, &value) && value == 6);
    CHECK(params->value_to_text(plugin, 5, value, channel_text, sizeof(channel_text)));
    CHECK(!strcmp(channel_text, "CH 6"));
    CHECK(params->text_to_value(plugin, 5, channel_text, &value) && value == 6);
    memory_t memory2 = {0};
    clap_ostream_t ostream2 = { .ctx = &memory2, .write = write_state };
    CHECK(copy_state->save(copy, &ostream2));
    CHECK(memory2.position == memory.position && !memcmp(memory.data, memory2.data, memory.position));
    memory.data[4] = 255; memory.position = 0; CHECK(!copy_state->load(copy, &istream));
    CHECK(copy_params->get_value(copy, 7, &value) && value == 3);
    copy->destroy(copy); plugin->destroy(plugin);
    entry->deinit(); entry->deinit();
    dlclose(library);
    puts("CLAP smoke test passed: 8 parameters, chord/arp engines, CC forwarding, audio passthrough, and state round-trip.");
    return 0;
}

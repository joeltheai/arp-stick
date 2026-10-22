Official CLAP headers, version 1.2.9, commit cd94482ba5941ae410809b6fbaed3bc851044270.
Source: https://github.com/free-audio/clap/tree/1.2.9
Only include/ and the upstream MIT LICENSE are vendored. Plugin implementation is Zig.

Local compatibility patch: #pragma once is replaced with equivalent include guards in headers. This avoids duplicate declarations through ../ include paths in Zig 0.16 translate-c. No ABI declarations are changed.

#ifndef ARPSTICK_CLAP_PRIVATE_STD_H
#define ARPSTICK_CLAP_PRIVATE_STD_H

#include "macros.h"

#ifdef CLAP_HAS_CXX11
#   include <cstdint>
#else
#   include <stdint.h>
#endif

#ifdef __cplusplus
#   include <cstddef>
#else
#   include <stddef.h>
#   include <stdbool.h>
#endif

#endif /* ARPSTICK_CLAP_PRIVATE_STD_H */

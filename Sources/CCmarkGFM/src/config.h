/* Hand-written equivalent of the CMake-generated config.h for cmark-gfm
 * 0.29.0.gfm.13, targeting clang on macOS (see PATCHES.md). */
#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

#define HAVE_STDBOOL_H

#ifdef HAVE_STDBOOL_H
  #include <stdbool.h>
#elif !defined(__cplusplus)
  typedef char bool;
#endif

#define HAVE___BUILTIN_EXPECT

#define HAVE___ATTRIBUTE__

#ifdef HAVE___ATTRIBUTE__
  #define CMARK_ATTRIBUTE(list) __attribute__ (list)
#else
  #define CMARK_ATTRIBUTE(list)
#endif

#ifndef CMARK_INLINE
  #if defined(_MSC_VER) && !defined(__cplusplus)
    #define CMARK_INLINE __inline
  #else
    #define CMARK_INLINE inline
  #endif
#endif

/* snprintf and vsnprintf fallbacks for MSVC before 2015 */
#if defined(_MSC_VER) && _MSC_VER < 1900 && !defined(__cplusplus)
#include <stdio.h>
#define snprintf c99_snprintf
#endif

#ifdef __cplusplus
}
#endif

#endif

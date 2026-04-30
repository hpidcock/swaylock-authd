/* Default configuration values, overridden at build time via -D flags. */
#pragma once

#ifndef SYSCONFDIR
#define SYSCONFDIR "/etc"
#endif

#ifndef SWAYLOCK_VERSION
#define SWAYLOCK_VERSION "unknown"
#endif

#ifndef HAVE_GDK_PIXBUF
#define HAVE_GDK_PIXBUF 0
#endif

#ifndef HAVE_QRENCODE
#define HAVE_QRENCODE 0
#endif

#ifndef HAVE_DEBUG_OVERLAY
#define HAVE_DEBUG_OVERLAY 0
#endif

#ifndef HAVE_DEBUG_UNLOCK_ON_CRASH
#define HAVE_DEBUG_UNLOCK_ON_CRASH 0
#endif
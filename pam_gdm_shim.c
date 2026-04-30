/*
 * pam_gdm_shim.c – thin C wrappers around the authd GDM static-inline
 * helpers that rely on GNU statement-expression macros.  These cannot be
 * translated by Zig's C front-end, so pam.zig calls these wrappers instead.
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include <stdlib.h>
#include <string.h>

#include "gdm/authd-gdm-extension.h"

void
pam_shim_gdm_advertise_extensions(void)
{
	authd_gdm_advertise_extensions();
}

void
pam_shim_gdm_request_init(GdmPamExtensionJSONProtocol *req, char *json)
{
	authd_gdm_request_init(req, json);
}
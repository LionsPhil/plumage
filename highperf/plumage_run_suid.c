/* Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License v3 or later.
 * See LICENSE.txt for details. */

/* SUID passthrough wrapper for plumage_run.
 * Performs environment tuning that requires root, then drops back to the
 * original user; plumage_run itself never gets elevated.
 * Build this, put it in PlumageClient/bin/ (probably), make it setuid root,
 * and change your plumageclient.json configuration to point to it.
 * If used non-root, this program warns but still passes through. */

#define _POSIX_C_SOURCE 200112L

#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/resource.h>

/* For security you should hardcode this to the plumage_run path. */
#ifndef PLUMAGE_RUN
#define PLUMAGE_RUN "/opt/plumage/PlumageClient/bin/plumage_run"
#endif
const char* plumage_run = PLUMAGE_RUN ;

/* RLIM_INFINITY would be nice here but is forbidden on stock Ubuntu Server
 * 14.04 LTS; assume this is generally the case for modern Linux. */
#ifndef FILE_LIMIT
#define FILE_LIMIT 128000
#endif
const rlim_t file_limit = FILE_LIMIT;

int main(int argc, char** argv) {
	/* If we are root, set up the environment. */
	if(geteuid() == 0) {
		/* Raise the open file limit; our child polygraph processes can easily
		 * max common defaults under high loads long before exhausting other
		 * system resources. */
		struct rlimit all_you_can_eat;
		all_you_can_eat.rlim_cur = file_limit;
		all_you_can_eat.rlim_max = file_limit;
		if(setrlimit(RLIMIT_NOFILE, &all_you_can_eat) != 0) {
			perror("plumage_run_suid: could not raise open file limit");
		}

		/* Drop back to the effective user and group */
		if((seteuid(getuid()) != 0) || (setegid(getgid()) != 0)) {
			perror("plumage_run_suid: could not drop privileges");
			return EXIT_FAILURE; /* * * * * * EARLY RETURN to bail out */
		}
	} else {
		/* Emit a warning, since this is unusual. */
		fputs("plumage_run_suid: not root, taking no additional action\n",
			stderr);
	}

	/* Become the plumage_run process.
	 * (It is standard that argv is appropriately terminated.) */
	execv(plumage_run, argv);

	/* If we got here, execv() failed, abandon ship. */
	perror("plumage_run_suid: could not execute plumage_run");
	return EXIT_FAILURE;
}

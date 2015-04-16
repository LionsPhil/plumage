# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::AsyncProcess;

=head1 Plumage::AsyncProcess

Asynchronous process support for Plumage (or, with a little work, similar environments).

We do this ourselves the long way so we can grab the PID (which IPC::Run doesn't allow) and re-open filehandles (which Proc::Background doesn't).
We also need to double-fork; this is very important as we will not be back to waitpid on the child, and if you just ignore SIGCHLD this persists into the polygraph process and breaks it in mysterious ways.

These are just package-namespaced methods.
There's no useful instance state to preserve since the whole point is that they may be called by different, isolated server worker processes across time.

=cut

# This is currently tested as a side-effect of testing PolygraphServerRun.
# The coverage is not amazing as a result (plus a lot of failure branches that
# are difficult to mock).

use Carp;
use File::Slurp;
use POSIX;

=head2 spawn($pidfile, $workingdir, $command, $stdin, $stdout, $stderr)

Creates a new, fully-detached, child process.
This child does not need to be waited upon and will not create zombies.
This is more of a "CreateProcess" API than a "fork and exec" API.

=over 4

=item pidfile

Filename to store the PID of the child in, so that it can be picked up by subsequent calls.

=item workingdir

Directory to set as the current working directory the command, if defined.

=item command

Arrayref of command and arguments to execute.

=item stdin, stdout, stderr

Filenames to re-open STDIN, STDOUT, and STDERR to, respectively.
stderr can be undefined to open it to point to STDOUT.

=back

Throws on errors within the parent; will not detect if the child exits with errors.
Croaks on usage errors.
Returns nothing.

=cut

sub spawn {
	my ($pidfile, $workingdir, $command, $stdin, $stdout, $stderr) = @_;

	croak "pidfile must be provided" unless defined $pidfile;
	croak "command arrayref must be provided"
		unless ((defined $command) && (ref $command eq 'ARRAY'));
	croak "stdin must be provided" unless defined $stdin;
	croak "stdout must be provided" unless defined $stdout;

	# We consider where we are now (the caller) to be the grandparent process.

	my $intermediate_pid = fork();
	if(!defined $intermediate_pid) {

		die "Couldn't fork: $!\n";

	} elsif($intermediate_pid) {

		# We're still the grandparent.
		# Wait for the intermediate process to finish, so that it doesn't
		# become a zombie.
		waitpid $intermediate_pid, 0;
		my $return = ($? >> 8);
		die "Intermediate process returned $return!\n" if $return;
		# And now we resume control flow.

	} else {

		# We're the intermediate process.
		# Fork for the process to become the executed command.
		my $pid = fork();
		if(!defined $pid) {

			# Don't die; mustn't risk invoking handlers.
			print STDERR "Couldn't fork: $!\n";
			POSIX::_exit(1);

		} elsif($pid) {

			# We're still the intermediate process.
			# Record the pid of the server process (with newline for
			# convention).
			unless(write_file(
				$pidfile,
				{ err_mode => 'carp' },
				"$pid\n"))
			{
				# write_file has already generated a message to STDERR.
				POSIX::_exit(1);
			}
			# Resume from here (will shall then hit an _exit).

		} else {

			# We're the grandchild process.
			# We need to detach from the parents.

			# Set a new session
			if(POSIX::setsid() == -1) {
				print STDERR "Couldn't set session: $!\n";
				POSIX::_exit(1);
			}

			# Set the working directory
			if(defined $workingdir) {
				unless(chdir $workingdir) {
					print STDERR "Couldn't change directory: $!\n";
					POSIX::_exit(1);
				}
			}

			# Re-open filehandles
			unless(
				open(STDIN,  '<',  $stdin             ) &&
				open(STDOUT, '>',  $stdout            ) &&
				open(STDERR, '>&', $stderr // \*STDOUT)) {

				print STDERR "Couldn't re-open filehandles: $!\n";
				POSIX::_exit(1);
			}

			# Now become the target command.
			# The gratuitous block here is the diagnostics module's
			# recommended way to suppress Perl warning about the "unlikely"
			# reachable not-just-die overrun code below. The block immediately
			# after exec is to guard against a one-element @$command; see
			# perldoc -f exec.
			{ exec { $command->[0] } @$command; }

			# Don't overrun
			print STDERR "Couldn't execute command: $!\n";
			POSIX::_exit(1);

		}

		# Intermediate gets to here.
		# Stop successfully, but don't run d'tors etc. because we're a fork.
		POSIX::_exit(0);

	}

	# Grandparent gets to here.
	# We don't know the PID; the intermediate wrote it into a file then exited.
	undef;
}

=head2 kill_kill($grace, @pids)

Given a list of process IDs, kill the child processes semi-gracefully (INT then KILL, with up to C<grace> seconds given for them to respond to INT).

This may cause a short delay between the signals.
Since this is intended to be an asynchronous library, it should not greatly exceed the grace period.

Note that this takes PIDs, not pidfiles.
It is expected the caller has routines to pluck pids from sets of pidfiles based on its pidfile organization strategy.
Trying to kill processes you cannot signal will not do anything useful.

=cut

sub kill_kill {
	my ($grace, @pids) = @_;

	# Send SIGINT
	kill(2, @pids);

	# Wait for up to a second
	for(my $timeout = $grace * 10; $timeout > 0; --$timeout) {
		# Sleep a little for them to react
		select undef, undef, undef, 0.1;
		# Escape the loop if nothing signalable is left
		last if kill(0, @pids) <= 0;
	}

	# Send SIGKILL to be sure even if we didn't time out
	kill(9, @pids);
}

1;

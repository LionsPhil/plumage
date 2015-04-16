# Copyright 2014-2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PolygraphServerRun;

=head1 PolygraphServerRun

Represents a run (execution with a given config) of the polygraph server side.
Runs on the server side are short-lived runtime state.

This is B<NOT> safe against concurrent access to the same run ID, nor
concurrent construction.

=cut

use File::Slurp qw();
use FindBin;
use IO::Dir;
use JSON;
use POSIX;
# There are many better-looking CPU-count modules, like Unix::Processors,
# Sys::CpuAffinity, and Sys::Info::Device::CPU. But this is the only one Ubuntu
# packages. Which is somebody's hacked-up subset of Unix::Processors. Oh well.
use Sys::CPU;

use Plumage::AsyncProcess;
use Plumage::Common;

# These are pseudo-constants mostly for historic reasons.
# They get default values if not specified in the configuration.
our $STATE_DIR               = '/run/plumage/';
our $POLYGRAPH_SERVER_BINARY = '/usr/bin/polygraph-server';
our $AGENT_PREFIX            = '127.0.2';
our $AGENT_OCTET_MIN         = 2;
our $AGENT_OCTET_MAX         = 65;

# Private method to load configuration used by both c'tors.
# Doing this in a BEGIN block doesn't work under Dancer.
sub _load_configuration {
	my $config_filename = "$FindBin::Bin/../etc/plumageserver.json";
	my $config = decode_json(File::Slurp::read_file($config_filename));
	$STATE_DIR               = $config->{'state_dir'              } // $STATE_DIR;
	$POLYGRAPH_SERVER_BINARY = $config->{'polygraph_server_binary'} // $POLYGRAPH_SERVER_BINARY;
	$AGENT_PREFIX            = $config->{'agent_prefix'           } // $AGENT_PREFIX;
	$AGENT_OCTET_MIN         = $config->{'agent_octet_min'        } // $AGENT_OCTET_MIN;
	$AGENT_OCTET_MAX         = $config->{'agent_octet_max'        } // $AGENT_OCTET_MAX;
}

=head2 new(configuration, supporting)

Creates a brand new run, with a new unique ID, then starts execution of the server using the given configuration.

See L<Plumage::Common::write_polygraph_config> for the format of the arguments.

While the API is asynchronous, even if the machine and network infrastructure were beefy enough to be valid, multiple concurrent server runs are unlikely to succeed due to wanting to bind to ports which will be in use.

Because the API is asychronous, this cannot tell if Polygraph choked on the configuration and bombed out almost immediately.

=cut

sub new {
	my ($class, $configuration, $supporting) = @_;

	_load_configuration();

	# Carve out our runtime state space
	# FIXME should clean this up again if the c'tor throws
	my ($id, $runstatedir) = Plumage::Common::make_state_subdirectory($STATE_DIR);

	# Store the configuration in it
	Plumage::Common::write_polygraph_configuration($runstatedir, $configuration, $supporting);

	# Work out how many processes to run, and with which addresses each
	my @ranges = Plumage::Common::ip_ranges(
		$AGENT_PREFIX, $AGENT_OCTET_MIN, $AGENT_OCTET_MAX,
		Sys::CPU::cpu_count());

	# Start the processes
	my $pnum = 0;
	foreach my $range (@ranges) {
		Plumage::AsyncProcess::spawn(
			"$runstatedir/polygraph$pnum.pid", # pidfile
			$runstatedir, # working directory
			[ $POLYGRAPH_SERVER_BINARY,
				'--config', 'configuration.pg',
				'--verb_lvl', '10',
				'--log', "binary$pnum.log",
				'--idle_tout', '1min',
				'--fake_hosts', $range ], # command
			'/dev/null', # STDIN
			"$runstatedir/console$pnum.log", # STDOUT
			undef, # STDERR (to STDOUT)
		);
		++$pnum;
	}

	return bless({
		id          => $id,
		runstatedir => $runstatedir,
	}, $class);
}

=head2 new_existing(id)

Creates a representation of an existing run, by ID.

Returns undef if no run by that ID exists.

=cut

# The use of an undef return over an exception makes for simpler code (and
# lighter dependencies) given the very limited use cases of this class.

sub new_existing {
	my ($class, $id) = @_;

	_load_configuration();

	# This also validates the ID
	my $runstatedir = Plumage::Common::find_state_subdirectory($STATE_DIR, $id);
	return undef unless defined $runstatedir;

	return bless({
		id          => $id,
		runstatedir => $runstatedir,
	}, $class);
}

=head2 id()

Returns the ID of this run.

IDs are guaranteed to be simple strings using no more than alphanumerics and hypens.

=cut

sub id {
	my ($self) = @_;
	return $self->{id};
}

# Private method: return the runstatedir for this instance
# Also sanity checks that it's still around, e.g. if someone tries to use an
# instance after calling delete(). This isn't race condition protection, but as
# documented we do not support concurrent unsynchronized access to the same ID.
sub _runstatedir {
	my ($self) = @_;
	my $runstatedir = $self->{runstatedir};
	die "Runtime state directory '$runstatedir' went missing"
		unless -d $runstatedir;
	return $runstatedir;
}

=head2 server_ids()

Returns a list of the server process IDs.
This is not their PIDs; this is a low opaque integer which you can pass to console() etc.

=cut

# Don't want the API to enforce that these must be contiguous starting from zero
sub server_ids {
	my ($self) = @_;
	my @pnums;
	my $pnum = 0;
	while(-e ($self->_runstatedir() . "/polygraph$pnum.pid")) {
		push @pnums, $pnum;
		++$pnum;
	}
	return @pnums;
}

# Private method: get the PIDs of the server processes as a list
sub _polygraphpids {
	my ($self) = @_;
	my @pids;
	my $pnum = 0;
	my $pidfile;
	while(-e ($pidfile = $self->_runstatedir() . "/polygraph$pnum.pid")) {
		my $pid = File::Slurp::read_file($pidfile);
		chomp $pid;
		push @pids, $pid;
		++$pnum;
	}
	return @pids;
}

=head2 running()

Returns true if any of the server processes are still running.

=cut

sub running {
	my ($self) = @_;
	my $running = 0;
	foreach my $pid ($self->_polygraphpids()) {
		# This could be more robust against PID recycling.
		# We can hopefully get away that runs should not be that long-living.
		# We do not use kill with signal 0 here as we may not be permitted to
		# signal the process even if it exists (different parent).
		my @stats = stat("/proc/$pid");
		$running = 1 if @stats;
	}
	return $running;
}

# XXX Being redesigned; see routes

#=head2 cpu()
#
#Return the proportional CPU usage of the server process, from 0 to 1.
#This is intended to indicate if Polygraph may be overwhelmed.
#If this reaches or sits uncomfortably near to 1 during the run, that is a bad sign.
#Undefined if the process is not running.
#
#=cut
#
## As such, if this ever wraps a multi-process Polygraph server, take the max,
## not average or sum, of their CPU loadings.
#
#sub cpu {
#	# Currently unimplemented because the information is hard to get;
#	# requiring an instantaneous sample of a cumulative measure with no history
#	...; # TODO
#}

=head2 output($serverid)

Returns the standard output of the server process.

This is valid even if it hasn't finished yet.

=cut

# XXX Depending on streaming mechanism, may be better served by filehandle?
sub output {
	my ($self, $serverid) = @_;
	die "Invalid server ID\n" unless $serverid =~ /^[0-9]+$/;
	return scalar File::Slurp::read_file($self->_runstatedir() . "/console$serverid.log");
}

=head2 log($serverid)

Returns the binary Polygraph log content if the server has finished.

If it has not finished, returns undef.

=cut

sub log {
	my ($self, $serverid) = @_;
	die "Invalid server ID\n" unless $serverid =~ /^[0-9]+$/;
	return undef if $self->running();
	return scalar File::Slurp::read_file($self->_runstatedir() . "/binary$serverid.log");
}

=head2 delete()

Clean up records of the run, including the output and log.

If the server process is still running, it will be killed.

After this, the object is not valid and must be destroyed.
Any other use of the object is undefined behaviour.

=cut

sub delete {
	my ($self) = @_;

	# Kill the process; very little grace because we're serving a web request
	if($self->running()) {
		Plumage::AsyncProcess::kill_kill(1, $self->_polygraphpids());
	}

	# Delete things (manually, to avoid scope for fun bugs with rmtree)
	my $runstatedir = $self->_runstatedir();

	Plumage::Common::delete_polygraph_configuration($runstatedir);

	foreach my $pnum ($self->server_ids()) {
		unlink "$runstatedir/polygraph$pnum.pid"
			or die "Deleting pidfile $pnum failed: $!\n";
		unlink "$runstatedir/console$pnum.log"
			or die "Deleting console log $pnum failed: $!\n";
		# Nonfatal if polygraph died so badly it never wrote its log
		unlink "$runstatedir/binary$pnum.log"
			or warn "Deleting binary log $pnum failed: $!\n";
	}

	rmdir $runstatedir
		or die "Deleting state directory failed: $!\n";
}

1;

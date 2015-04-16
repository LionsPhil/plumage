# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PlumageClientRun;

=head1 PlumageClientRun

Note that this is PlumageClientRun, c.f. PolygraphServerRun, since it deals with
the Plumage-specific C<plumage_run> co-ordinator script, rather than directly
with Polygraph client processes.
C<plumage_run> is a separate unit because it must perform various glue actions,
including delays, which do not fit in a stateless, asynchronous web service
library.

This is B<NOT> safe for concurrent access to the same ID, nor concurrent
construction.

=cut

use DateTime;
use File::Path qw();
use File::Slurp qw();
use FindBin;
use IPC::Run qw();
use IO::Dir;
use JSON;
use Template;

use Plumage::AsyncProcess;
use Plumage::Common;

# These are pseudo-constants mostly for historic reasons.
# The get default values if not specified in the configuration.
our $STATE_DIR = '/run/plumage/';
our $PLUMAGE_RUN_BINARY = "$FindBin::Bin/plumage_run"; # default is dynamic
our $TAR_BINARY = '/bin/tar';
# Other host config, and the polygraph client binary, are handled in plumage_run.

# Private method to load configuration used by both c'tors.
# Unlike the server version, returns a hashref of host parameters.
sub _load_configuration {
	my $config_filename = "$FindBin::Bin/../etc/plumageclient.json";
	my $config = decode_json(File::Slurp::read_file($config_filename));
	$STATE_DIR          = $config->{'state_dir'              } // $STATE_DIR;
	$PLUMAGE_RUN_BINARY = $config->{'plumage_run_binary'     } // $PLUMAGE_RUN_BINARY;
	$TAR_BINARY         = $config->{'tar_binary'             } // $TAR_BINARY;

	return $config->{'host_parameters'} // {};
}

=head2 new(configuration_template, template_params, supporting, notify)

Creates a brand new run, with a new unique ID, then starts execution of the
co-ordinator using the given configuration.

The configuration_template is the actual template text to process into a PGL
configuration, not a filename.
template_params are merged with host-specific parameters to process the
template.
Conflicting keys will cause an exception since either taking precidence would
be error-prone.

See L<Plumage::Common::write_polygraph_config> for the format of the supporting argument.

C<notify> is passed through to plumage_run for notification behaviour.

Because the API is asychronous, this cannot tell if Polygraph choked on the
configuration and bombed out almost immediately.

=cut

sub new {
	my ($class, $configuration_template, $template_params, $supporting, $notify) = @_;

	# Load configuration, including host-specific parameters, e.g. IP address
	# prefixes for this Polygraph pair.
	my $host_params = _load_configuration();

	# Merge host-specific variables into the template parameters
	foreach my $key (keys %$host_params) {
		if(exists $template_params->{$key}) {
			die "Template parameter '$key' conflicts with host configuration\n";
		}
		$template_params->{$key} = $host_params->{$key};
	}

	# Carve out our runtime state space
	# FIXME should clean this up again if the c'tor throws
	my ($id, $runstatedir) = Plumage::Common::make_state_subdirectory($STATE_DIR);

	# Under this make the statedir for plumage_run
	my $plumagerunstatedir = "$runstatedir/pr/";
	mkdir $plumagerunstatedir or die "Couldn't make state subdirectory: $!\n";

	# Under *that* make the configuration directory
	my $configstatedir = "$plumagerunstatedir/configuration/";
	mkdir $configstatedir or die "Couldn't make config subdirectory: $!\n";

	# Run configuration through Template::Toolkit.
	# We set INCLUDE_PATH, but the supporting files aren't written there yet,
	# so you can't actually make use of this to break the template across
	# multiple files. The only effect is to define it to something sane.
	my $tt = Template->new({
		INCLUDE_PATH => $configstatedir,
		POST_CHOMP   => 1,
	});

	my $configuration;
	$tt->process(
		\$configuration_template,
		$template_params,
		\$configuration,
	) or die "Template processing failed: ".$tt->error()."\n";

	# Store the now fully-templated configuration (and supporting files)
	Plumage::Common::write_polygraph_configuration($configstatedir, $configuration, $supporting);

	# Work out a safe report name
	my $reportname = 'Plumage';
	if($configuration =~ m!^//plumage//reportname//(.*)$!m) {
		$reportname = $1;
		# Chomp only cares about local line-endings; we can get MS-DOS ones,
		# because templates come from mutli-line text fields in a web interface,
		# and <textarea> is defined to always be MS-DOS.
		$reportname =~ s/[\r\n]$//g;
		# This duplicates a check in plumage_run, since that check comes after
		# process creation and is too late to give clean, early error reporting
		# (it will instead successfully create a run that immediately bombs
		# out).
		die "Forbidden characters in report name '$reportname'\n"
			if $reportname =~ m/[^a-zA-Z0-9.:_-]/;
	}

	# Append a datestamp; local time is most useful for display here.
	# Replace the colons with more hyphens.
	$reportname .= '_'.DateTime->now(time_zone => 'local')->iso8601();

	# Start plumage_run. It handles the rest of the wrangling, including
	# working out agent IP ranges and co-ordinating with the server.
	Plumage::AsyncProcess::spawn(
		"$runstatedir/plumage_run.pid", # pidfile
		$plumagerunstatedir, # working directory
		[ $PLUMAGE_RUN_BINARY,
			$reportname,
			$plumagerunstatedir,
			$notify // '' ], # command
		'/dev/null', # STDIN
		"$runstatedir/plumage_run.log", # STDOUT
		undef, # STDERR (to STDOUT)
	);

	return bless({
		id          => $id,
		runstatedir => $runstatedir,
	}, $class);
}

=head2 new_existing(id)

Creates a representation of an existing run, by ID.

Returns undef if no run by that ID exists.

=cut

# See PolygraphServerRun for the rationale for undef over exceptions here.

sub new_existing {
	my ($class, $id) = @_;

	_load_configuration();

	# This also validates the ID
	my $runstatedir = Plumage::Common::find_state_subdirectory($STATE_DIR, $id);
	return undef unless defined $runstatedir;

	return bless({
		id => $id,
		runstatedir => $runstatedir,
	}, $class);
}

=head2 id()

Returns the ID of this run.

IDs are guaranteed to be simple strings using no more than alphanumerics and
hypens.

=cut

sub id {
	my ($self) = @_;
	return $self->{id};
}

# Private method: return the runstatedir for this instance
# Also sanity checks that it's still around, e.g. if someone tries to use an
# instance after calling delete(). This isn't race condition protection, but as
# documented we do not support concurrency unsynchronized access to the same ID.
sub _runstatedir {
	my ($self) = @_;
	my $runstatedir = $self->{runstatedir};
	die "Runtime state directory '$runstatedir' went missing"
		unless -d $runstatedir;
	return $runstatedir;
}

# Private method: directory within runstatedir for plumage_run
sub _plumagerunstatedir {
	my ($self) = @_;
	return $self->_runstatedir().'/pr/';
}

# Private method: directory within plumage_run directory for configuration
sub _configstatedir {
	my ($self) = @_;
	return $self->_plumagerunstatedir().'/configuration/';
}


# Private method: return the PID of the co-ordinator.
# There is a tiny race window immediately after process creation where this may
# fail as an intermediate process takes a moment to spawn the final process and
# write the pidfile.
sub _pid {
	my ($self) = @_;
	my $pidfile = $self->_runstatedir() . '/plumage_run.pid';
	my $pid = File::Slurp::read_file($pidfile);
	chomp $pid;
	return $pid;
}

=head2 running()

Returns true if the co-ordinator process is still running.
See also L<finished()>.

=cut

sub running {
	my ($self) = @_;
	# See PolygraphServerRun for the rationale for this over kill 0
	my @stats = stat('/proc/'.$self->_pid());
	return !!(@stats);
}

=head2 finished()

Returns true if the run has reached the point where it will make no more
changes to the state directory. This is subtly different from L<running()> as
it will return true before the process exits to allow deadlock-free result
notification ordering:

=over 4

=item *

The co-ordinator process, C<plumage_run>, finishes generating state and
signals the notify URI. This is a blocking operation until it gets a response,
since it is an HTTP request.

=item *

The notified service, at least for Master, requests the report from Client.

=item *

Client must determine that it is acceptable to return the report at this point.
C<finished()> will return true, but so will C<running()>.

=item *

The notified service gets the report and returns a response to the
notification. C<plumage_run> ignores it and exits. C<running()> is now false.

=back

C<finished()> will always return true if C<running()> is false, so that it
gives useful results if C<plumage_run> exits abnormally.

=cut

# An alternative approach may be to put the report payload in the notify URI
# and prohibit other API calls during it, but would require more complicated
# code-sharing with plumage_run and be more fragile to usage error.

sub finished {
	my ($self) = @_;
	my $donefile = $self->_plumagerunstatedir() . '/done';
	return 1 if -e $donefile;
	return !$self->running();
}

=head2 results(with_report)

Returns a scalar of a tarball of logs and the report (if generated).
The format is that offered by the PlumageClient /report endpoint, because an
API boundary that passes an in-memory tarball is I<slightly> more encapsulated
than one that just gives you a directory full of files.

with_report is a boolean controlling if the report/ tree is included.

Throws if still running, because logs are still being written.
You need to kill() or wait for running() to return false first.

=cut

# Note that this is the same organization as the plumage_run state directory
# because it has the same goals and this keeps things simple and efficient for
# now. If plumage_run changes, this application will need to transform the data
# to maintain API compatibility further.
# Aside from the config, we notably exclude pidfiles and monitoring URI files.

sub results {
	my ($self, $with_report) = @_;

	die "Cannot get results until finished" unless $self->finished();

	# Archive::Tar is less useful than it could be here; we'd have to write our
	# recursion. Wrangling a tar process is actually cleaner (and faster and
	# more compatible). We've still got to glob ourselves, but we can just read
	# directories rather than deal with the complexities of File::Glob.
	# We always expect a plumage_run log and configuration.
	my @files = qw(
		../plumage_run.log
		configuration/configuration.pg
	);

	foreach my $role (qw(client server)) {
		my $dir = IO::Dir->new( $self->_plumagerunstatedir()."/$role" );
		next unless defined $dir; # Possible if plumage_run crashed early
		foreach my $entry ($dir->read()) {
			if(($entry =~ /^console[0-9]+\.log$/)
			|| ($entry =~ /^binary[0-9]+\.log$/)) {

				push @files, "$role/$entry";
			}
		}
	}

	if($with_report && -d $self->_plumagerunstatedir().'/report')
		{ push @files, 'report/'; }


	my ($in, $out, $err) = ('', '', '');
	IPC::Run::run(
		[ $TAR_BINARY,
			'--create',
			# These three arguments translate to "keep doing the removal of
			# absolute and upward-relative paths, but don't warn about it"
			# because we *want* that for ../plumage_run.log
			'--absolute-names',             # don't do the built-in which warns
			'--transform', 's,^(../)*,,Sx', # but do remove ../
			'--transform', 's,^/,,S',       # and /
			'--directory', $self->_plumagerunstatedir(),
			@files ],
		\$in, \$out, \$err
	) or die "Error rolling result tarball: $?, $err";
	warn "Result tarball warning: $err" if $err; # must be nonfatal by this point

	return $out;
}

=head2 kill()

Stop the co-ordination process, if it is still running.

=cut

sub kill {
	my ($self) = @_;
	# We give plumage_run quite a lot of grace here, since it will try to get
	# the server side to clean up as well, and if we -9 it in the head before
	# it can send that message we'll leave dirt and running processes behind.
	Plumage::AsyncProcess::kill_kill(10, $self->_pid());
}

=head2 delete()

Clean up records of the run, including the logs and report.

If the co-ordination process is still running, it will be killed.

After this, the object is not valid and must be destroyed.
Any other use of the object is undefined behaviour.

=cut

sub delete {
	my ($self) = @_;

	# Kill the process
	$self->kill();

	# Delete things
	my $runstatedir        = $self->_runstatedir();
	my $plumagerunstatedir = $self->_plumagerunstatedir();
	my $configstatedir     = $self->_configstatedir();

	Plumage::Common::delete_polygraph_configuration($configstatedir);

	# Now, although we've cleaned configstatedir, plumage_run is still at
	# liberty to create other files under plumagerunstatedir, most notably the
	# whole report structure. So we need to rmtree in this case.
	my $rmerrors;
	File::Path::remove_tree($plumagerunstatedir, {
		safe => 1, # don't -f; shouldn't need to chmod anything
		error => \$rmerrors,
	});

	# Consult File::Path's POD for the structure we're unpicking here
	if(@$rmerrors) {
		my @errors;
		foreach my $rmerror (@$rmerrors) {
			foreach my $file (keys %$rmerror) {
				push @errors, "$file (".$rmerror->{$file}.')';
			}
		}
		my $errorsummary = join('; ', @errors);
		die "Deleting state files failed: $errorsummary\n";
	}

	if(     -e "$runstatedir/done") {
		unlink "$runstatedir/done"
			or die "Deleting donefile failed: $!\n";
	}

	unlink "$runstatedir/plumage_run.pid"
		or die "Deleting pidfile failed: $!\n";
	unlink "$runstatedir/plumage_run.log"
		or die "Deleting logfile failed: $!\n";
	rmdir $runstatedir
		or die "Deleting state directory failed: $!\n";
}

1;

# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::Model::Runs;

=head1 Plumage::Model::Runs

Collection of runs.
In practice, these are always under a Configuration, and there is no
backreference from here.

=cut

use DateTime qw();
use File::Slurp qw();
use IPC::Run qw();
use JSON qw();

# Friend constructor for Configuration.
# Takes the subdirectory for runs.

sub _new {
	my ($class, $store_dir) = @_;
	return bless({
		collection => Plumage::Model::Collection->new($store_dir),
	}, $class);
}

=head2 runs()

Returns a list of run IDs.

=cut

sub runs {
	my ($self) = @_;
	return $self->{collection}->list();
}

=head2 run(id)

Returns a existing run by ID, or undef if it does not exist.

=cut

sub run {
	my ($self, $id) = @_;
	return Plumage::Model::Run->_new($self->{collection}->at($id));
}

=head2 create(client, parameters)

Creates a new run within the collection and returns its ID.
This should be closely followed by a start() on the run.

C<client> is the URI of the client endpoint used.
C<parameters> is a hashref of the parameter values used.

=cut

sub create {
	my ($self, $client, $parameters) = @_;
	my $run_id = $self->{collection}->create();

	# Initialize it, since runs are semi-immutable
	$self->run($run_id)->_init(
		$client,
		$parameters,
	);

	return $run_id;
}

=head2 delete(id)

Deletes a run by its ID.

=cut

sub delete {
	my ($self, $id) = @_;
	return $self->{collection}->delete($id);
}

package Plumage::Model::Run;

=head1 Plumage::Model::Run

A single run.
Apart from their comment and report, runs are immutable once created.

=cut

# Friend constructor for Runs.
# For convenience, passes through undef if dir is undef.
# Because the c'tor may be asked to represent an existing run, it does not
# initialize new runs; use _init() for that.

sub _new {
	my ($class, $dir, $values) = @_;
	return unless defined $dir;
	my $self = bless({
		dir => $dir,
	}, $class);

	return $self;
}

# Friend initializer for Runs.
# Takes initial values as per create() in Runs.

sub _init {
	my ($self, $client, $parameters) = @_;
	my $dir = $self->{dir};

	# Write out the initial values
	File::Slurp::write_file("$dir/client.uri",      $client);
	File::Slurp::write_file("$dir/parameters.json", JSON::encode_json($parameters));

	# Write a blank comment so we don't have to special-case its mutator
	File::Slurp::write_file("$dir/comment.txt", '');

	# Write the timestamp. There is currently no need to override this, but it
	# could be an optional argument. UTC is the default, which is what we want.
	my $timestamp = DateTime->now()->iso8601();
	# DateTime unfortunately leaves off the timezone specifier, at least in some
	# versions. Check and fix this, not least as the ECMAScript 6 draft says
	# timezoneless ISO datestamps are to be interpreted as in the local zone.
	unless(($timestamp =~ /Z$/) || ($timestamp =~ /[+-]\d\d:?\d\d$/)) {
		$timestamp .= 'Z';
	}
	File::Slurp::write_file("$dir/time.txt", $timestamp);

	return $self;
}

=head2 running()

Return true if the run is running.
This can thus be false either if it has not been properly started yet, or if it
has terminated.

=cut

sub running {
	my ($self) = @_;
	return -e $self->{dir}.'/client_run.uri';
}

=head2 start(client_run, events)

Mark a run as having been started on the client.
This should closely follow a create(), but cannot be the same call since the ID
of the created run must be passed (indirectly) to the client for the client to
then reply with the ID on its end.

C<client_run> is the URI of the run in the client.
C<events> is the URI of the client event stream.

Returns this.

=cut

sub start {
	my ($self, $client_run, $events) = @_;
	my $dir = $self->{dir};

	File::Slurp::write_file("$dir/client_run.uri",  $client_run);
	File::Slurp::write_file("$dir/events.uri",      $events);
	return $self;
}

=head2 time()

Return the ISO8601 timestamp for the start of the run.

=cut

sub time {
	my ($self) = @_;
	return scalar File::Slurp::read_file($self->{dir}.'/time.txt');
}

=head2 client()

Return the URI for the client used.

=cut

sub client {
	my ($self) = @_;
	return scalar File::Slurp::read_file($self->{dir}.'/client.uri');
}

=head2 client_run()

Return the URI for run on the client.
Once the run has terminated, this returns undef.

=cut

sub client_run {
	my ($self) = @_;
	return unless $self->running();
	return scalar File::Slurp::read_file($self->{dir}.'/client_run.uri');
}

=head2 events()

Return the URI for the event stream.
Once the run has terminated, this returns undef.

=cut

sub events {
	my ($self) = @_;
	return unless $self->running();
	return scalar File::Slurp::read_file($self->{dir}.'/events.uri');
}

=head2 parameters()

Return the hashref of parameter values used for the run.

=cut

sub parameters {
	my ($self) = @_;
	return JSON::decode_json(scalar File::Slurp::read_file($self->{dir}.'/parameters.json'));
}

=head2 comment(), comment(comment)

Get/set the comment for this run.

=cut

sub comment {
	my ($self, @mutate) = @_;

	my $filename = $self->{dir}."/comment.txt";
	if(@mutate) {
		# Setting
		my ($comment) = @mutate;
		File::Slurp::write_file($filename, $comment);
		return $comment;
	} else {
		# Getting
		return scalar File::Slurp::read_file($filename);
	}
}

=head2 report_dir()

Return the directory prefix for the Polygraph report for this run, or undef
if there is no report. Serve files from under here as the report webpages.

=cut

sub report_dir {
	my ($self) = @_;
	my $dir = $self->{dir}.'/report';
	return $dir if -d $dir;
	return;
}

=head set_results(results)

Set the results of the run.
This takes the tarball returned by the Plumage Client's results endpoint and
stores it within the run directory, notably causing report_dir() to start
returning a report, and client_run() and events() to consider the run
terminated. The other files are preserved for archival and future use but the
model does not currently expose them.

=cut

sub set_results {
	my ($self, $results) = @_;

	# We want to extract specific things from the tarball, to make it
	# nontrivial to just trample files all over the place. However, there's no
	# tar flag for "it's not a fatal error if some of these don't exist", so we
	# first have to inspect the contents.
	# These should always exist:
	my @extractables_mandatory = qw(
		plumage_run.log
		configuration/configuration.pg
	);
	# These are the ones we think may not exist. We allow arbitrary files under
	# client and server since damage is limited and while we could wildcard for
	# expected logfiles, we then have to make our filtering more complicated:
	my @extractables_optional = qw(
		client
		server
		report
	);

	my ($in, $out, $err) = ($results, '', '');
	IPC::Run::run(
		[ Plumage::Model::tar_binary(), '--list' ],
		\$in, \$out, \$err
	) or die "Error listing result tarball: $?, $err";
	warn "Result tarball list warning: $err" if $err; # must be nonfatal by this point

	my %listing = map {
		# This *could* just be $_ => 1, but for some tar implementations not
		# including the directory itself, just filenames under it.
		my $base = $_;
		$base =~ s!/.*!/!;
		$base => 1;
	} split(/\n/, $out);
	@extractables_optional = grep {
		# Tar implementations are inconsistent over trailing / on directories
		exists $listing{$_} || # Archive::Tar
		exists $listing{"$_/"} # GNU tar
	} @extractables_optional;

	# OK, now extract what we've got
	($in, $out, $err) = ($results, '', '');
	IPC::Run::run(
		[ Plumage::Model::tar_binary(),
			'--extract',
			'--keep-old-files',      # robustness; shouldn't occur anyway
			'--no-overwrite-dir',    # ditto
			'--touch',               # don't extract mtimes
			'--no-same-permissions', # filter by umask (default)
			'--directory', $self->{dir},
			@extractables_mandatory, @extractables_optional ],
		\$in, \$out, \$err
	) or die "Error extracting result tarball: $?, $err";
	warn "Result tarball extract warning: $err" if $err;

	# There is no tar option for forcing permission bits *on*. So that we don't
	# break our ability to do cleanup, force sane permissions. This is a lot
	# easier letting chmod do the recursion and directory-special-case heavy-
	# lifting.
	($in, $out, $err) = ('', '', '');
	IPC::Run::run(
		[ Plumage::Model::chmod_binary(),
			'--recursive',
			'u+rwX', # capital X = x for directories and already-executable
			@extractables_mandatory, @extractables_optional ],
		\$in, \$out, \$err,
		# chmod has no --directory, so get IPC::Run to do it
		init => sub {
			chdir $self->{dir}
				or die "chdir for correcting result permissions failed: $!";
		}
	) or die "Error correcting result permissions: $?, $err";
	warn "Result tarball chmod warning: $err" if $err;

	# Remove the client run and events URIs, since that marks the run as
	# terminated
	unlink $self->{dir}.'/client_run.uri' or die "Could not remove client run URI: $!";
	unlink $self->{dir}.'/events.uri'     or die "Could not remove events URI: $!";

	return;
}

1;

# Copyright 2014-2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::Common;

=head1 Plumage::Common

Common code between PlumageClient and PlumageServer.

The normal deployment case is merge this into lib/ for the two.

=cut

# Importing from this will break the unit tests' ability to mock it
use File::Slurp qw();
use IO::Dir qw();

# Wrap -d in a normal function so we can mock it for testing
sub _is_dir { return (-d $_[0]); }

# Wrap (a reduced form of) mkdir in a normal function so we can mock it for
# testing more selectively than blatting all CORE::mkdir in the current
# interpreter. Note that passing all of @_ to mkdir breaks this.
sub _mkdir { return (mkdir $_[0]); }

# Likewise for unlink, single file only
sub _unlink { return (unlink $_[0]); }

=head2 ip_ranges(prefix, min, max, partitions)

Work out the IP ranges for Polygraph instances.

Takes the three-octet subnet prefix, and minimum and maximum forth octet, and the number of partitions (CPU cores).
Returns a list with as many elements as there should be instances, each of which is a scalar range in Polygraph syntax.

=cut

sub ip_ranges {
	my ($prefix, $min, $max, $partitions) = @_;

	my $offset = 0;
	my $error = 0.0;
	my $range = $max - $min;
	my $pinverse = $partitions / $range;
	my $low = $min;
	my @ranges;

	# Doing this Bresenham's style gives nicer distribution for the rounding
	# off from partitions, and degrades nicely if there are more partitions
	# than addresses.
	while($offset <= $range) {
		++$offset;
		$error += $pinverse;

		if($error > 1.0) {
			my $high = $offset + $min - 1;
			push @ranges, "$prefix.$low-$high";
			$low = $high + 1;
			$error -= 1.0;
		}
	}

	return @ranges;
}

=head2 make_state_subdirectory(state_directory)

Create a new, unique subdirectory for tracking the state of a run, under the overall state directory.

Returns a list of the leaf name, and the the absolute path of the subdirectory, e.g.

 my ($id, $runstatedir) = Plumage::Common::make_state_directory($STATE_DIR);

Throws on failure.

=cut

sub make_state_subdirectory {
	my ($state_directory) = @_;

	# Generate a unique ID
	# Q: Why am I rolling my own rather than using a UUID?
	# A: Because Ubuntu don't seem to actually package Data::UUID or Data::GUID,
	#    and the ones they do package are obscure and very alpha-versioned.
	#    But the POD reserves the right to make this a proper UUID some day.
	my $id = 0;
	my $statedir = IO::Dir->new($state_directory);
	die "Couldn't open state directory: $!\n" unless defined $statedir;
	foreach my $entry ($statedir->read()) {
		if($entry =~ /^[0-9]+$/) {
			# Deliberately go from the highest seen to avoid re-use of any gaps
			# if we have concurrent runs.
			if($id <= $entry) { $id = $entry + 1; }
		}
	}

	# Make the directory
	# FIXME race condition with ID generation can cause this to fail-stop
	my $runstatedir = "$state_directory/$id";
	_mkdir($runstatedir) or die "Couldn't create run state directory '$runstatedir': $!\n";

	return ($id, $runstatedir);
}

=head2 find_state_subdirectory(state_directory, id)

Given the same state_directory as make_state_subdirectory, and an ID it returned, get the subdirectory it would have also returned.
Safe to call with arbitrary ID values.

Returns undefined if no such subdirectory exists.
The use of an undef return over an exception makes for simpler code (and lighter dependencies) given the expected pattern is to use this to test identifiers recieved from the user and report error to them if not found.

=cut

sub find_state_subdirectory {
	my ($state_directory, $id) = @_;

	# Test the ID is sane and the state directory actually exists
	# (If/when moving to UUIDs, remember to permit '-' as well here.)
	return undef unless $id =~ /^[0-9]+$/;

	my $runstatedir = "$state_directory/$id";
	return undef unless _is_dir($runstatedir);

	return $runstatedir;
}

=head2 validate_supporting_filename(filename)

Validates that the filename provided is valid for a supporting file.
If it is, returns nothing useful.
If it is not, throws an exception string explaining in what way it is invalid.

=cut

sub validate_supporting_filename {
	my ($filename) = @_;
	die "Main configuration cannot be a supporting file\n"
		if $filename =~ m!configuration.pg$!;
	die "Filename '$filename' contains path components\n"
		if $filename =~ m!/!;
	die "Filename '$filename' is hidden\n"
		if $filename =~ m!^\.!; # also stops trying to write to . or ..
	die "Filename '$filename' may conflict with runtime files\n"
		if $filename =~ m!\.(log|pid)$!;
	return;
}

=head2 write_polygraph_configuration(runstatedir, configuration, supporting)

Write a configuration file and supporting files to a state directory.

The configuration is the actual PGL text which will be written to C<configuration.pg>, not a filename.

The supporting hashref is a mapping from filenames to file contents for other files that should be alongside the configuration, such as distribution definitions.
The names cannot contain path components, be hidden, or end in C<.log> or C<.pid>.

A null-separated list of of supporting filenames is written to C<.supporting.log> for later cleanup, so glob-deleting everything can be avoided.

Returns nothing useful, but throws on failures.

=cut

sub write_polygraph_configuration {
	my ($runstatedir, $configuration, $supporting) = @_;

	# Write the configuration to a temporary file
	my $configpath =  "$runstatedir/configuration.pg";
	File::Slurp::write_file($configpath, $configuration);

	# Write out supporting files
	$supporting //= {};
	foreach my $supportname (keys %$supporting) {
		validate_supporting_filename($supportname);
		File::Slurp::write_file("$runstatedir/$supportname", $supporting->{$supportname});
	}

	# Remember which files are supporting
	File::Slurp::write_file("$runstatedir/.supporting.log", join("\0", keys %$supporting));

	undef;
}

=head2 delete_polygraph_configuration(runstatedir)

Delete the Polygraph configuration from a state directory which has previously been used with write_polygraph_configuration().

This does not remove the directory itself, since it assumes it may contain other files that are to be removed first.

Returns nothing useful, but throws on failures.

=cut

sub delete_polygraph_configuration {
	my ($runstatedir) = @_;

	_unlink("$runstatedir/configuration.pg")
		or die "Deleting configuration failed: $!\n";

	foreach (split /\0/, scalar File::Slurp::read_file("$runstatedir/.supporting.log")) {
		# It would be best to sanitize the unlink path so it is always under
		# $runstatedir, but we know due to write_polygraph_configuration() that
		# we can take a rather blunt approach to forbidding attempts to break
		# out, should .supporting.log have been tampered with.
		die "Supporting configuration list contains forbidden filenames"
			if $_ =~ m!/! || $_ =~ m!^\.!;
		_unlink("$runstatedir/$_")
			or die "Deleting supporting configuration '$_' failed: $!\n";
	}

	_unlink("$runstatedir/.supporting.log")
		or die "Deleting supporting configuration list failed: $!\n";

	undef;
}

1;

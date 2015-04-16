# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::Model::Configurations;

=head1 Plumage::Model::Configurations

Model for the collection of configurations.

=cut

use File::Slurp qw();
use JSON qw();

use Plumage::Model::Collection;
use Plumage::Common;

# Friend constructor for Model.
# Takes the subdirectory for configurations.

sub _new {
	my ($class, $store_dir) = @_;
	return bless({
		collection => Plumage::Model::Collection->new($store_dir),
	}, $class);
}

=head2 configurations()

Returns a list of configuration IDs.

=cut

sub configurations {
	my ($self) = @_;
	return $self->{collection}->list();
}

=head2 configuration(id)

Returns a existing configuration by ID, or undef if it does not exist.

=cut

sub configuration {
	my ($self, $id) = @_;
	return Plumage::Model::Configuration->_new($self->{collection}->at($id));
}

=head2 create()

Creates a new blank configuration within the collection and returns its ID.

=cut

sub create {
	my ($self) = @_;
	return $self->{collection}->create();
}

=head2 delete(id)

Deletes a configuration by its ID.
As per the web API, this recursively deletes all runs using it.

=cut

sub delete {
	my ($self, $id) = @_;
	# Runs get deleted as part of the recursive rmtree; if this filesystem
	# nesting ever stops (e.g. replacing the model storage with a database) it
	# will be necessary to remove them here.
	return $self->{collection}->delete($id);
}

package Plumage::Model::Configuration;

=head1 Plumage::Model::Configuration

A single configuration.

=cut

# Friend constructor for Configurations.
# Takes the subdirectory for this configuration.
# For convenience, passes through undef if dir is undef.

sub _new {
	my ($class, $dir) = @_;
	return unless defined $dir;
	return bless({
		dir => $dir,
	}, $class);
}

# Private method for implementing simple accessor/mutator methods that just
# store blobs as-is.
# Takes the filename for the blob, default if the file does not exist, and a
# ref to the original argument list.
# Throws on I/O errors.

sub _get_set_blob {
	my ($self, $filename, $default, $args) = @_;

	$filename = $self->{dir}."/$filename";

	shift @$args; # remove self
	if(@$args) {
		# Setting
		File::Slurp::write_file($filename, $args->[0]);
		return $args->[0];
	} else {
		# Getting
		if(-e $filename) {
			return scalar File::Slurp::read_file($filename);
		} else {
			return $default;
		}
	}
	# Every leaf of the above if tree returns
}

# Private utility method for determining if this configuration has runs
sub _has_runs {
	my ($self) = @_;
	return !!($self->runs()->runs());
}

=head2 template(), template(template)

Get/set the template for the configuration.

=cut

sub template {
	my ($self, @other) = @_;
	if(@other && $self->_has_runs())
		{ die "Cannot modify template of configuration with runs\n"; }
	return $self->_get_set_blob('configuration.pg.tt', '', \@_);
}

=head2 supporting()

Get the L<Plumage::Model::Configuration::Supporting> for this configuration.

=cut

sub supporting {
	my ($self) = @_;
	my $supporting_dir = $self->{dir}."/supporting";
	unless(-d $supporting_dir) {
		mkdir $supporting_dir or die "Couldn't create support subdirectory: $!";
	}
	return Plumage::Model::Configuration::Supporting->_new($supporting_dir, $self->_has_runs());
}

=head2 name(), name(name), comment(), comment(comment)

Get/set the name and comment of the configuration

=cut

sub name {
	return $_[0]->_get_set_blob('name.txt', 'New configuration', \@_);
}

sub comment {
	return $_[0]->_get_set_blob('comment.txt', '', \@_);
}

=head2 parameters(), parameters(parameters)

Get/set parameters.
The mutator takes an arrayref of L<Plumage::Model::Configuration::Parameter>
structs, so that it can distinguish an empty array from a get request.
The return is a plain list of them.

=cut

sub parameters {
	my ($self, $parameters) = @_;
	my $filename = $self->{dir}."/parameters.json";
	if(defined $parameters) {

		# Setting
		die "Cannot modify parameter metadata of configuration with runs\n"
			if $self->_has_runs();
		# Parameter objects implement TO_JSON, so we *could* get JSON to do the
		# conversion to plain hashes transparently like this:
		# 	JSON->new()->utf8(1)->convert_blessed(1)->encode($parameters)
		# but this is causing JSON to blow up internally with an attempt to
		# modify read-only values. So do it longhand.
		my @params_raw;
		foreach my $parameter (@$parameters) {
			push @params_raw, $parameter->TO_JSON();
		}
		File::Slurp::write_file($filename, JSON::encode_json(\@params_raw));
		return @params_raw;

	} else {

		# Getting
		return unless -e $filename; # EARLY RETURN * * * * *
		my @params;
		my $params_raw = JSON::decode_json(scalar File::Slurp::read_file($filename));
		foreach my $param_raw (@$params_raw) {
			push @params,
				Plumage::Model::Configuration::Parameter->new(%$param_raw);
		}
		return @params;

	}
}

=head2 runs()

Get the L<Plumage::Model::Runs> for this configuration.

=cut

sub runs {
	my ($self) = @_;
	my $runs_dir = $self->{dir}."/runs";
	unless(-d $runs_dir) {
		mkdir $runs_dir or die "Couldn't create run subdirectory: $!";
	}
	return Plumage::Model::Runs->_new($runs_dir);
}

package Plumage::Model::Configuration::Supporting;

=head1 Plumage::Model::Configuration::Supporting

Collection of supporting files.

=cut

# Friend constructor for Configuration.
# Takes the subdirectory for supporting files, and if the configuration is
# immutable.

sub _new {
	my ($class, $store_dir, $immutable) = @_;
	return bless({
		collection => Plumage::Model::Collection->new($store_dir),
		immutable  => $immutable,
	}, $class);
}

=head2 files()

Returns a list of filenames of supporting files.

=cut

sub files {
	my ($self) = @_;
	return $self->{collection}->list();
}

=head2 file(name)

Returns the contents of the named file, or undef if it does not exist.

=cut

sub file {
	my ($self, $name) = @_;
	my $filename = $self->{collection}->at($name);
	return unless defined $filename;
	return scalar File::Slurp::read_file($filename);
}

=head2 update(name, content)

Replaces the contents of the named file, creating it if necessary.
For compatability with lower levels of Plumage, will throw if the filename is
not valid as a supporting file (so we can report this to the user at
configuration setup time, not when their first run fails on them right out the
gate then needs to be deleted before they can amend it).

=cut

sub update {
	my ($self, $name, $content) = @_;
	die "Cannot modify supporting files of configuration with runs\n"
		if $self->{immutable};
	Plumage::Common::validate_supporting_filename($name); # throws
	my $filename = $self->{collection}->insert_at($name);
	File::Slurp::write_file($filename, $content);
}

=head2 delete(name)

Removes the named file.
Returns true on success, undefined if it did not exist.

=cut

sub delete {
	my ($self, $name) = @_;
	die "Cannot modify supporting files of configuration with runs\n"
		if $self->{immutable};
	return $self->{collection}->delete($name);
}

package Plumage::Model::Configuration::Parameter;

=head1 Plumage::Model::Configuration::Parameter;

Structured representation of a parameter to a configuration.
This is just a simple L<fields> struct-like.
The constructor accepts a hash (not a hashref) for initial values.

Fields are:

=over 4

=item name

=item default

=back

=cut

use fields qw(name default);

sub new {
	my Plumage::Model::Configuration::Parameter $self = shift;
	$self = fields::new($self) unless ref $self;
	my (%init) = @_;
	foreach (keys %init) { $self->{$_} = $init{$_}; }
	return $self;
}

=head2 TO_JSON()

Serializes to a plain, unblessed Perl hash.
See L<JSON>.

=cut

sub TO_JSON {
	my ($self) = @_;
	return {
		name    => $self->{name},
		default => $self->{default},
	};
}

1;

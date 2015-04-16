# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::Model;

=head1 Plumage::Model

Model for Plumage's persistant data.

The Plumage models are very ID-oriented, preferring them as arguments and
return values over objects, because they expect a web application context
where reference-by-ID is the norm. Likewise, they tend to prefer undef return
over exceptions for absent items as this makes accurate 404 reporting easier.

Using this will import the necessary packages under it.

=cut

use File::Slurp qw();
use FindBin qw();
use JSON qw();

use Plumage::Model::Configurations;
use Plumage::Model::Runs;

# Private package globals for system binaries. These are accessed via plain
# namespaced functions rather than methods because the users of them will not
# have a backreference to a model. They get updated when a c'tor loads the host
# configuration. This is a little hairy but should only produce unpredictable
# results if the host configuration changes the binary paths between
# constructing multiple model objects with overlapping lifetimes.
my $_TAR_BINARY   = '/bin/tar';
my $_CHMOD_BINARY = '/bin/chmod';

=head2 new()

The constructor loads the host configuration.

=cut

# This could be a singleton to avoid so much reloading on every route, but for
# our purpose simplicity and reduced scope for awkward bugs are preferable.

sub new {
	my ($class) = @_;

	my $config_filename = "$FindBin::Bin/../etc/plumagemaster.json";
	my $config = JSON::decode_json(File::Slurp::read_file($config_filename));

	my $store_dir    = $config->{store_dir}    // '/var/lib/plumage/';
	my $client_bases = $config->{client_bases} // [];

	$_TAR_BINARY   = $config->{tar_binary}   // $_TAR_BINARY;
	$_CHMOD_BINARY = $config->{chmod_binary} // $_CHMOD_BINARY;

	die "Configuration storage directory does not exist"
		unless -d $store_dir;

	return bless({
		store_dir => $store_dir,
		clients   => $client_bases,
	}, $class);
}

=head2 configurations()

Returns a L<Plumage::Model::Configurations> for the collection of configurations.

=cut

sub configurations {
	my ($self) = @_;

	my $configurations_dir = $self->{store_dir}.'/configurations';
	mkdir $configurations_dir unless -d $configurations_dir;
	return Plumage::Model::Configurations->_new($configurations_dir);
}

=head2 clients()

Returns a list of client URI scalars from the host configuration.

=cut

sub clients {
	my ($self) = @_;
	return @{$self->{clients}};
}

=head2 tar_binary()

Namespaced function to return the path of the tar binary.

=cut

sub tar_binary {
	return $_TAR_BINARY;
};

=head2 chmod_binary()

Namespaced function to return the path of the chmod binary.

=cut

sub chmod_binary {
	return $_CHMOD_BINARY;
}

1;

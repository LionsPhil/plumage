# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package Plumage::PublishAPI;

use Pod::Xhtml;
use Template;

=head1 Plumage::PublishAPI

Defines a common mechanism to automatically generate API documentation from POD,
which can be served from a consistent route.

=head2 publish($file)

Plain function to return an HTML document publishing the API documented by the
POD of the given file. Use like this:

	get '/apidoc' => sub {
		return Plumage::PublishAPI::publish(__FILE__);
	};

=cut

sub publish {
	my ($file) = @_;
	my $podulator = Pod::Xhtml->new(
		StringMode => 1,
		FragmentOnly => 1,
		TopLinks => 0,
	);
	$podulator->parse_from_file($file);
	my $fragment = $podulator->asString();

	# This isn't great but a proper XML parser would be overkill, as would be
	# reparsing the POD looking for =head1. Pod::Xhtml won't generate a correct
	# <title> even in non-fragment mode since it's hard-coded to look for text
	# after a =head1 NAME.
	$fragment =~ m!<h1[^>]*>([^<]*)</h1>!;
	my $title = $1 // 'Plumage';

	# This is even nastier but the module doesn't provide useful control over
	# how the index is generated.
	$fragment =~ s|<!-- INDEX START -->|<div id="index">|;
	$fragment =~ s|<hr />||;
	$fragment =~ s|<!-- INDEX END -->|</div>|;

	# Dancer isn't used with a Template configuration since for the vast
	# majority of routes that's the wrong thing; they're REST API or static
	# (as we almost are). So invoke T::T manually.
	my $tt = Template->new({
		INCLUDE_PATH => 'views/',
		POST_CHOMP   => 1,
	});
	my $output;
	$tt->process(
		'apidoc.tt',
		{
			title         => $title,
			documentation => $fragment,
		},
		\$output,
	) or die "Template processing failed: ".$tt->error()."\n";
	return $output;
}

1;

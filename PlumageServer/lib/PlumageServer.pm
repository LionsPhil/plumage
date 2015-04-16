# Copyright 2014-2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PlumageServer;
use Dancer2;

use PolygraphServerRun;
use Plumage::PublishAPI;

our $VERSION = '0.1';

=head1 Plumage server

This POD documents the RESTful Web Service implemented by this application.

Normally, this service is invoked only by the Plumage Client application.

=head2 POST /runs/

Starts execution of the polygraph server with a configuration provided by the form-encoded request uploads.
C<configuration> must be the Polygraph configuration itself.
C<supporting> may be supplied multiple times; filenames are respected and will be put alongside the configuration.

Returns a 202 Accepted with a Location header indicating the URI for monitoring the run.

=cut

post '/runs/' => sub {
	my $configuration = request->upload('configuration');
	unless(defined $configuration) {
		send_error('Configuration required', 403); return;
	}
	my $configuration_data = $configuration->content();

	my %supporting_data;
	foreach my $supporting (request->upload('supporting')) {
		# Validating this isn't trying to trample /etc/passwd is done by PSRun
		# (Ideally, better error-reporting to give a 4xx rather than 5xx)
		$supporting_data{ $supporting->filename() } = $supporting->content();
	}

	my $run = PolygraphServerRun->new($configuration_data, \%supporting_data);
	my $runid = $run->id();
	my $runuri = ''.uri_for("/runs/$runid/wait");

	status 202;
	header 'Location' => $runuri;
	content_type 'text/plain';
	# This must be forcefully stringified, or our serializer will try to
	# JSONify the Perl URI object and cause Bad Things. (Also, newline.)
	return "$runuri\n";
};

=head2 GET /runs/(runid)/wait

Monitor a run in progress; this is what the POST request above directs you to.
While running, returns 200 OK, and a partial form of the run (see below).
Once complete, returns a 303 See Other with a Location pointing to the URI for the run.

=cut

get '/runs/:runid/wait' => sub {
	my $runid = params('route')->{runid};
	my $run = PolygraphServerRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	if($run->running()) {
		status 200;
		return _urls_for_run($run);
	} else {
		status 303;
		my $uri = uri_for("/runs/$runid");
		header 'Location' => "$uri";
		content_type 'text/plain';
		return "$uri\n";
	}
};

=head2 GET /runs/(runid)

Identity of a run.
Fetching this returns a JSON object containing URLs of resources under the run, of the form:

	{
		"cputime": "url",
		"console": ["url", "url", "url"],
		"log":     ["url", "url", "url"]
	}

During the run, only cputime and console output URLs are provided.
After it is compelete, polygraph binary log URLs are added.

=cut

get '/runs/:runid' => sub {
	my $runid = params('route')->{runid};
	my $run = PolygraphServerRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	return _urls_for_run($run);
};

# Generate the JSON metadata pointers for a run
sub _urls_for_run {
	my ($run) = @_;
	my $runid = $run->id();

	my %metadata = (
		cputime => ''.uri_for("/runs/$runid/cputime"),
	);
	my @serverids = $run->server_ids();
	$metadata{console} = [map { ''.uri_for("/runs/$runid/$_/console") } @serverids];
	$metadata{log}     = [map { ''.uri_for("/runs/$runid/$_/log"    ) } @serverids]
		unless $run->running();
	return \%metadata;
}

=head2 GET /runs/(runid)/cputime

Get the CPU time usage of the Polygraph server processes, in seconds.
Returns a JSON object of the form:

	{
		"time": [0.1, 0.1, 0.1]
	}

Because this is an point sample, you will have to take differences and divide by your time interval to work out percentage CPU load.
Hanging around 100% load after startup is a bad sign and may mean the server can't keep up.

(These data are aggregated into a single request for efficiency.)

=cut

get '/runs/:runid/cputime' => sub {
	my $runid = params('route')->{runid};
	my $run = PolygraphServerRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	...; # TODO
};

=head2 GET /runs/(runid)/(process)/console

This is the form of the URI for the console log of a Polygraph run.
Returns the console log as a stream of chunked data.
The request body will complete once the run stops.

=cut

# XXX can you stream from Dancer?
# http://search.cpan.org/~xsawyerx/Dancer2/lib/Dancer2/Manual.pod#send_file
# http://www.perlmonks.org/?node_id=1023517
# http://www.perlmonks.org/?node_id=1032829

get '/runs/:runid/:serverid/console' => sub {
	...;
};

=head2 GET /runs/(runid)/(process)/log

This is the form of the URI for the binary log of a Polygraph run.
If the run has not yet completed, returns 503 Service Unavailable.
Currently it does not provide any Retry-After estimation; clients are expected to only get here as a result of the monitoring URI returning 303.

=cut

get '/runs/:runid/:serverid/log' => sub {
	my $runid = params('route')->{runid};
	my $serverid = params('route')->{serverid};
	my $run = PolygraphServerRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	my $log = $run->log($serverid);

	if(defined $log) {
		content_type 'application/octet-stream';
		return $log;
	} else {
		send_error('No log yet', 503); return;
	}
};

=head2 DELETE /runs/(runid){/wait}

Deleting the monitoring or finished URI stops the run, if still going, and erases the logs for it.
Clients should do this after successfully retrieving the binary log from, or aborting, a run.

=cut

my $delete_run = sub {
	my $runid = params('route')->{runid};
	my $run = PolygraphServerRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	$run->delete();
	return '';
};
del '/runs/:runid' => $delete_run;
del '/runs/:runid/wait' => $delete_run;

=head2 GET /, GET /apidoc

Returns this API documentation.

=cut

get '/' => sub {
	return redirect(uri_for('/apidoc'));
};

get '/apidoc' => sub {
	return Plumage::PublishAPI::publish(__FILE__);
};

true;

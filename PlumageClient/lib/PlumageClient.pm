# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PlumageClient;
use Dancer2;

use PlumageClientRun;
use Plumage::PublishAPI;

our $VERSION = '0.1';

=head1 Plumage client

This POD documents the RESTful Web Service implemented by this application.

Normally, this service is invoked only by the Plumage Master application.
This service will automatically manage the matching Plumage Server.

=head2 POST /runs/

Starts execution of the polygraph client/server pair with a configuration
provided by the form-encoded request uploads.
C<configuration.tt> must be the Polygraph configuration template, which will be
run through L<Template::Toolkit> with machine-specific substitutions B<and> form
submission parameters.
C<supporting> may be supplied multiple times; filenames are respected and will
be put alongside the configuration.
C<notify> is an optional notification URI.
When the run terminates in some manner, a POST will be made to it with no body.
It will not be triggered if this route itself returns an error.

Other form parameters prefixed with C<param_> will be passed to the template
with C<param_> stripped. (This is to namespace them from the others.)

Returns a 201 Created with a Location header indicating URI representing the
run.

=cut

# The notify POST might grow a payload in future identifying the run, but this
# requires passing more state down through the layers, and we don't currently
# need it.

post '/runs/' => sub {
	my $configuration = request->upload('configuration.tt');
	unless(defined $configuration) {
		send_error('Configuration template required', 403); return;
	}
	my $configuration_data = $configuration->content();

	my %body_params = request->params('body');
	my %template_params;
	foreach my $param (keys %body_params) {
		if($param =~ /^param_(.+)/) {
			$template_params{$1} = $body_params{$param};
		}
	}

	my %supporting_data;
	foreach my $supporting (request->upload('supporting')) {
		# Validating this isn't trying to trample /etc/passwd is done by PCRun
		# (Ideally, better error-reporting to give a 4xx rather than 5xx)
		$supporting_data{ $supporting->filename() } = $supporting->content();
	}

	my $notify = request->params('body')->{'notify'};

	my $run = PlumageClientRun->new(
		$configuration_data, \%template_params, \%supporting_data, $notify);
	my $runid = $run->id();
	my $runuri = ''.uri_for("/runs/$runid");

	status 201;
	header 'Location' => $runuri;
	content_type 'text/plain';
	# This must be forcefully stringified, or our serializer will try to
	# JSONify the Perl URI object and cause Bad Things. (Also, newline.)
	return "$runuri\n";
};

=head2 GET /runs/(runid)

Identity of a run.
This is what the POST request above directs you to.

The response you get from this depends on the MIME type you Accept.

=over 4

=item text/event-stream

will be redirected with 303 See Other to the C</events> resource.

=item application/x-tar

will be redirected with 303 See Other to the C</results> resource.

=item text/html

will generate a small document with links to the other two. This is mostly
provided so clients that are blind to redirection (e.g. AJAX requests) can get a
200 OK response to the creation POST.

=back

Other types are not supported and will be refused with 406 Not Acceptable.
Note that the Accept header processing is quite stupid and will not correctly
understand quality values.
For correct results accept exactly only the MIME type desired.

=cut

# This doesn't go via a JSON object like the server API because it's possible
# to perform discovery of the desired subresources in a
# non-application-specific manner, i.e. using plain HTTP features. There is no
# monitoring URI since the resource is conceptually considered ready from the
# start.

get '/runs/:runid' => sub {
	# We could get away with blindly assuming the runid exists and let the
	# redirected-to route return 404 if needed, but for the text/html case at
	# least it is preferable not to give 200s which are lies.

	my $runid = params('route')->{runid};
	my $run = PlumageClientRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	# See https://github.com/PerlDancer/Dancer2/issues/712 for Dancer2
	# proposals to do content negotiation better than this. I don't use
	# Dancer's conditional matching because there's common code across these
	# routes.
	# By default, generate the web fragment.
	my $accept = request->accept() // 'text/html';
	my $events_uri  = uri_for("/runs/$runid/events");
	my $results_uri = uri_for("/runs/$runid/results");
	my $redirect = undef;

	if(     $accept =~ m!text/event-stream!i) {
		$redirect = $events_uri;
	} elsif($accept =~ m!application/x-tar!i) {
		$redirect = $results_uri;
	} elsif($accept =~ m!text/html!i) {

		# Heredoc rather than view template since it's a API discovery
		# mechanism, not a user-facing page. This should never get bigger.
		# The possible namespace of URIs here should not conflict with HTML.
		status 200;
		content_type 'text/html';
		return <<"RUNDISCOVER";
<!DOCTYPE html><html><head><title>Plumage run $runid</title></head><body><p>
	<a href="$events_uri">Events</a>
	<a href="$results_uri">Results</a>
</p></body></html>
RUNDISCOVER
		# * * * * EARLY RETURN * * * * *

	}

	if(defined $redirect) {
		status 303;
		header 'Location' => "$redirect";
		content_type 'text/plain';
		return "$redirect\n";
	} else {
		# This SHOULD have an entity body, but Dancer makes that awkward
		send_error('Not Acceptable', 406); return;
	}
};

=head2 GET /runs/(runid)/events

Endpoint for a server-sent event feed for collated log and performance data.
See L<https://developer.mozilla.org/en-US/docs/Server-sent_events/Using_server-sent_events>.

The following events are generated, each with a JSON payload of a simple object
acting as a map:

=head3 coordinating

Progress is being made on co-ordinating the run. C<human> is a human-readable
log message. C<semantic> is one of the following tokens, normally generated in
order:

=over 4

=item preparing

co-ordination is starting, required configuration is being gathered

=item starting-servers

Polygraph server processes are being started

=item warming-servers

Polygraph server processes are being given idle time to start up

=item starting-clients

Polygraph client processes are being started

=item waiting-clients

waiting for clients to finish their run

=item waiting-servers

waiting for servers to time out and shut down

=item fetching-servers

fetching run data from the servers

=item killing-clients

closing down/cleaning up after clients

=item killing-servers

closing down/cleaning up after servers

=item generating-report

generating the Polygraph report from the run

=item error

a co-ordination error has occurred; a failure completion event will follow if
fatal (note that this is distinct from e.g. errors from Polygraph, which will
appear as log lines and only propagate here if fatal)

=back

=head3 polygraphlog

A console log line from a Polygraph process.
C<role> will either be C<client>, C<server>, or C<report>; C<id> will be a small
integer indicating which one; and C<message> will be the log line.

=head3 cpuusage

CPU usage information for the Polygraph processes, collated into one message.
There are top-level keys for C<client> and C<server>, and under each a JSON
array of proportional CPU loads in the range 0.0 to 1.0, with an element per
process, in order.

=head3 completed

The run has stopped.
C<how> is one of the tokens C<succeeded>, C<aborted> (run was stopped by API
action), or C<failed> (run stopped itself due to a fatal error).

=cut

get '/runs/:runid/events' => sub {
	my $runid = params('route')->{runid};
	my $run = PlumageClientRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	...;
};

=head2 GET /runs/(runid)/results

Returns the results of the run as a tarball with the following structure:

 ./plumage_run.log    - Log of events from the co-ordinator
 ./configuration/
     configuration.pg - Configuration file after template processing
 ./client/
     consoleN.log     - Console output from each client process
     binaryN.log      - Binary log from each client process
 ./server/
     consoleN.log     - Console output from each server process
     binaryN.log      - Binary log from each server process
 ./report/
     *                - Generated Polygraph report after the run

The configuration is not included in full since it is defined by the caller
(master), which is responsible for associating and archiving configurations
with runs. Supporting files are omitted, but the processed template is
included for diagnostics and because it may be sensitive to host configuration.

If the run has not yet completed, returns 503 Service Unavailable.

=cut

# Consideration was made of making this a multipart/mixed MIME response, but
# that's unconventional usage to begin with, and there are further
# complications in that it's a arbitrarily hierarchical structure, yet the
# filenames suggested by Content-Disposition should only be leaf names and
# clients are strongly encouraged to discard any path components for security.

get '/runs/:runid/results' => sub {
	my $runid = params('route')->{runid};
	my $run = PlumageClientRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	unless($run->finished()) {
		send_error('No results yet', 503); return;
	}

	status 200;
	content_type 'application/x-tar';
	return $run->results(1);
};

=head2 DELETE /runs/(runid)

Deleting the run stops it if in progress, and erases all state tracking for it.
The manager should do this after successfully retrieving the results from, or
aborting, a run.

The response body is a partial form of the tarball provided from the /results
resource, without the Polygraph report structure.
This allows the Polygraph logs of a partial run to be archived by the caller if
desired.

=cut

del '/runs/:runid' => sub {
	my $runid = params('route')->{runid};
	my $run = PlumageClientRun->new_existing($runid);

	unless(defined $run) {
		send_error('No such run', 404); return;
	}

	$run->kill();

	my $results = $run->results(0);

	$run->delete();

	status 200;
	content_type 'application/x-tar';
	return $results;
};

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

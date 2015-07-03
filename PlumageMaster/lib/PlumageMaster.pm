# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PlumageMaster;
use Dancer2;

use HTTP::Request::Common;
use LWP::UserAgent;
use Try::Tiny;

use Plumage::Model;
use Plumage::PublishAPI;

our $VERSION = '0.2';

=head1 Plumage master

This POD documents the RESTful Web Service implemented by this application.

Normally, this service is invoked by the Plumage JavaScript application (which
it also serves as a simple static route), but it is also a sensible endpoint
to use for automated performance testing.

B<All API routes are prefixed with C</api/1>.>

=cut

prefix '/api' => sub { prefix '/1' => sub { # Non-indenting version 1 API prefix

# TODO Try to factor out configuration object lookup into a before hook

# FIXME Investigate further why request->data() isn't working. It should return
# the same as request->serializer()->deserialize(request->body()), which works,
# but is instead just yielding undef. Looking at its implementation, if it gets
# that far, pretty much the only thing left before returning is Moo plumbing.

=head2 GET    /configurations/

Get a JSON array of minimal representations of configurations, each as a hash
containing an C<id>, C<name>, and C<comment>. The C<runs> element contains the
count of runs under the configuration as summary information.

=cut

get '/configurations/' => sub {
	my $configurations = Plumage::Model->new()->configurations();

	return [ map {
		my $cfg = $configurations->configuration($_);
		{
			id      => $_,
			name    => $cfg->name(),
			comment => $cfg->comment(),
			runs    => (scalar $cfg->runs()->runs()),
		};
	} $configurations->configurations() ];
};

=head2 POST   /configurations/

Create a new, empty configuration.
Returns a minimal JSON respresentation of the single configuration, as for GET.

=cut

post '/configurations/' => sub {
	my $configurations = Plumage::Model->new()->configurations();
	my $id = $configurations->create();
	my $configuration = $configurations->configuration($id);

	status 201; # Created
	return {
		id      => $id,
		name    => $configuration->name(),
		comment => $configuration->comment(),
	};
};

=head2 GET    /configurations/(id)

This is the URI for a configuration.
Returns a JSON representation of the configuration, except for supporting files.
This is like the format above, but adds C<template>.

Note that configurations which have runs are (mostly) immutable.

=cut

get '/configurations/:cid' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	return {
		id       => $cid,
		name     => $configuration->name(),
		comment  => $configuration->comment(),
		runs     => (scalar $configuration->runs()->runs()),
		template => $configuration->template(),
	};
};

=head2 PUT    /configurations/(id)

Sets the configuration's name, comment, and template based on keys of a JSON
object in the request body. Omitted keys are ignored.

If the configuration has runs, template changes are also ignored.

=cut

put '/configurations/:cid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $data = request->serializer()->deserialize(request->body());

	$configuration->name(   $data->{name}   )
		if exists $data->{name};
	$configuration->comment($data->{comment})
		if exists $data->{comment};

	unless($configuration->runs()->runs()) {
		$configuration->template($data->{template})
			if exists $data->{template};
	}

	status 204; # No Content
	return '';
};

=head2 DELETE /configurations/(id)

Permanantly delete a configuration B<and all runs using it>.
There is no confirmation or undo at the API level.

This is a permitted mutation to a configuration with runs since it does not
invalidate them; it I<destroys> them.

=cut

del '/configurations/:cid' => sub {
	# Note that doing the delete is part of this expression
	if(defined Plumage::Model->new()->configurations()->delete(
		request->params('route')->{'cid'})) {

		status 204; # No Content
		return '';
	} else {
		return send_error('No such configuration', 404);
	}
};

=head2 GET    /configurations/(id)/supporting/

Get a JSON array of supporting file names.
Note that this is a ReSTful collection, but is I<not> quite the usual Backbone
pattern, to avoid having to JSON-encode arbitrary binary data.

=cut

get '/configurations/:cid/supporting/' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	return [ $configuration->supporting()->files() ];
};

=head2 GET    /configurations/(id)/supporting/(name)

The URI space for individual supporting files.
There is no hierarchy permitted.
Returns the content of the supporting file.

Supporting files are put alongside the configuration for Polygraph to reference,
e.g. size distributions, SSL configurations and certificates.
Plumage treats them as opaque binary blobs.

=cut

get '/configurations/:cid/supporting/:sid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $file = $configuration->supporting()->file(
		request->params('route')->{'sid'});
	return send_error('No such supporting file', 404)
		unless defined $file;

	content_type 'application/octet-stream';
	return $file;
};

=head2 PUT    /configurations/(id)/supporting/(name)

Sets the content of the supporting file.
If it did not previously exist, this creates it.

=cut

put '/configurations/:cid/supporting/:sid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	# TODO Better pass through errors from this than by 500-ing
	$configuration->supporting()->update(
		request->params('route')->{'sid'},
		request->body());

	status 204; # No Content
	return '';
};

=head2 DELETE /configurations/(id)/supporting/(name)

Deletes the supporting file.

=cut

del '/configurations/:cid/supporting/:sid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	$configuration->supporting()->delete(
		request->params('route')->{'sid'});

	status 204; # No Content
	return '';
};

=head2 GET    /configurations/(id)/parameters/

Gets a JSON array of configuration parameter metadata. Each has a C<id>,
C<name> and a C<default>. The names are the parameter names in the template,
without any C<param_> prefix. The IDs are an ordering index and may change on
deletions.

=cut

get '/configurations/:cid/parameters/' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $index = 0;
	return [ map { {
		id      => $index++,
		name    => $_->{name},
		default => $_->{default},
	} } $configuration->parameters() ];
};

=head2 POST   /configurations/(id)/parameters/

Add new parameter metadata to the end of the list. A JSON representation of the
parameter may be provided, and will be echoed back with its new C<id> included.

=cut

post '/configurations/:cid/parameters/' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $data = request->serializer()->deserialize(request->body()) // {};
	my $parameter = Plumage::Model::Configuration::Parameter->new(
		name    => $data->{name}    // '',
		default => $data->{default} // '',
	);
	my @parameters = $configuration->parameters();
	push @parameters, $parameter;
	$configuration->parameters(\@parameters);

	status 201; # Created
	return {
		id      => $#parameters,
		name    => $parameter->{name},
		default => $parameter->{default},
	};
};

=head2 PUT    /configurations/(id)/parameters/

B<Replace> the set of parameters with those in the request body, which should
be an object containing a JSON array in the same format as the matching GET,
under the key 'parameters'.

=cut

put '/configurations/:cid/parameters/' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	# The weird requirement to wrap the array in an object comes from Dancer;
	# it will crash internally when processing a request in an environment using
	# the JSON deserializer if the request body is a JSON array.
	my $data = request->serializer()->deserialize(request->body()) // {};
	my @parameters;
	foreach my $datum (@{$data->{parameters} // []}) {
		my $parameter = Plumage::Model::Configuration::Parameter->new(
			name    => $datum->{name}    // '',
			default => $datum->{default} // '',
		);
		push @parameters, $parameter;
	}
	$configuration->parameters(\@parameters);

	status 204; # No Content
	return '';
};

=head2 GET    /configurations/(id)/parameters/(id)

Get a single parameter from the collection.

=cut

get '/configurations/:cid/parameters/:pid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $pid = request->params('route')->{'pid'};
	my @parameters = $configuration->parameters();
	my $parameter = $parameters[$pid];
	return send_error('No such parameter', 404)
		unless defined $parameter;

	return {
		id      => $pid,
		name    => $parameter->{name},
		default => $parameter->{default},
	};
};

=head2 PUT    /configurations/(id)/parameters/(id)

Sets a single parameter's metadata in the same format as the GET route.
This can create or overwrite an existing entry.

=cut

put '/configurations/:cid/parameters/:pid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $pid = request->params('route')->{'pid'};
	my $data = request->serializer()->deserialize(request->body());
	my $parameter = Plumage::Model::Configuration::Parameter->new({
		name    => $data->{name} // '',
		default => $data->{name} // '',
	});

	my @parameters = $configuration->parameters();
	splice @parameters, $pid, 1, $parameter;
	$configuration->parameters(\@parameters);

	status 204; # No Content
	return '';
};

=head2 DELETE /configurations/(id)/parameters/(id)

Remove a single parameter's metadata.
This invalidates the IDs of other parameters; fetch the collection again.

=cut

del '/configurations/:cid/parameters/:pid' => sub {
	my $configuration = Plumage::Model->new()->configurations()->configuration(
		request->params('route')->{'cid'});
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $pid = request->params('route')->{'pid'};
	my @parameters = $configuration->parameters();
	splice @parameters, $pid, 1;
	$configuration->parameters(\@parameters);

	status 204; # No Content
	return '';
};

=head2 POST   /configurations/(id)/runs/

Start a new run using the given configuration.
The body should be a form-encoded submission with fields:

=over 4

=item client

The URI of the PlumageClient API endpoint on which to instance this run.

=item param_I<name>

Parameters for the configuration template.
These will have the C<param_> stripped for passing to the template.

=back

Returns a 201 Created with a Location header for the URI for the run, and a
plaintext body with the ID of the run.

This is deliberately not Backbone-shaped since creating a run is not just
manipulating a data structure; it has side-effects.

=cut

post '/configurations/:cid/runs/' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	# Unpack submission details needed for the run
	my $body_params = request->params('body') // {};
	my $client = $body_params->{'client'};
	return send_error('Missing client', 400) unless defined $client;

	my %parameters;
	foreach my $body_param (keys %$body_params) {
		if($body_param =~ /^param_(.*)$/) {
			$parameters{$1} = $body_params->{$body_param};
		}
	}

	# Get supporting files in appropriate LWP format
	my $supporting = $configuration->supporting();
	my @supporting_data;
	foreach my $supporting_name ($supporting->files()) {
		push @supporting_data, 'supporting';
		push @supporting_data, [
			undef, $supporting_name,
			Content_Type => 'application/octet-stream',
			Content => $supporting->file($supporting_name),
		];
	}

	# Create out local record of the run
	my $runs = $configuration->runs();
	my $rid = $runs->create($client, \%parameters);
	my $run = $runs->run($rid);

	# Get parameters in appropriate LWP format.
	# This is a little silly since we just stripped this prefix off and we
	# could pass through a filtered set, but it makes the code boundaries
	# clearer.
	# Parenthesese inside the map block are needed to disambiguate; see
	# perldoc -f map.
	my @parameters_lwp = map {( "param_$_" => $parameters{$_} )} keys %parameters;

	# Work out the notification URI for termination
	my $notify = ''.uri_for("/api/1/configurations/$cid/runs/$rid/notify");

	# Prepare a user-agent to prod the client web service
	my $ua = LWP::UserAgent->new();
	$ua->timeout(5);
	$ua->env_proxy();

	# Poke the client to start the run
	my $request = POST($client.'runs/',
		Content_Type => 'form-data',
		Content => [
			'notify' => $notify,
			'configuration.tt' => [
				undef, 'configuration.pg.tt',
				Content_Type => 'text/plain',
				Content => $configuration->template(),
			],
			# These flatten into more pairs; remember, => is a comma
			@supporting_data,
			@parameters_lwp,
		],
	);
	my $response = $ua->request($request);

	my $client_run;
	try {

		unless($response->is_success()) {
			die "Starting client job failed:\n".$response->as_string()."\n"
				."Request was:\n".$request->as_string();
		}

		$client_run = $response->header('Location');
		die "Client claimed to start run but did not return URI for it!\n"
			unless defined $client_run;

	} catch {
		my $original = $_;
		# Try to clean up the run we created so we don't make ghosts. Catch if
		# *this* dies so we don't mask the original exception.
		try {
			$runs->delete($rid);
		} catch {
			warn "Died trying to clean up! $_\nOriginal exception:\n";
		};
		# Now rethrow the original exception
		die $original;
	};

	# Get the event URI from the client
	my $events = $client_run; # Content type negotation should make this work anyway
	$response = $ua->simple_request(GET $client_run, Accept => 'text/event-stream');
	if($response->code() == 303) {
		my $location = $response->header('Location');
		if(defined $location) {
			$events = $location;
		} else {
			# Make this nonfatal for robustness; a broken event stream
			# shouldn't now cause us to drop our started run on the floor.
			warn "Didn't get redirected to the event stream!\n";
		}
	} else {
		# Same logic w.r.t. only a warning
		warn 'Unexpected response when looking for event stream: '.
			$response->message()."\n";
	}

	# Start the run on our side
	$run->start($client_run, $events);

	# Tell *our* caller how we refer to the run
	my $uri = ''.uri_for("/api/1/configurations/$cid/runs/$rid");
	status 201;
	header Location => $uri;
	content_type 'text/plain';
	return "$rid\n";
};

=head2 GET    /configurations/(id)/runs/

Get a JSON array of partial representations of runs, each as a hash containing
the following:

=over 4

=item id

Unique, unchanging identifier for the run.

=item time

The time of the start of the run in ISO 8601 format. I<Immutable.>

=item comment

User-editable comment.

=item client

The text/plain URI of the client endpoint used for the run. I<Immutable.>

=item parameters

JSON object of the parameters used for the run.
These do not have any C<param_> prefixes from the form submission.
I<Immutable.>

=item running

Boolean indicating if the run is still in progress.

=item has_report

Boolean indicating if the run has a report.
A finished run may not have a report if it was aborted or failed.

=back

=cut

get '/configurations/:cid/runs/' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $runs = $configuration->runs();

	return [ map {
		my $run = $runs->run($_);
		{
			id         => $_,
			time       => $run->time(),
			comment    => $run->comment(),
			client     => $run->client(),
			parameters => $run->parameters(),
			running    => $run->running() ? JSON::true : JSON::false,
			has_report => (defined $run->report_dir()) ? JSON::true : JSON::false,
		};
	} $runs->runs() ];
};

=head2 GET    /configurations/(id)/runs/(id)

URI for a run.
Returns a single JSON object as per the collection format above.

=cut

get '/configurations/:cid/runs/:rid' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	return {
		id         => $rid,
		time       => $run->time(),
		comment    => $run->comment(),
		client     => $run->client(),
		parameters => $run->parameters(),
		running    => $run->running() ? JSON::true : JSON::false,
		has_report => (defined $run->report_dir()) ? JSON::true : JSON::false,
	};
};

=head2 PUT    /configurations/(id)/runs/(id)

Sets the run's comment based off the JSON object in the request body, the same
format as the GET route.
This is mutable at any point so you can add and amend conclusions.
No other properties are mutable, and will be ignored.

=cut

put '/configurations/:cid/runs/:rid' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	my $data = request->serializer()->deserialize(request->body());

	$run->comment($data->{comment})
		if exists $data->{comment};

	status 204; # No Content
	return '';
};

=head2 GET    /configurations/(id)/runs/(id)/events

Redirects to the server-sent event stream directly from the client.
See the client API documentation.

Once the run has stopped, returns 410 Gone.

=cut

# TODO In future, should be possible to run a replay of the events from
#      plumage_run.log

get '/configurations/:cid/runs/:rid/events' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	my $events = $run->events();
	if(defined $events) {
		return redirect $events;
	} else {
		return send_error('Run has stopped', 410);
	}
};

=head2 GET    /configurations/(id)/runs/(id)/report/

Returns the HTML index page of the Polygraph report for this run, assuming it
completed successfully.
This HTML document will refer to further resources under this prefix.

=cut

# Redirect to the directory version so relative URIs work consistently
get '/configurations/:cid/runs/:rid/report' => sub {
	my $cid = request->params('route')->{'cid'};
	my $rid = request->params('route')->{'rid'};
	return redirect ''.uri_for("/api/1/configurations/$cid/runs/$rid/report/");
};

# The megasplat does not match 'nothing', so handling the index page requires a
# separate route
get '/configurations/:cid/runs/:rid/report/' => sub {
	# Forward this internally; it's an index document, not a redirect
	my $cid = request->params('route')->{'cid'};
	my $rid = request->params('route')->{'rid'};
	forward "/api/1/configurations/$cid/runs/$rid/report/index.html";
};

# There is a Dancer bug, unfixed in the old Ubuntu version, which stops
#     get '/configurations/:cid/runs/:rid/report/**'
# from working: https://github.com/PerlDancer/Dancer2/pull/729
# So we have to fake this with nothing but splats.
get '/configurations/*/runs/*/report/**' => sub {
	my ($cid, $rid, $path) = splat; # scalar, scalar, arrayref

	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	# We should clean up the path to avoid things like ../../../../etc/passwd.
	# Unfortunately File::Spec et. al. are useless here because they are
	# worrying about symlinks, and Cwd isn't appropriate since we want to
	# sanitize this path *before* touching the filesystem, not interpret it
	# according *to* the filesystem.
	my @path_components;
	foreach my $component (@$path) {
		if(     $component eq '.') {
			# do nothing
		} elsif($component eq '..') {
			# omit this and remove the previous, if any
			pop @path_components;
		} else {
			# keep this one
			push @path_components, $component;
		}
	}
	# Ok, now base this under our report directory.
	my $report_base = $run->report_dir();
	my $file = "$report_base/".join('/', @path_components);
	# And send it, allowing it to be outside the public/ directory
	return send_file($file, system_path => 1);
};

=head2 DELETE /configurations/(id)/runs/(id)/abort

I<Alternate resource identifier> to abort a run without deleting it.
This terminates the run (soon) and gathers its results, which may be desirable
if it has been running for hours, has encountered problems, but you wish to
preserve a record of these problems.

=cut

# You can't do "any ['abort'] => '...run ID...'"; Dancer plain doesn't seem to
# support non-standard HTTP methods.

del '/configurations/:cid/runs/:rid/abort' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	# Make a API request to the client to abort the run.
	# The notification postback will then make us update our state.
	_delete_client_run($run);

	status 204; # No Content
	return '';
};

# Private function to send the API request to delete a client run. Takes the run.
# No-op if there is no client-side run (e.g. already deleted).
sub _delete_client_run {
	my ($run) = @_;
	my $client_run = $run->client_run();
	if(defined $client_run) {
		my $ua = LWP::UserAgent->new();
		$ua->timeout(5);
		$ua->env_proxy();
		my $response = $ua->delete($run->client_run());
		die 'Deleting client job failed: '.$response->message()."\n"
			unless $response->is_success();
	}
}

=head2 DELETE /configurations/(id)/runs/(id)

Permanently delete a run, including its results.
If the run is still running, it is first aborted.

=cut

del '/configurations/:cid/runs/:rid' => sub {
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	# Delete it client-side
	_delete_client_run($run);

	if(defined $configuration->runs()->delete($rid)) {
		status 204; # No Content
		return '';
	} else {
		return send_error('No such run', 404); # ...went missing somehow
	}
};

# POST /configurations/(id)/runs/(id)/notify
# Private API call.
# The Client uses this to tell the Master to pull the results of now-terminated
# run. The Client discovers this URI because it is passed to them during run
# creation.

post '/configurations/:cid/runs/:rid/notify' => sub {
	# TODO Make sure exceptions here to an error log; Plackup/Starman/Dancer
	#      keep losing them, and any version returned down the HTTP response
	#      will only end up in a plumage_run log which gets unlinked halfway
	#      through.
	my $cid = request->params('route')->{'cid'};
	my $configuration = Plumage::Model->new()->configurations()->configuration($cid);
	return send_error('No such configuration', 404)
		unless defined $configuration;

	my $rid = request->params('route')->{'rid'};
	my $run = $configuration->runs()->run($rid);
	return send_error('No such run', 404)
		unless defined $run;

	# Fetch the results from the client
	my $ua = LWP::UserAgent->new();
	$ua->timeout(5);
	$ua->env_proxy();
	my $response = $ua->get(
		$run->client_run(),
		Accept => 'application/x-tar',
	);

	# And now delete the client's record of them to tidy it up
	_delete_client_run($run);

	# Do something with the results now we've cleaned up
	# TODO Better handling of runs which terminate without results, e.g. here
	die 'Fetching client results failed: '.$response->message()."\n"
		unless $response->is_success();

	$run->set_results($response->decoded_content(raise_error => 1));

	status 204; # No Content
	return '';
};

=head2 GET    /clients

Returns a JSON array of client endpoint URIs as defined by the installation.
These are appropriate values to pass when starting a run.

=cut

get '/clients' => sub {
	my @clients = Plumage::Model->new()->clients();
	return \@clients;
};

=head2 GET    /doc

Return this API documentation.

=cut

get '/doc' => sub {
	return Plumage::PublishAPI::publish(__FILE__);
};

}}; # End non-indenting version 1 API prefix

=head2 GET /

B<Not an API route.>

Redirects to the current API documentation.

=cut

get '/' => sub {
	return redirect ''.uri_for('/api/1/doc');
};

true;

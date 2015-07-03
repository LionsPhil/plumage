# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

package PlumageUI;
use Dancer2;

our $VERSION = '0.2';

use File::Slurp qw();
use HTTP::Request::Common;
use JSON qw();
use LWP::UserAgent;
use Try::Tiny;

hook before => sub {
	# Load the configuration
	my $config_filename = "$FindBin::Bin/../etc/plumageui.json";
	my $config = JSON::decode_json(File::Slurp::read_file($config_filename));

	# Note that we add the API path to this configuration
	var master_base =>
		($config->{master_base} // 'http://localhost:5000/')
		.'api/1/';

	# Prepare a suitable user agent
	my $ua = LWP::UserAgent->new();
	$ua->timeout(10); # be as patient as we can get away with
	$ua->env_proxy();

	var user_agent => $ua;

	# Dig out sane IDs from route parameters
	foreach my $id_type (qw(cid rid)) {
		my $id = request->params('route')->{$id_type} // '';
		if($id =~ /^[0-9]+$/) {
			var $id_type => $id;
		}
	}
};

# Passthrough function to turn UA failures into exceptions
# TODO When this encounters a 404, in many cases that should propagate out from
#      us, e.g. because a configuration or run does not exist.
sub _throw_on_fail {
	my ($response) = @_;

	unless($response->is_success()) {
		# Unfortunately at this point we don't have the context for the request
		# any more.
		die "API call failed:\n".$response->as_string();
	}

	return $response;
}

# Helper function for JSON-returning API calls, taking arbitrary HTTP::Request
sub _request_json {
	my ($request) = @_;

	my $data;
	try {
		my $response = _throw_on_fail(var('user_agent')->request($request));
		my $content = $response->decoded_content(raise_error => 1);
		try {
			$data = JSON::decode_json($content);
		} catch {
			require Data::Dumper;
			die "API call JSON parse failed: ${_}Got:\n".Data::Dumper::Dumper($content)."\n";
		};
	} catch {
		die "${_}While attempting: ".$request->as_string();
	};

	return $data;
}

# Helper function for most common case: GET some JSON-format data at a path
sub _get_json {
	my ($path) = @_;

	return _request_json(GET var('master_base').$path);
}

# Routes

# Default; redirect to the list of configurations
get '/' => sub {
	return redirect uri_for '/configurations/';
};

# Show the list of configurations
get '/configurations/' => sub {
	my @configurations = sort {
		$a->{name} cmp $b->{name}
	} @{_get_json('configurations/')};

	# TODO Amend Master API to give run counts under each configuration and
	#      include in template params so badges work. (Not wanting to make N
	#      subrequests here.)

    template 'configurations', {
		configurations => \@configurations,
	};
};

# Create a new configuration then redirect to the display route for it.
# This is invoked via AJAX to get the correct non-idempotent HTTP method.
post '/configurations/' => sub {
	my $configuration = _request_json(POST var('master_base').'configurations/');
	my $id = $configuration->{id} // die 'New configuration has no ID';

	status 201; # Created
	content_type 'text/plain';
	return uri_for "/configurations/$id/edit";
};

# Display a configuration (and its runs)
get '/configurations/:cid' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $configuration =   _get_json("configurations/$cid");
	my @runs          = @{_get_json("configurations/$cid/runs/")};

	# These are ISO timestamps, so sort stringwise
	@runs = sort { $a->{time} cmp $b->{time} } @runs;

	# Get the parameter list from one of the runs, for table headings
	# TODO Get this from the configuration; possible within its GET API
	my @parameters;
	if(@runs) {
		@parameters = keys %{$runs[0]->{parameters}};
	}

	template 'configuration', {
		configuration => $configuration,
		runs          => \@runs,
		parameters    => \@parameters,
	};
};

# Get the form to edit a configuration
get '/configurations/:cid/edit' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $configuration = _get_json("configurations/$cid");
	my $supporting    = _get_json("configurations/$cid/supporting/");
	my $parameters    = _get_json("configurations/$cid/parameters/");

	template 'configuration-edit', {
		configuration => $configuration,
		supporting    => $supporting,
		parameters    => $parameters,
	};
};

# Save (partial) changes to a configuration
post '/configurations/:cid/edit' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $post = request->params('body') // {};

	# See if this configuration already has runs
	my $configuration = _get_json("configurations/$cid");
	my $has_runs = $configuration->{runs};

	# Build a JSON representation from our post data and save it
	my $configuration_data = {
		name     => $post->{name} // 'Unnamed Configuration',
		comment  => $post->{comment} // '',
		template => $post->{template} // '',
	};
	_throw_on_fail(var('user_agent')->put(
		var('master_base')."configurations/$cid",
		Content_Type => 'application/json',
		Content => JSON::encode_json($configuration_data)));

	# If we have runs, this is the only thing that can be changed.
	# (The master API will happily ignore reasserting the template.)
	# Early exit, and we know it must be to return to the view.
	if($has_runs) {
		return redirect uri_for "/configurations/$cid";
	}

	# Build an array of parameters and reset it
	# (This means you can delete them by blanking the textfields; a fancier
	# approach would be to difference the lists)
	# First turn the pairs of text inputs into an id => { name, default } hash.
	my %parameter_data_hash;
	foreach my $field_name (keys %$post) {
		if($field_name =~ /^parameter-([0-9]+)-(.+)/) {
			my ($id, $role) = ($1, $2);
			$parameter_data_hash{$id} //= {};
			$parameter_data_hash{$id}->{$role} = $post->{$field_name};
		}
	}
	# Now boil that down into an array, preserving ID ordering
	my @parameter_data;
	foreach my $parameter_id (sort { $a <=> $b } keys %parameter_data_hash) {
		my $parameter = $parameter_data_hash{$parameter_id};
		$parameter->{name}    //= 'unamed_parameter';
		$parameter->{default} //= '';
		if($parameter->{name} ne '')
			{ push @parameter_data, $parameter; }
	}
	# And set it
	_throw_on_fail(var('user_agent')->put(
		var('master_base')."configurations/$cid/parameters/",
		Content_Type => 'application/json',
		Content => JSON::encode_json({'parameters' => \@parameter_data})));

	# Process a supporting file removal, if any
	foreach my $field_name (keys %$post) {
		if($field_name =~ /^delete-(.+)/) {
			my $filename = $1;
			_throw_on_fail(var('user_agent')->delete(
				var('master_base')."configurations/$cid/supporting/$filename"));
		}
	}

	# Process a supporting file upload, if any
	if(exists $post->{'supporting-go'}) {
		my $upload = upload('supporting-upload');
		if($upload) {
			my $content = $upload->content();
			my $filename = $post->{'supporting-as'} // '';
			if($filename eq '')
				{ $filename = $upload->basename(); }
			# TODO Report errors better from this; user error like invalid
			#      upload names should not cause generic 500s.
			_throw_on_fail(var('user_agent')->put(
				var('master_base')."configurations/$cid/supporting/$filename",
				Content_Type => 'application/octet-stream',
				Content => $content));
		} # not a problem otherwise, they just clicked the wrong submit button
	}

	# If they saved, send them back to viewing the now-changed configuration.
	# Else they did something with supporting files, so send them back to
	# GETting the edit form.
	if(exists $post->{'save'}) {
		return redirect uri_for "/configurations/$cid";
	} else {
		return redirect uri_for "/configurations/$cid/edit";
	}
};

# This is just a confirmation screen
get '/configurations/:cid/delete' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $configuration = _get_json("configurations/$cid");

	template 'configuration-delete', {
		configuration => $configuration,
	};
};

# This is the actual confirmation to perform the deletion
post '/configurations/:cid/delete' => sub {
	my $cid = var('cid') // die 'Missing CID';

	_throw_on_fail(var('user_agent')->delete(
		var('master_base')."configurations/$cid"));

	return redirect uri_for "/configurations/";
};

# Present the form to start a run
get '/configurations/:cid/runs/new' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $configuration = _get_json("configurations/$cid");
	my $parameters    = _get_json("configurations/$cid/parameters/");
	my $clients       = _get_json("clients");

	template 'run-start', {
		configuration => $configuration,
		parameters    => $parameters,
		clients       => $clients,
	};
};

# Actually start a run
post '/configurations/:cid/runs/new' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $configuration = _get_json("configurations/$cid");
	my $post = request->params('body') // {};

	my $client = $post->{'client'} // die 'Missing client';

	# Get the parameters as a hash, with the required prefix for the API
	# FIXME Parameters are wide strings. This causes explosions in
	#       HTTP::Message if a parameter value is non-ASCII.
	my %parameters;
	foreach my $field_name (keys %$post) {
		if($field_name =~ /^param-(.+)/) {
			my $param_name = $1;
			my $param_value = $post->{$field_name};
			$parameters{"param_$param_name"} = $param_value;
		}
	}

	# Build and submit the request
	my $request = POST(var('master_base')."configurations/$cid/runs/",
		Content_Type => 'form-data',
		Content => [
			'client' => $client,
			%parameters, # flattens out here
		],
	);
	my $response = _throw_on_fail(var('user_agent')->request($request));

	# Redirect to the run in progress based on the response
	my $rid = $response->decoded_content(raise_error => 1);
	chomp $rid;
	die "Unexpected non-numeric run ID" unless $rid =~ /^[0-9]+$/;

	return redirect uri_for "/configurations/$cid/runs/$rid";
};

# Display a run, possibly which is in progress
get '/configurations/:cid/runs/:rid' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $rid = var('rid') // die 'Missing RID';
	my $configuration = _get_json("configurations/$cid");
	my $run           = _get_json("configurations/$cid/runs/$rid");

	if($run->{'running'}) {
		# TODO Show a different template, when we log/CPU feeds
	}

	# TODO This should really be the order defined by the configuration, but at
	#      least this ordering is stable.
	my @parameters_ordered = sort keys %{$run->{'parameters'}};

	template 'run', {
		configuration     => $configuration,
		run               => $run,
		parameters_ordered => \@parameters_ordered,
	};
};

# Update the comment for a run
post '/configurations/:cid/runs/:rid' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $rid = var('rid') // die 'Missing RID';
	my $post = request->params('body') // {};

	my $run_data = {
		comment  => $post->{'comment'} // '',
	};
	_throw_on_fail(var('user_agent')->put(
		var('master_base')."configurations/$cid/runs/$rid",
		Content_Type => 'application/json',
		Content => JSON::encode_json($run_data)));

	# Redirect back to viewing the run (TODO better feedback)
	return redirect uri_for "/configurations/$cid/runs/$rid";
};

# Redirect through to the report for a run
get '/configurations/:cid/runs/:rid/report/' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $rid = var('rid') // die 'Missing RID';

	return redirect var('master_base')."configurations/$cid/runs/$rid/report/";
};

# This is just a confirmation screen
get '/configurations/:cid/runs/:rid/delete' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $rid = var('rid') // die 'Missing RID';
	my $configuration = _get_json("configurations/$cid");
	my $run           = _get_json("configurations/$cid/runs/$rid");

	template 'run-delete', {
		configuration => $configuration,
		run           => $run,
	};
};

# This is the actual confirmation to perform the deletion
post '/configurations/:cid/runs/:rid/delete' => sub {
	my $cid = var('cid') // die 'Missing CID';
	my $rid = var('rid') // die 'Missing RID';

	_throw_on_fail(var('user_agent')->delete(
		var('master_base')."configurations/$cid/runs/$rid"));

	return redirect uri_for "/configurations/$cid";
};

# TODO Future enhancements:
# - Show node states on frontpage (requires list-of-running-runs API);
#   store CID/RID metadata with the transient runs so the UI can link which
#   persistent run they are busy with
# - Show busy state of machines when selecting pair to start a run one
#   (requires some of API above)
# - Short views of comments (in lists/tables) should only use the first line
# - Comments should be processed as MarkDown; T::T filter exists:
#   http://lists.template-toolkit.org/pipermail/templates/2008-March/010095.html
# - Copy-configuration functionality, so that copy can be edited
# - Event stream from plumage_run (requires API implementation)
#   https://developer.mozilla.org/en-US/docs/Server-sent_events/Using_server-sent_events
# - Max/peak CPU usage gauge while run is process (requires API implementation)
#   http://justgage.com/
#   http://smart-ip.net/gauge.html
#   https://github.com/Mikhus/canv-gauge

true;

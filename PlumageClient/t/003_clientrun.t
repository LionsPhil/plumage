#!/usr/bin/perl
# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

# During testing, we won't have the common code copied into place, so cheat it
# with @INC.
use lib qw(../common/lib ../../common/lib);

use Test::Spec;
use Test::MockModule;

use Archive::Tar;
use File::Slurp;
use File::Temp;
use IO::Scalar;
# We both mock *and* use File::Slurp for the tests. Importing its subs prevents
# the mock being able to intercept them, but even if that starts working it
# provides a passthrough for all but the target file.

use PlumageClientRun;

describe 'Plumage client run' => sub {
	# These require a mocked environment, since mocking the file test
	# operators, statting/reading /proc, etc. would be nightmarish.
	# Careful; this isn't a sandbox! Bugs might still delete random files.
	describe 'when executing' => sub {
		my $mock_file_slurp;
		my $tmpdir_handle;
		my $tmpdir;
		my $run;

		before 'each' => sub {
			# Create a virtual environment
			$tmpdir_handle = File::Temp->newdir(
				TEMPLATE => 'plumage-test-XXXXXXXX',
				TMPDIR => 1);
			$tmpdir = $tmpdir_handle->dirname();
			diag "Virtual environment in $tmpdir\n";

			# Put a fake plumage_run process within it for us to use
			# The sleep here will cause kill -9 to kick in
			my $fake_plumage_run = <<'EOFAKEPLUMAGERUN';
#!/bin/sh
echo $*
set -e
mkdir "$2/client"
sleep 5
echo 'ran' > "$2/client/console0.log"
mkdir "$2/report"
EOFAKEPLUMAGERUN
			my $fake_plumage_run_path = "$tmpdir/fake_plumage_run";
			write_file($fake_plumage_run_path, $fake_plumage_run);
			chmod 0700, $fake_plumage_run_path
				or die "test suite chmod failed: $!\n";

			# Fake a configuration to read which points to this environment
			# We let it use the real system tar, though
			$mock_file_slurp = Test::MockModule->new('File::Slurp');
			$mock_file_slurp->mock('read_file', sub {
				my ($filename, @other) = @_;
				if($filename =~ m!/plumageclient\.json$!) {
					return <<"EOFAKECONFIG";
{
	"state_dir": "$tmpdir/",
	"plumage_run_binary": "$fake_plumage_run_path",
	"host_parameters": {
		"host_chassis_colour": "beige"
	}
}
EOFAKECONFIG
				} else {
					# Our mocking will hit Common code, and might even hit the
					# tests below, so pass through to the real read_file.
					return $mock_file_slurp->original('read_file')->($filename, @other);
				}
			});
		};
		after 'each' => sub {
			# Actually deleting the files is handled by File::Temp, but we do
			# want to kill processes, and we shall assume this functionality
			# works because all we could do otherwise is duplicate it here with
			# all the same bugs. (It's also a thing wrapper around a tested
			# Common function.)
			if(defined $run) {
				diag "Killing run...\n";
				$run->kill();
				$run = undef;
			}
		};

		# We do not test configuration writing in depth here since it is common
		# code which is tested both as part of Plumage::Common, and again by
		# PolygraphServerRun.

		it 'populates the configuration template with runtime parameters' => sub {
			$run = PlumageClientRun->new(
				'foo [% bar %] baz',
				{ bar => 'quux' },
				{},
				undef
			);
			is(read_file("$tmpdir/0/pr/configuration/configuration.pg"),
				'foo quux baz');
		};

		it 'populates the configuration template with host parameters' => sub {
			$run = PlumageClientRun->new(
				'foo [% host_chassis_colour %] baz',
				{},
				{},
				undef
			);
			is(read_file("$tmpdir/0/pr/configuration/configuration.pg"),
				'foo beige baz');
		};

		it 'rejects conflicts of runtime and host parameters' => sub {
			trap {
				$run = PlumageClientRun->new(
					'foo [% host_chassis_colour %] baz',
					{ host_chassis_colour => 'brushed aluminium' },
					{},
					undef
				);
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/conflicts with host configuration/);
		};

		it 'generates a default report name' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			sleep 1; # Allow dummy process to produce output
			like(read_file("$tmpdir/0/plumage_run.log"), qr/^[a-zA-Z0-9.:_-]+ /);
		};

		it 'detects custom report names' => sub {
			my $config =<<'CUSTOMREPORTNAMECONFIG';
Foo
//plumage//reportname//things_[% name %]_stuff
Bar
CUSTOMREPORTNAMECONFIG
			$run = PlumageClientRun->new(
				$config,
				{ name => 'wibble' },
				{},
				undef
			);
			sleep 1;
			like(read_file("$tmpdir/0/plumage_run.log"), qr/^things_wibble_stuff[a-zA-Z0-9.:_-]+ /);
		};

		it 'refuses invalid report names' => sub {
			my $config =<<'CUSTOMREPORTNAMECONFIG2';
Foo
//plumage//reportname//You can't call it this!
Bar
CUSTOMREPORTNAMECONFIG2
			trap {
				$run = PlumageClientRun->new($config, {}, {}, undef);
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/Forbidden characters in report name/);
		};

		it 'adds a datestamp' => sub {
			my $datetime = Test::MockModule->new('DateTime');
			$datetime->mock('iso8601', sub { 'DATESTAMP' });

			$run = PlumageClientRun->new(
				'//plumage//reportname//NAME',
				{},
				{},
				undef
			);
			sleep 1;
			like(read_file("$tmpdir/0/plumage_run.log"), qr/^NAME_DATESTAMP /);
		};

		it 'passes notify URIs through to plumage_run' => sub {
			$run = PlumageClientRun->new('', {}, {},
				'http://polymaster/run/0/done');
			sleep 1;
			like(read_file("$tmpdir/0/plumage_run.log"),
				qr| http://polymaster/run/0/done$|);
		};

		# That it invokes plumage_run at all is implicitly tested by the above
		# using our dummy to read back the report name command line it was
		# given.

		it 'detects if plumage_run is still running' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			ok($run->running());
			sleep 7;
			ok(!$run->running());
		};

		it 'detects if plumage_run has finished but not yet exited' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			ok(!$run->finished());
			write_file("$tmpdir/0/pr/done"); # fake plumage_run activity
			ok($run->finished());
		};

		it 'refuses to give results until finished' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			trap {
				$run->results(1);
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/Cannot get results until finished/);
		};

		it 'gives results after process exits' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			sleep 7; # let the run finish and exit
			# fake plumage_run fails to write the donefile
			my $tarball = $run->results(1);
			my $tar = Archive::Tar->new(IO::Scalar->new(\$tarball));

			ok($tar->contains_file('plumage_run.log')) &&
			ok($tar->contains_file('configuration/configuration.pg')) &&
			ok($tar->contains_file('report/')) &&
			ok($tar->contains_file('client/console0.log'))
			|| do {
				diag "Got tar contents:";
				foreach my $file ($tar->list_files())
					{ diag $file; }
			};

			is($tar->get_content('client/console0.log'), "ran\n");
		};

		it 'gives results if finished before process exit' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			sleep 2; # Give the process a moment to create files
			write_file("$tmpdir/0/pr/done"); # fake plumage_run
			trap {
				# All we care about is that this doesn't throw; the actual
				# return value is tested above
				$run->results(0);
			};
			diag $trap->stderr() if $trap->stderr();
			ok($trap->did_return());
		};

		it 'kills on command' => sub {
			# Assumes running() works, which is tested above
			$run = PlumageClientRun->new('', {}, {}, undef);
			$run->kill();
			ok(!$run->running());
		};

		it 'can clean up a run which has finished' => sub {
			$run = PlumageClientRun->new('', {}, {}, undef);
			sleep 7; # let the run finish
			$run->delete(); # if this dies, it will fail the test (correctly)
			$run = undef; # stop after() handler trying to double-free
			ok(! -e "$tmpdir/0"); # if not zero, earlier tests will have failed
		};
	};
};

runtests unless caller;

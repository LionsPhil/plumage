#!/usr/bin/perl
# Copyright 2014-2015 Philip Boulain <philip.boulain@smoothwall.net>
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

use File::Slurp;
use File::Temp;

use PolygraphServerRun;

describe 'Polygraph server run' => sub {
	# These require a mocked environment, since mocking the file test
	# operators, statting/reading /proc, etc. would be nightmarish.
	# Careful; this isn't a sandbox! Bugs might still delete random files.
	describe 'when executing' => sub {
		my $mock_cpus;
		my $mock_file_slurp;
		my $tmpdir_handle;
		my $tmpdir;
		my $run;

		before 'all' => sub {
			# Set a known number of CPU cores for stable results across hosts
			$mock_cpus = Test::MockModule->new('Sys::CPU');
			$mock_cpus->mock('cpu_count', sub { return 4; });
		};

		before 'each' => sub {
			# Create a virtual environment
			$tmpdir_handle = File::Temp->newdir(
				TEMPLATE => 'plumage-test-XXXXXXXX',
				TEMPDIR => 1);
			$tmpdir = $tmpdir_handle->dirname();
			diag "Virtual environment in $tmpdir\n";

			# Put a fake server process within it for us to use
			# The sleep here will cause kill -9 to kick in
			my $fake_polyserver = <<'EOFAKEPOLYSERVER';
#!/bin/sh
echo $*
echo 'Warning: BEES' >&2
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--log" ]; then
		shift
		echo 'data' >> $1
	fi
	shift
done
sleep 5
EOFAKEPOLYSERVER
			my $fake_polyserver_path = "$tmpdir/fakepolyserver";
			write_file($fake_polyserver_path, $fake_polyserver);
			chmod 0700, $fake_polyserver_path
				or die "test suite chmod failed: $!\n";

			# Fake a configuration to read which points to this environment
			$mock_file_slurp = Test::MockModule->new('File::Slurp');
			$mock_file_slurp->mock('read_file', sub {
				my ($filename, @other) = @_;
				if($filename =~ m!/plumageserver\.json$!) {
					return <<"EOFAKECONFIG";
{
	"state_dir": "$tmpdir/",
	"polygraph_server_binary": "$fake_polyserver_path",
	"agent_prefix": "10.0.132",
	"agent_octet_min": 2,
	"agent_octet_max": 5
}
EOFAKECONFIG
				} else {
					# Our mocking will hit Common code, so pass through to the
					# real read_file.
					return $mock_file_slurp->original('read_file')->($filename, @other);
				}
			});
		};
		after 'each' => sub {
			# Actually deleting the files is handled by File::Temp, but we do
			# want to kill processes, and we shall assume this functionality
			# works because all we could do otherwise is duplicate it here with
			# all the same bugs.
			if(defined $run) {
				diag "Deleting run...\n";
				$run->delete();
				$run = undef;
			}
		};

		it 'writes configuration files' => sub {
			$run = PolygraphServerRun->new('configuration', {
				'extra.pgd' => 'extra',
			});
			my $id = $run->id();
			is(read_file("$tmpdir/$id/configuration.pg"), 'configuration');
			is(read_file("$tmpdir/$id/extra.pgd"), 'extra');
		};

		it 'refuses to write configuration files outside of its state directory' => sub {
			trap { $run = PolygraphServerRun->new('configuration', {
				'/tmp/outside' => 'badness',
			}); };
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/contains path components/);

			trap { $run = PolygraphServerRun->new('configuration', {
				'..' => 'badness',
			}); };
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/is hidden/);

			trap { $run = PolygraphServerRun->new('configuration', {
				'polygraph0.pid' => 'badness',
			}); };
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/may conflict/);
		};

		it 'runs polygraph instances' => sub {
			$run = PolygraphServerRun->new('configuration');
			my $id = $run->id();

			# Let the subprocesses run. Timing-sensitive tests, yay!
			sleep 2;

			# We don't go grubbing in /proc ourselves; we can be confident that
			# these files can only be created by our shell script above being
			# invoked, outside of malicious cases.
			foreach my $pnum (0 .. 3) {
				# Tracks their PIDs
				like(read_file("$tmpdir/$id/polygraph$pnum.pid"), qr/^[0-9]+$/);

				# They create binary logs
				ok(-e "$tmpdir/$id/binary$pnum.log");

				# Passes them correct arguments and redirects their output to console
				my $octet = $pnum + 2;
				my $expected_console = <<"EXPECTEDCONSOLE";
--config configuration.pg --verb_lvl 10 --log binary$pnum.log --idle_tout 1min --fake_hosts 10.0.132.$octet-$octet
Warning: BEES
EXPECTEDCONSOLE
				is(read_file("$tmpdir/$id/console$pnum.log"), $expected_console);
			}

			# Doesn't create a fifth
			ok(! -e "$tmpdir/$id/polygraph4.pid");
		};

		it 'finds an existing run, and its server IDs' => sub {
			$run = PolygraphServerRun->new('configuration');
			my $id = $run->id();

			my $run_again = PolygraphServerRun->new_existing($id);
			is_deeply([$run_again->server_ids()], [0, 1, 2, 3]);
		};

		it 'detects if the servers are still running' => sub {
			$run = PolygraphServerRun->new('configuration');
			ok($run->running());
			sleep 7;
			ok(!$run->running());
		};

		# Skip testing console() until API settles

		it 'does not return binary log output during run' => sub {
			$run = PolygraphServerRun->new('configuration');
			ok(!defined $run->log(0));
		};

		it 'returns binary log output' => sub {
			$run = PolygraphServerRun->new('configuration');
			sleep 7;
			foreach my $sid ($run->server_ids()) {
				is($run->log($sid), "data\n");
			}
		};

		it 'can clean up a test which has finished' => sub {
			# Testing the delete()-while-running case is done repeatedly by the
			# after() handler
			$run = PolygraphServerRun->new('configuration');
			my $id = $run->id();
			sleep 7;
			$run->delete(); # if this dies, it will fail the test (correctly)
			$run = undef; # stop after() handler trying to double-free
		};
	};
};

runtests unless caller;

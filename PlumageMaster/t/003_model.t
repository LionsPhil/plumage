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

use Plumage::Model;

# Hold on to $tmpdir for the duration of the entire test so the bit of shared
# mocking we are about to do works; notably we are NOT expanding the handle
# lifespan so at points this refers to a non-existent directory. That's fine;
# anything reading config at that point is broken and should fail-stop when it
# chokes on trying to work under it.
my $tmpdir;
my $mock_file_slurp;
# Fake a configuration to read which points to the temporary storage directory
# and has some test data for clients().
$mock_file_slurp = Test::MockModule->new('File::Slurp');
$mock_file_slurp->mock('read_file', sub {
	my ($filename, @other) = @_;
	if($filename =~ m!/plumagemaster\.json$!) {
		return <<"EOFAKECONFIG";
{
	"store_dir": "$tmpdir/",
	"client_bases": [
		"http://polyclient:5000/",
		"http://polyclient2:5000/"
	]
}
EOFAKECONFIG
	} else {
		# Pass through to the real read_file
		return $mock_file_slurp->original('read_file')->($filename, @other);
	}
});

describe 'Plumage model' => sub {
	# Testing the collection concept directly is a little white-box but avoids
	# us having to recover the same ground repeatedly in the different contexts
	# below.
	describe 'collection concept' => sub {
		my $tmpdir_handle;
		my $collection;

		before 'each' => sub {
			# Create a virtual environment
			$tmpdir_handle = File::Temp->newdir(
				TEMPLATE => 'plumage-test-XXXXXXXX',
				TMPDIR => 1);
			$tmpdir = $tmpdir_handle->dirname();
			diag "Virtual environment in $tmpdir\n";

			$collection = Plumage::Model::Collection->new($tmpdir);
		};
		# File::Temp will clean up automatically; don't need matching 'after'

		it 'generates an ID for a new element' => sub {
			my $cfg = $collection->create();
			ok(defined $cfg);
		};

		it 'returns a listing of all IDs' => sub {
			# At first it should be empty
			cmp_bag([ $collection->list() ], []);
			# Now add a couple of items
			my @ids;
			push @ids, $collection->create();
			push @ids, $collection->create();
			# It should now return them
			cmp_bag([ $collection->list() ], \@ids);
		};

		it 'returns a unique subpath for an item' => sub {
			my $id_1   = $collection->create();
			my $path_1 = $collection->at($id_1);
			like($path_1, qr/^\Q$tmpdir\E\//);

			my $id_2   = $collection->create();
			my $path_2 = $collection->at($id_2);
			isnt($path_2, $path_1);
		};

		it 'returns paths to create items at provided IDs' => sub {
			my $path = $collection->insert_at('boris');
			is($path, "$tmpdir/boris");
		};

		it 'prohibits unsafe IDs' => sub {
			trap {
				$collection->insert_at('some/subdir');
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/Unsafe ID.*in collection/);

			trap {
				$collection->insert_at('..');
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/Unsafe ID.*in collection/);

			trap {
				$collection->insert_at('.hidden');
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/Unsafe ID.*in collection/);
		};

		# These two tests peek into internals for the sake of covering some
		# more complicated error-recovery code
		it 'can not be tricked into creating arbitrary directories' => sub {
			write_file("$tmpdir/.next", "ARBITRARY");
			$collection->create();
			ok(! -e "$tmpdir/ARBITRARY");
		};

		it 'recovers from a missing next-ID file' => sub {
			my $id_1 = $collection->create();
			unlink "$tmpdir/.next" or die "test implemenation assumption failed";
			my $id_2 = $collection->create();
			isnt($id_2, $id_1);
		};

		it 'returns undef non-existant item' => sub {
			ok(!defined $collection->at('anything'));
		};

		it 'deletes an item' => sub {
			# Assume this works because we tested it above
			my $id = $collection->create();
			$collection->delete($id);
			# Check it's gone against two previous test results
			cmp_bag([ $collection->list() ], []);
			ok(!defined $collection->at($id));
		};

		it 'generates new IDs without re-use' => sub {
			my $id_1 = $collection->create();
			my $id_2 = $collection->create();
			$collection->delete($id_2);
			my $id_3 = $collection->create();
			isnt($id_3, $id_2);
		};
	};

	describe 'configuration' => sub {
		my $tmpdir_handle;
		my $cfg_collection;

		before 'each' => sub {
			# Create a virtual environment
			$tmpdir_handle = File::Temp->newdir(
				TEMPLATE => 'plumage-test-XXXXXXXX',
				TMPDIR => 1);
			$tmpdir = $tmpdir_handle->dirname();
			diag "Virtual environment in $tmpdir\n";

			$cfg_collection = Plumage::Model->new()->configurations();
		};

		# These tests are covered by testing the underlying collection.
		# If the wrapping of that collection breaks, later tests will fail.
		#it 'creates a new configuration';
		#it 'gives a listing of all IDs';
		#it 'deletes a configuration';
		#it 'generates new IDs without re-use';
		# But these have different types, so test them again:

		it 'retrieves a configuration' => sub {
			my $id = $cfg_collection->create();
			isa_ok($cfg_collection->configuration($id),
				'Plumage::Model::Configuration');
		};

		it 'does not retrieve a non-existant configuration' => sub {
			ok(!defined $cfg_collection->configuration('anything'));
		};

		describe 'for a configuration' => sub {
			my $configuration_id;
			my $configuration;

			before 'each' => sub {
				$configuration_id = $cfg_collection->create();
				$configuration = $cfg_collection->configuration($configuration_id);
			};

			after 'each' => sub {
				if(defined $configuration_id) { # see below; test deletes it
					$cfg_collection->delete($configuration_id);
				}
			};

			it 'round-trip stores a template' => sub {
				$configuration->template("TEMPLATE\nTEMPLATE\n");
				is($configuration->template(), "TEMPLATE\nTEMPLATE\n");
			};

			it 'adds, updates, and lists supporting files' => sub {
				# Starts empty
				cmp_bag([ $configuration->supporting()->files() ],
					[qw()]);

				# Adding a file lists it
				$configuration->supporting()->update('secret.key', '1111');
				cmp_bag([ $configuration->supporting()->files() ],
					[qw(secret.key)]);

				# Adding another file lists both
				$configuration->supporting()->update('ssl.conf', 'rot13');
				cmp_bag([ $configuration->supporting()->files() ],
					[qw(secret.key ssl.conf)]);

				# Replacing a file still only lists both once each
				$configuration->supporting()->update('secret.key', '1112');
				cmp_bag([ $configuration->supporting()->files() ],
					[qw(secret.key ssl.conf)]);
			};

			it 'round-trip stores a supporting file' => sub {
				$configuration->supporting()->update('secret.key', '1111');
				is($configuration->supporting()->file('secret.key'), '1111');
			};

			it 'deletes a supporting file' => sub {
				$configuration->supporting()->update('secret.key', '1111');
				$configuration->supporting()->delete('secret.key');
				cmp_bag([ $configuration->supporting()->files() ], []);
			};

			it 'round-trip stores a name' => sub {
				$configuration->name('SSL Stress Test');
				is($configuration->name(), 'SSL Stress Test');
			};

			it 'round-trip stores a comment' => sub {
				my $comment = "Proxy must import the supporting CA certificate\nand use 1.2.3.4 for DNS\n";
				$configuration->comment($comment);
				is($configuration->comment(), $comment);
			};

			it 'round-trip stores parameter info' => sub {
				$configuration->parameters([
					Plumage::Model::Configuration::Parameter->new(
						name    => 'proxy',
						default => '10.0.3.1',
					),
					Plumage::Model::Configuration::Parameter->new(
						name    => 'users',
						default => '500',
					),
				]);
				my @parameters = $configuration->parameters();
				is_deeply(\@parameters, [
					{
						name    => 'proxy',
						default => '10.0.3.1',
					}, {
						name    => 'users',
						default => '500',
					}
				]);
			};

			it 'gives access to a scoped run model' => sub {
				isa_ok($configuration->runs(),
					'Plumage::Model::Runs');
			};

			# [Im]mutability tests; this jumps ahead a bit
			describe 'with runs' => sub {
				my $run_id;

				before 'each' => sub {
					# Need a supporting file as well for read tests
					$configuration->supporting()->update('file', 'hello');
					$run_id = $configuration->runs()->create(
						'nonsense', {});
				};

				after 'each' => sub {
					if(defined $configuration_id) { # see below; test deletes it
						$configuration->runs()->delete($run_id);
						$configuration->supporting()->delete('file');
					}
				};

				it 'disallows changing the template' => sub {
					$configuration->template(); # Read still musn't die
					trap {
						$configuration->template('oops');
					};
					diag $trap->stderr() if $trap->stderr();
					like($trap->die(), qr/Cannot modify.*configuration with runs/);
				};

				it 'disallows changing supporting files' => sub {
					$configuration->supporting()->file('file'); # Read still mustn't die
					trap {
						$configuration->supporting()->update('file', 'oops');
					};
					diag $trap->stderr() if $trap->stderr();
					like($trap->die(), qr/Cannot modify.*configuration with runs/);

					trap {
						$configuration->supporting()->delete('file');
					};
					diag $trap->stderr() if $trap->stderr();
					like($trap->die(), qr/Cannot modify.*configuration with runs/);
				};

				it 'allows changing the name' => sub {
					$configuration->name('OK');
					ok(1); # We didn't die!
				};

				it 'allows changing the comment' => sub {
					$configuration->comment('OK');
					ok(1); # We didn't die!
				};

				it 'disallows changing the parameters' => sub {
					$configuration->parameters(); # Read still mustn't die
					trap {
						$configuration->parameters([]);
					};
					diag $trap->stderr() if $trap->stderr();
					like($trap->die(), qr/Cannot modify.*configuration with runs/);
				};

				# This test resets the configuration which is NOT otherwise
				# reset at this level
				it 'allows deleting the configuration' => sub {
					$cfg_collection->delete($configuration_id);
					ok(1); # We didn't die!
					# Make $configuration_id invalid so the after subs know not
					# to clean it up.
					$configuration_id = undef;
				};
			};
		};
	};

	describe 'run' => sub {
		my $tmpdir_handle;
		my $runs;

		before 'each' => sub {
			# Create a virtual environment
			$tmpdir_handle = File::Temp->newdir(
				TEMPLATE => 'plumage-test-XXXXXXXX',
				TMPDIR => 1);
			$tmpdir = $tmpdir_handle->dirname();
			diag "Virtual environment in $tmpdir\n";

			my $configurations = Plumage::Model->new()->configurations();
			my $configuration = $configurations->configuration($configurations->create());
			$runs = $configuration->runs();
		};

		# ID listing, deletion, and generation is again covered by the
		# underlying collection, so don't need repeating here:
		#it 'gives a listing of all IDs';
		#it 'generates new IDs without re-use';
		#it 'deletes a run';
		# Run creation gets tested as a dependency of other tests

		it 'retrieves a run' => sub {
			my $id = $runs->create('nonsense', {});
			isa_ok($runs->run($id), 'Plumage::Model::Run');
		};

		it 'does not retrieve a non-existant run' => sub {
			ok(!defined $runs->run('anything'));
		};

		describe 'for a run' => sub {
			my $run_id;
			my $run;

			my $client = 'http://polyclient:5000/';
			my $client_run = 'http://polyclient:5000/runs/0';
			my $parameters = {
				proxy => '10.0.0.23',
				users => 100,
			};
			my $events = 'http://polyclient:5000/runs/0/events';

			before 'each' => sub {
				$run_id = $runs->create($client, $parameters);
				$run = $runs->run($run_id);
				$run->start($client_run, $events);
			};

			after 'each' => sub {
				$runs->delete($run_id);
			};

			it 'identifies that it is running' => sub {
				ok($run->running());
			};

			it 'retrieves a timestamp' => sub {
				# Checking the actual time is timing-sensitive; trust DateTime
				# and just see we get something UTC-timestamp-like.
				like($run->time(), qr/^\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
			};

			it 'retrieves the client used' => sub {
				is($run->client(), $client);
			};

			it 'retrieves the client-side run URI' => sub {
				is($run->client_run(), $client_run);
			};

			it 'retrieves the parameters used' => sub {
				is_deeply($run->parameters(), $parameters);
			};

			it 'retrieves the event stream URI' => sub {
				is($run->events(), $events);
			};

			describe 'with results' => sub {
				before 'each' => sub {
					# The trailing / on directories is what GNU tar does, but
					# Archive::Tar seems to strip it back off again anyway.
					# As a bonus, it seems to set 000 permissions if we don't
					# give it explicit ones.
					my $tar = Archive::Tar->new();
					$tar->add_data('plumage_run.log', 'LOG') and
					$tar->add_data('configuration/', '',
						{ type => Archive::Tar::Constant::DIR }) and
					$tar->add_data('configuration/configuration.pg', 'CONFIG') and
					$tar->add_data('client/', '',
						{ type => Archive::Tar::Constant::DIR }) and
					$tar->add_data('client/console0.log', 'CLIENT CONSOLE LOG') and
					$tar->add_data('client/binary0.log',  'CLIENT BINARY LOG') and
					$tar->add_data('server/', '',
						{ type => Archive::Tar::Constant::DIR }) and
					$tar->add_data('server/console0.log', 'SERVER CONSOLE LOG') and
					$tar->add_data('server/binary0.log',  'SERVER BINARY LOG') and
					$tar->add_data('report/', '',
						{ type => Archive::Tar::Constant::DIR }) and
					$tar->add_data('report/index.html', 'REPORT') and
					$tar->add_data('mystery.sh', 'MYSTERY')
						or die "Test suite failed to mock up data: ".$tar->error();
					my $results_tar = $tar->write();

					$run->set_results($results_tar);
				};

				after 'each' => sub {
					# Reset the run. This is a bit disgusting since we really
					# want Test::Spec to be doing the parent before/after hooks
					# for each test at this depth.
					$runs->delete($run_id);
					$run_id = $runs->create($client, $parameters);
					$run = $runs->run($run_id);
					$run->start($client_run, $events);
				};

				it 'no longer reports as running' => sub {
					ok(!$run->running());
				};

				it 'no longer returns the client-side run URI' => sub {
					ok(!defined $run->client_run());
				};

				it 'no longer returns the event stream URI' => sub {
					ok(!defined $run->events());
				};

				it 'retrieves the report base path' => sub {
					my $report_base = $run->report_dir();
					my $report = read_file("$report_base/index.html",
						{err_mode => 'carp'}); # prefer failing below to dying
					is($report, 'REPORT');
				};

				# These two peek inside implementation a bit, but it is by
				# design that if you archive the whole state tree you get the
				# raw logs amongst them for future cleverness.

				it 'archives the known files' => sub {
					my $dir = $run->{dir};
					ok(-e "$dir/plumage_run.log");
					ok(-e "$dir/configuration/configuration.pg");
					ok(-e "$dir/client/console0.log");
					ok(-e "$dir/client/binary0.log");
					ok(-e "$dir/server/console0.log");
					ok(-e "$dir/server/binary0.log");
				};

				it 'does not archive unknown files' => sub {
					my $dir = $run->{dir};
					ok(! -e "$dir/mystery.sh");
				};
			};
		};
	};

	it 'returns base client URIs' => sub {
		# See the configuration mock just before the tests for this data
		cmp_bag([Plumage::Model->new()->clients()], [qw(
			http://polyclient:5000/
			http://polyclient2:5000/
		)]);
	};
};

runtests unless caller;

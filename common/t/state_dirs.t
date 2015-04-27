#!/usr/bin/perl
# Copyright 2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

use Test::Spec;
use Test::MockModule;

use Plumage::Common;

describe 'Plumage common routines for state handling' => sub {
	describe 'when generating new state' => sub {
		my $io_dir;
		my $common;
		my @existing_dirs;
		my @created_dirs;

		before 'all' => sub {
			$io_dir = Test::MockModule->new('IO::Dir');
			$io_dir->mock('read', sub { @existing_dirs; });
			# Note we don't mock its c'tor, so it opens the real /tmp

			$common = Test::MockModule->new('Plumage::Common');
			$common->mock('_mkdir', sub { push @created_dirs, $_[0]; });
		};

		before 'each' => sub {
			@created_dirs = qw();
		};

		it 'should conjure unique IDs and directories' => sub {
			@existing_dirs = qw();
			my ($id, $runstatedir) = Plumage::Common::make_state_subdirectory('/tmp/');
			# This is a little naughty as we assume the ID is the subdirectory
			# name rather than try to rip it back out of runstatedir
			@existing_dirs = ($id);
			my ($id2, $runstatedir2) = Plumage::Common::make_state_subdirectory('/tmp/');

			ok($id ne $id2)
				or diag("ID '$id' duplicated");
			ok($runstatedir ne $runstatedir2)
				or diag("directory '$runstatedir' duplicated");

			# Check it's created the directories we expect, which partially
			# undermines the above's ID-format-agnosticism, but at least
			# catches if they're not within our top-level state directory
			cmp_bag(\@created_dirs, ['/tmp//0', '/tmp//1']);
		};

		it 'should skip holes in IDs' => sub {
			@existing_dirs = qw(1 3);
			my ($id, $runstatedir) = Plumage::Common::make_state_subdirectory('/tmp/');
			is($id, 4);
		};
	};

	describe 'when dealing with alleged existing state' => sub {
		it 'should represent existing state' => sub {
			my $common = Test::MockModule->new('Plumage::Common');
			$common->mock('_is_dir', sub { 1; });

			my $run = Plumage::Common::find_state_subdirectory('/notexist/', '1');
			ok(defined $run);
			is($run, '/notexist//1');
		};

		it 'should refuse to represent state which does not exist' => sub {
			my $common = Test::MockModule->new('Plumage::Common');
			$common->mock('_is_dir', sub { 0; });

			# An ID which is sane but absent
			ok(!(defined Plumage::Common::find_state_subdirectory('/notexist/', '99')));
		};

		it 'should refuse IDs which are not simply numeric' => sub {
			# This mock is not strictly needed for black-box testing, but
			# ensures that it is a failure to get as far as filesystem
			# operations.
			my $common = Test::MockModule->new('Plumage::Common');
			$common->mock('_is_dir', sub { die "should not have got this far!"; });

			# An ID which is trying to bust out of the state directory.
			# This does exist as a path, so should not hit the above case and
			# pass by that even if the ID validation is broken and accepts it.
			# (The mock above would also throw an exception.)
			ok(!(defined Plumage::Common::find_state_subdirectory('/tmp/', '..')));
		};
	};

	describe 'when writing Polygraph configuration' => sub {
		my $file_slurp;
		my %files_written;

		before 'all' => sub {
			$file_slurp = Test::MockModule->new('File::Slurp');
			$file_slurp->mock('write_file', sub {
				my ($file, $content, @ignored) = @_;
				die "Overwriting file '$file'" if exists $files_written{$file};
				$files_written{$file} = $content;
			});
		};

		before 'each' => sub {
			%files_written = qw();
		};

		it 'should write the main config' => sub {
			Plumage::Common::write_polygraph_configuration('/notexist/', 'CONFIG', {});
			is($files_written{'/notexist//configuration.pg'} // '', 'CONFIG');
		};

		it 'should write and record supporting files' => sub {
			Plumage::Common::write_polygraph_configuration('/notexist/', 'CONFIG', {
				'one.pgd' => '1',
				'two.pem' => '2',
			});

			# The ordering is not guaranteed, but we can't really splice a
			# cmp_bag into this is_deeply, so accept an alternate ordering by
			# telling lies about what was written in one special case.
			if($files_written{'/notexist//.supporting.log'}
				eq "two.pem\0one.pgd") {

				$files_written{'/notexist//.supporting.log'}
					= "one.pgd\0two.pem";
			}

			is_deeply(\%files_written, {
				'/notexist//configuration.pg' => 'CONFIG',
				'/notexist//one.pgd' => '1',
				'/notexist//two.pem' => '2',
				'/notexist//.supporting.log' => "one.pgd\0two.pem",
			});
		};

		it 'should refuse conflicting or unsafe supporting files' => sub {
			my %bad_files = (
				'configuration.pg' => qr/configuration cannot be a supporting file/,
				'path/components'  => qr/contains path components/,
				'.hidden'          => qr/is hidden/,
				'..'               => qr/is hidden/,
				'naughty.pid'      => qr/may conflict with runtime files/,
				'client0.log'      => qr/may conflict with runtime files/,
			);

			foreach my $bad_file (keys %bad_files) {
				# Need to redo the 'before each' for overwrite bug detection
				%files_written = qw();

				trap {
					Plumage::Common::write_polygraph_configuration('/notexist/', 'CONFIG', {
						$bad_file => 'uh-oh',
					});
				};
				diag $trap->stderr() if $trap->stderr();
				like($trap->die(), $bad_files{$bad_file});
			}
		};

		# Duplicate files are not possible to express via the API due to being
		# passed as hash keys.
	};

	describe 'when deleting Polygraph configuration' => sub {
		my $file_slurp;
		my $common;
		my @unlinked;
		my $supporting_log;

		before 'all' => sub {
			$file_slurp = Test::MockModule->new('File::Slurp');
			$file_slurp->mock('read_file', sub {
				my ($file, @ignored) = @_;
				die "Unexpected read of '$file'"
					unless $file eq '/notexist//.supporting.log';
				die 'Supporting log was deleted before read'
					unless defined $supporting_log;
				return $supporting_log;
			});

			$common = Test::MockModule->new('Plumage::Common');
			$common->mock('_unlink', sub {
				my ($file) = @_;
				# Detect bugs where we delete the log before reading it
				if($file eq '/notexist//.supporting.log')
					{ $supporting_log = undef; }

				push @unlinked, $file;
			});
		};

		before 'each' => sub {
			@unlinked = qw();
			$supporting_log = '';
		};

		it 'should remove the main config and supporting file list' => sub {
			Plumage::Common::delete_polygraph_configuration('/notexist/');
			cmp_bag(\@unlinked, [qw(
				/notexist//configuration.pg
				/notexist//.supporting.log
			)]);
		};

		it 'should remove supporting files' => sub {
			$supporting_log = "one.ahahah\0TWO.ahahah";

			Plumage::Common::delete_polygraph_configuration('/notexist/');
			cmp_bag(\@unlinked, [qw(
				/notexist//configuration.pg
				/notexist//one.ahahah
				/notexist//TWO.ahahah
				/notexist//.supporting.log
			)]);
		};

		it 'should not be possible to trick it into removing files outside the configuration' => sub {
			$supporting_log = "/stilldoesntexist";

			trap {
				Plumage::Common::delete_polygraph_configuration('/notexist/');
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/contains forbidden filenames/);
		};

		it 'should not be possible to trick it into unlinking current/parent directory' => sub {
			$supporting_log = "..";

			trap {
				Plumage::Common::delete_polygraph_configuration('/notexist/');
			};
			diag $trap->stderr() if $trap->stderr();
			like($trap->die(), qr/contains forbidden filenames/);
		};
	};
};

runtests unless caller;

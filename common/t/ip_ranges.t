#!/usr/bin/perl
# Copyright 2014-2015 Philip Boulain <philip.boulain@smoothwall.net>
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License v3 or later.
# See LICENSE.txt for details.
use warnings;
use strict;

use Test::Spec;

use Plumage::Common;

describe 'Plumage common routines' => sub {
	it 'should calculate address ranges for partitioning' => sub {
		my @ranges;
		@ranges = Plumage::Common::ip_ranges('10.0.132', 2, 65, 1);
		is_deeply([qw(
			10.0.132.2-65
			)], \@ranges);

		@ranges = Plumage::Common::ip_ranges('10.0.132', 2, 65, 4);
		is_deeply([qw(
			10.0.132.2-17
			10.0.132.18-33
			10.0.132.34-49
			10.0.132.50-65
			)], \@ranges); # Size 16

		@ranges = Plumage::Common::ip_ranges('10.0.132', 2, 65, 8);
		is_deeply([qw(
			10.0.132.2-9
			10.0.132.10-17
			10.0.132.18-25
			10.0.132.26-33
			10.0.132.34-41
			10.0.132.42-49
			10.0.132.50-57
			10.0.132.58-65
			)], \@ranges); # Size 8

		@ranges = Plumage::Common::ip_ranges('10.0.132', 2, 4, 32);
		is_deeply([qw(
			10.0.132.2-2
			10.0.132.3-3
			10.0.132.4-4
			)], \@ranges); # Don't spin up servers without addresses

		@ranges = Plumage::Common::ip_ranges('10.0.132', 2, 254, 3);
		is_deeply([qw(
			10.0.132.2-86
			10.0.132.87-170
			10.0.132.171-254
			)], \@ranges); # Sizes of 85 + 84 + 84 = 253 (2--254 inclusive)
	};
};

runtests unless caller;

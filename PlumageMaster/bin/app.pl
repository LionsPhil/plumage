#!/usr/bin/env perl
# Entry point/harness for Plumage master
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use PlumageMaster;
PlumageMaster->dance;

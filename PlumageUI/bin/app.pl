#!/usr/bin/env perl
# Entry point/harness for Plumage UI
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use PlumageUI;
PlumageUI->dance;

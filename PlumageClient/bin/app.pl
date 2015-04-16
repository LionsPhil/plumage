#!/usr/bin/env perl
# Entry point/harness for Plumage client
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use PlumageClient;
PlumageClient->dance;

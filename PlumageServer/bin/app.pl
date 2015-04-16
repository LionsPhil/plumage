#!/usr/bin/env perl
# Entry point/harness for Plumage server
use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use PlumageServer;
PlumageServer->dance;

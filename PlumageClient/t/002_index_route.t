use Test::More tests => 1;
use strict;
use warnings;

# the order is important
use PlumageClient;
use Dancer2::Test apps => ['PlumageClient'];

# Most routes are not tested because they are thin wrappers over the tested library

# This test appears to fail to detect the route since it doesn't return 200(!)
#route_exists [GET => '/'], 'a route handler is defined for /';
response_status_is ['GET' => '/'], 302, 'response status is 302 for /';

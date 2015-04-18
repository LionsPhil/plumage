use Test::More tests => 1;
use strict;
use warnings;

# the order is important
use PlumageMaster;
use Dancer2::Test apps => ['PlumageMaster'];

# This test appears to fail to detect the route since it doesn't return 200(!)
#route_exists [GET => '/'], 'a route handler is defined for /';
response_status_is ['GET' => '/'], 302, 'response status is 302 for /';

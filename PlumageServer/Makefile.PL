use strict;
use warnings;
use ExtUtils::MakeMaker;

# Normalize version strings like 6.30_02 to 6.3002,
# so that we can do numerical comparisons on it.
my $eumm_version = $ExtUtils::MakeMaker::VERSION;
$eumm_version =~ s/_//;

WriteMakefile(
    NAME                => 'PlumageServer',
    AUTHOR              => q{Philip Boulain <philip.boulain@smoothwall.net>},
    VERSION_FROM        => 'lib/PlumageServer.pm',
    ABSTRACT            => 'Server REST API for Plumage Polygraph Frontend',
    ($eumm_version >= 6.3001
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
        'YAML'       => 0,
        'Dancer2'    => 0.11,
        'Pod::Xhtml' => 1.60,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'PlumageServer-*' },
);

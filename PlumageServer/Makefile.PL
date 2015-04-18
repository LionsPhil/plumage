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
      ? ('LICENSE'=> 'agpl_3')
      : ()),
    PL_FILES            => {},
    MIN_PERL_VERSION    => '5.18.2',
    PREREQ_PM => {
        'Dancer2'               => 0.11,
        'File::Slurp'           => 9999.19,
        'IO::Scalar'            => 2.110,
        'IPC::Run'              => 0.92,
        'JSON'                  => 2.61,
        'Pod::Xhtml'            => 1.60,
        'Sys::CPU'              => 0.61,
        'Template'              => 2.24,
        'YAML'                  => 0.84,
    },
    TEST_REQUIRES       => {
        'Test::MockModule' => 0.05,
        'Test::Spec'       => 0.47,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'PlumageServer-*' },
);

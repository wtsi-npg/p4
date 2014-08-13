use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
  'build_requires' => {
    'File::Slurp'           => 0,
    'JSON'                  => 0,
    'POSIX'                 => 0,
    'File::Temp'            => 0,
    'Getopt::Std'           => 0,
    'Readonly'              => 0,
    'Carp'                  => 0,
    'Data::Dumper'          => 0,
    'ExtUtils::CBuilder'    => 0
  }
);

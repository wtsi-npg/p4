use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
  'requires' => {
    'File::Slurp'           => 0,
    'JSON'                  => 0,
    'POSIX'                 => 0,
    'File::Temp'            => 0,
    'Getopt::Std'           => 0,
    'Readonly'              => 0,
    'Carp'                  => 0,
    'Data::Dumper'          => 0
  },
  'build_requires' => {
    'ExtUtils::CBuilder'    => 0
  }
);

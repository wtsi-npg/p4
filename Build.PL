use strict;
use warnings;
use Module::Build;

my $class = Module::Build->subclass(code => <<'EOF');

  sub git_tag {
    my $gitver = q[git describe --dirty --always];
    my $version = `$gitver` || 'unknown';
    $version =~ s/\s$//smxg;
    $version=~s/\A(?![\d])/0.0-/smx; #prepend 0.0- if does not start with a number
    return $version;
  }

  sub ACTION_code {
    my $self = shift;

    $self->SUPER::ACTION_code;

    my $gitver = $self->git_tag();
    my @files = split q[\n], `find blib/lib -type f -name "*.pm"`;
    if (-d 'blib/script') {
      push @files, split q[\n],  `find blib/script -type f`;
    }
    foreach my $file (@files) {
      warn "Changing version of $file to $gitver\n";
      my $backup = '.original';
      local $^I = $backup;
      local @ARGV = ($file);
      while (<>) {
        s/(\$VERSION\s*=\s*)('?\S+'?)\s*;/${1}'$gitver';/;
        print;
      }
      unlink "$file$backup";
    }
    return;
  }
EOF

my $builder = $class->new(

  'module_name'        => 'p4',
  'dist_author'        => q(npg <npg@sanger.ac.uk>),
  'dist_version'       => $class->git_tag(),
  'dist_abstract'      => 'Process and Pipe Pipeline Panacea',
  'license'            => 'gpl',

  'configure_requires' => {
    'ExtUtils::CBuilder'    => 0
  },

  'requires' => {
    'Carp'                  => 0,
    'Cwd'                   => 0,
    'Data::Dumper'          => 0,
    'File::Slurp'           => 0,
    'File::Temp'            => 0,
    'File::Which'           => 0,
    'Getopt::Long'          => 0,
    'Getopt::Std'           => 0,
    'JSON'                  => 0,
    'List::MoreUtils'       => 0,
    'POSIX'                 => 0,
    'Readonly'              => 0
  },

  'build_requires' => {
    'ExtUtils::CBuilder'    => 0
  },

  'dist' => { COMPRESS => 'gzip', SUFFIX => 'gz', }
);

$builder->create_build_script();

1;

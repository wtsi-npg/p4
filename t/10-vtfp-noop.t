use strict;
use warnings;
use Test::More tests => 1;
use File::Slurp;
use Perl6::Slurp;
use JSON;

my $template = q[t/data/10-vtfp-noop.json];

{
# the template contains nodes and edges with no parameters. This test should confirm that vtfp.pl has no effect on them.

my $fc = from_json(read_file($template));
my $expected->{version} = q/1.0/;
$expected->{nodes} = $fc->{nodes};
$expected->{edges} = $fc->{edges};
my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 --no-absolute_program_paths $template |");
is_deeply ($vtfp_results, $expected, 'noop test');
}


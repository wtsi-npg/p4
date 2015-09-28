use strict;
use warnings;
use Test::More tests => 1;
use Test::Deep;
use Perl6::Slurp;
use Data::Dumper;
use JSON;

my $template = q[t/data/10-vtfp-array_expansion.json];

{
# the template contains a set of possibly multivalued parameters p1 - p5 which should expand into a list (array ref) in the cmd attribute of its one node

my $vtfp_results = from_json(slurp "bin/vtfp.pl $template |");
my $c = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~1A~,q~1B~,q~2A~,q~3A~,q~3B~,q~3C~,q~3D~,q~4A~,q~5A~,q~5B~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'first array element expansion test');
}


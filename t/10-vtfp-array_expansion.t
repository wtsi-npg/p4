use strict;
use warnings;
use Test::More tests => 2;
use Perl6::Slurp;
use JSON;

my $template = q[t/data/10-vtfp-array_expansion.json];
my $template_v2 = q[t/data/10-vtfp-array_expansion.v2.json];
my $which_echo = `which echo`;
chomp $which_echo;

{
# the template contains a set of possibly multivalued parameters p1 - p5 which should expand into a list (array ref) in the cmd attribute of its one node

my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 $template |");
my $c = {version => q[1.0], edges=> [], nodes => [ {cmd => [qq~$which_echo~,q~1A~,q~1B~,q~2A~,q~3A~,q~3B~,q~3C~,q~3D~,q~4A~,q~5A~,q~5B~], type => q~EXEC~, id => q~n1~, }]};
is_deeply ($vtfp_results, $c, 'first array element expansion test');

$vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 $template_v2 |");
$c = {version => q[2.0], edges=> [], nodes => [ {cmd => [qq~$which_echo~,q~1A~,q~1B~,q~2A~,q~3A~,q~3B~,q~3C~,q~3D~,q~4A~,q~5A~,q~5B~], type => q~EXEC~, id => q~n1~, }]};
is_deeply ($vtfp_results, $c, 'first array element expansion test (v2)');
}


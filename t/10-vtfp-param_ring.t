use strict;
use warnings;
use Test::More tests => 3;
use Test::Deep;
use Perl6::Slurp;
use Data::Dumper;
use JSON;

my $template = q[t/data/10-vtfp-param_ring.json];

{
# the template contains a ring of parameter defaults p2->p3->p4->p5->p2. This will lead to an infinite recursion error
#  unless the default ring is broken by giving one of the parameters a value (I arbitrarily selected p3). Parameters
#  p1 - p4 will appear in the resulting cmd attribute (if they are set).

my $vtfp_results = from_json(slurp "bin/vtfp.pl -keys p3 -vals break $template |");
#print "\n\n\n", q[Dump1: ], Dumper($vtfp_results), "\n\n\n";
my $c = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~one~,q~break~,q~break~,q~break~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'first parameter ring test');
}

{
# this is a slightly more complicated version of the previous test. It sets two parameter values in the ring, and one
#  not involved the ring (p1)

my $vtfp_results = from_json(slurp "bin/vtfp.pl -keys p1,p2,p4 -vals first,second,fourth $template |");
#print "\n\n\n", q[Dump2: ], Dumper($vtfp_results), "\n\n\n";
my $c = {edges => [], nodes => [ {cmd => [q~/bin/echo~,q~first~,q~second~,q~fourth~,q~fourth~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'second parameter ring test');
}

{
# another variant of the first previous test. It nullifies the first parameter, then sets the value for p5 (in the ring,
# but not referenced directly in the node cmd) to confirm that the value propagates through the defaults to p2, p3, and p4

my $vtfp_results = from_json(slurp "bin/vtfp.pl -nullkeys p1 -keys p5 -vals fifth $template |");
#print "\n\n\n", q[Dump3: ], Dumper($vtfp_results), "\n\n\n";
my $c = {edges => [], nodes => [ {cmd => [q~/bin/echo~,q~fifth~,q~fifth~,q~fifth~], type => q~EXEC~, id => q~n1~}]};
cmp_deeply ($vtfp_results, $c, 'third parameter ring test');
}


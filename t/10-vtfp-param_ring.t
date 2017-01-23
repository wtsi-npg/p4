use strict;
use warnings;
use Test::More tests => 4;
use Test::Cmd;
use Perl6::Slurp;
use JSON;
use Cwd;

my $template = q[t/data/10-vtfp-param_ring.json];


# first, failure
# the template contains a ring of parameter defaults p2->p3->p4->p5->p2. This will lead to an infinite recursion error
#  unless the default ring is broken by giving one of the parameters a value
subtest 'irdetect' => sub {
	plan tests => 2;

	my $odir = getcwd();
	my $template_full_path = $odir . q[/] . $template;

	my $test = Test::Cmd->new( prog => $odir.'/bin/vtfp.pl', workdir => q());
	ok($test, 'made test object');
	my $test_result = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 1 $template_full_path]);
	my $exit_status = $?;
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for splice fail test (infinite recursion detected in parameter substitution)");
};

{
# Remove infinite recursion error  by giving one of the parameters a value (I arbitrarily selected p3). Parameters
#  p1 - p4 will appear in the resulting cmd attribute (if they are set).

my $vtfp_results = from_json(slurp "bin/vtfp.pl -keys p3 -vals break $template |");
my $c = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~one~,q~break~,q~break~,q~break~], type => q~EXEC~, id => q~n1~}]};
is_deeply ($vtfp_results, $c, 'first parameter ring test');
}

{
# this is a slightly more complicated version of the previous test. It sets two parameter values in the ring, and one
#  not involved the ring (p1)

my $vtfp_results = from_json(slurp "bin/vtfp.pl -keys p1,p2,p4 -vals first,second,fourth $template |");
my $c = {edges => [], nodes => [ {cmd => [q~/bin/echo~,q~first~,q~second~,q~fourth~,q~fourth~], type => q~EXEC~, id => q~n1~}]};
is_deeply ($vtfp_results, $c, 'second parameter ring test');
}

{
# another variant of the first previous test. It nullifies the first parameter, then sets the value for p5 (in the ring,
# but not referenced directly in the node cmd) to confirm that the value propagates through the defaults to p2, p3, and p4

my $vtfp_results = from_json(slurp "bin/vtfp.pl -nullkeys p1 -keys p5 -vals fifth $template |");
my $c = {edges => [], nodes => [ {cmd => [q~/bin/echo~,q~fifth~,q~fifth~,q~fifth~], type => q~EXEC~, id => q~n1~}]};
is_deeply ($vtfp_results, $c, 'third parameter ring test');
}


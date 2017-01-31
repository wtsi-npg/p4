use strict;
use warnings;
use Carp;
use Test::More tests => 2;
use Test::Cmd;
use File::Slurp;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $tdir = tempdir(CLEANUP => 1);

my $template = q[t/data/10-vtfp-array_expansion.json];

{
# the template contains a set of possibly multivalued parameters p1 - p5 which should expand into a list (array ref) in the cmd attribute of its one node

my $vtfp_results = from_json(slurp "bin/vtfp.pl $template |");
my $c = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~1A~,q~1B~,q~2A~,q~3A~,q~3B~,q~3C~,q~3D~,q~4A~,q~5A~,q~5B~], type => q~EXEC~, id => q~n1~}]};
is_deeply ($vtfp_results, $c, 'first array element expansion test');
}

# subst directive name requires evaluation (is not just a string)
subtest 'indirect_param_names' => sub {
	plan tests => 5;

	my $indirect_param_names_template = {
		description => q/indirect parameter names examples/,
		version => q/1.0/,
		nodes =>
		[
			{
				id => q/fred/,
				description => q/parameter name is the value of another parameter/,
				type => q/EXEC/,
				cmd => [
					q/echo/,
					q/fredvalue:/,
					{ subst => { subst => q/alice/ } }
				],
			},
			{
				id => q/bill/,
				description => q/parameter name is the result of a subst_constructor evaluation/,
				type => q/EXEC/,
				cmd => [
					q/echo/,
					q/billval:/,
					{ subst => { subst_constructor => { vals => [ q/b/, q/i/, q/l/, q/l/ ], postproc => { op => q/concat/, pad => q//, } } } }
				],
			},
		],
	};

	my $ipn_template = $tdir.q[/10-vtfp-indirect_param_names.json];
	my $template_contents = to_json($indirect_param_names_template);
	write_file($ipn_template, $template_contents);

	my$odir = getcwd();
	my $test = Test::Cmd->new( prog => $odir.'/bin/vtfp.pl', workdir => q());
	ok($test, 'made test object');
	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred,bill,alice -vals bloggs,bailey,fred $ipn_template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
			nodes => [
					{
						id => 'fred',
						description => 'parameter name is the value of another parameter',
						type => 'EXEC',
						cmd => [ 'echo', 'fredvalue:', 'bloggs' ],
					},
					{
						id => 'bill',
						description => 'parameter name is the result of a subst_constructor evaluation',
						type => 'EXEC',
						cmd => [ 'echo', 'billval:', 'bailey' ],
					}
			],
			edges => [],
	};

	is_deeply ($vtfp_results, $expected_result, 'vtfp results 1 comparison');

	# change parameter values
	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred,bill,alice -vals bloggs,bailey,bill $ipn_template]);
	ok($exit_status>>8 == 0, "non-zero exit for test2: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
			nodes => [
					{
						id => 'fred',
						description => 'parameter name is the value of another parameter',
						type => 'EXEC',
						cmd => [ 'echo', 'fredvalue:', 'bailey' ],
					},
					{
						id => 'bill',
						description => 'parameter name is the result of a subst_constructor evaluation',
						type => 'EXEC',
						cmd => [ 'echo', 'billval:', 'bailey' ],
					}
			],
			edges => [],
	};

	is_deeply ($vtfp_results, $expected_result, 'vtfp results 2 comparison');

};

1;

use strict;
use warnings;
use Carp;
use Test::More tests => 4;
use Test::Cmd;
use File::Slurp;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $tdir = tempdir(CLEANUP => 1);
my $odir = getcwd();
my $test = Test::Cmd->new( prog => $odir.'/bin/vtfp.pl', workdir => q());
ok($test, 'made test object');

# Test expansion of parameters, specifically cases where there are multiple instances of multi-valued parameters (arrays).
#   In the cmd attribute, the result should be an array of scalars
subtest 'flat_array_param_names' => sub {
	plan tests => 2;

	my $flat_array_param_names_template = {
		description => 'Test expansion of parameters, specifically cases where there are multiple instances of multi-valued parameters (arrays)',
		version => '1.0',
		subst_params => [
			{ id =>  'p1', subst_constructor => { vals => [ '1A', '1B' ] } },
			{ id =>  'p2', subst_constructor => { vals => [ '2A' ] } },
			{ id =>  'p3', subst_constructor => { vals => [ '3A', '3B', '3C', '3D' ] } },
			{ id =>  'p4', default => '4A'},
			{ id =>  'p5', subst_constructor => { vals => [ '5A', '5B' ] } }
		],
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', {subst => 'p1'}, {subst => 'p2'}, {subst => 'p3'}, {subst => 'p4'}, {subst => 'p5'}  ]
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-lat_array_param_names.json];
	my $template_contents = to_json($flat_array_param_names_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','1A','1B','2A','3A','3B','3C','3D','4A','5A','5B'],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'flat array param_names results comparison');
};

# subst directive name requires evaluation (is not just a string)
subtest 'indirect_param_names' => sub {
	plan tests => 4;

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

	my $template = $tdir.q[/10-vtfp-indirect_param_names.json];
	my $template_contents = to_json($indirect_param_names_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred,bill,alice -vals bloggs,bailey,fred $template]);
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
	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred,bill,alice -vals bloggs,bailey,bill $template]);
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

# entire node is subst directive
subtest 'full_node_subst' => sub {
	plan tests => 2;

	my $full_nodes_as_subst_template = {
		version => "1.0",
		description => "subst directive name requires evaluation (is not just a string)",
		subst_params => [
			{ id => "fred", default => "Bloggs" },
			{ id => "alice", default => "fred" },
			{
				id => "all_param_node0",
				default =>  {
						id => "apn0",
						type => "EXEC",
						use_STDIN => JSON::false,
						use_STDOUT => JSON::true,
						cmd => [ "echo", "subst", "from", "sp", "section" ],
				},
			},
		],
		nodes => [
			{ subst => "all_param_node0" },
			{ subst => "all_param_node1",
					ifnull =>  {
						id => "apn1",
						type => "EXEC",
						use_STDIN => JSON::false,
						use_STDOUT => JSON::true,
						cmd => [ "echo", "subst", "from", "ifnull" ],
					},
			},
		],
	};

	my $template = $tdir.q[/10-vtfp-full_nodes_as_subst_template.json];
	my $template_contents = to_json($full_nodes_as_subst_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		nodes => [
                       {
                         id => 'apn0',
                         type => 'EXEC',
                         use_STDIN => JSON::false,
                         use_STDOUT => JSON::true,
                         cmd => [
                                    'echo',
                                    'subst',
                                    'from',
                                    'sp',
                                    'section'
                                  ],
                       },
                       {
                         id => 'apn1',
                         type => 'EXEC',
                         use_STDIN => JSON::false,
                         use_STDOUT => JSON::true,
                         cmd => [
                                    'echo',
                                    'subst',
                                    'from',
                                    'ifnull'
                                  ],
                       }
                     ],
		edges => [],
        };

	is_deeply ($vtfp_results, $expected_result, 'entire node is subst directive results comparison');
};

1;

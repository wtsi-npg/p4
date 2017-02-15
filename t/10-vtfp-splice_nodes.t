use strict;
use warnings;
use Carp;
use Test::More tests => 3;
use Test::Cmd;
use File::Slurp;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $tdir = tempdir(CLEANUP => 1);
print q[tdir: ], $tdir, "\n";

my $basic_linear_template = {
		description => q[simple linear chain (stdin->stdout) of nodes],
		version => q[1.0],
		nodes =>
		[
			{
				id => q[hello],
				type => q[EXEC],
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ q/echo/, q/Hello/ ],
			},
			{
				id => q[rev],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/rev/ ]
			},
			{
				id => q[uc],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
			},
			{
				id => q[disemvowel],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tr/, q/-d/, q/[aeiouAEIOU]/ ],
			},
			{
				id => q[output],
				type => q[OUTFILE],
				name => q/tmp.xxx/,
			},
		],
		edges =>
		[
			{ id => q[e0], from => q[hello], to => q[rev] },
			{ id => q[e1], from => q[rev], to => q[uc] },
			{ id => q[e2], from => q[uc], to => q[disemvowel] },
			{ id => q[e3], from => q[disemvowel], to => q[output] }
		]
	};

my $basic_multipath_template = {
		description => q[graph with some branching],
		version => q[1.0],
		nodes =>
		[
			{
				id => q[top],
				type => q[EXEC],
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => q/echo "Start" | tee __ALT_OUT__/,
			},
			{
				id => q[nodeA],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedA\\n/#, ]
			},
			{
				id => q[nodeB],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedB\\n/#, ]
			},
			{
				id => q[tee2],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tee/, q/__RIGHT2_OUT__/ ]
			},
			{
				id => q[tee3],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tee/, q/__RIGHT3_OUT__/, q/__MID3_OUT__/ ]
			},
			{
				id => q[Aleft],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ left\\n/# ],
			},
			{
				id => q[Aright],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ right\\n/# ],
			},
			{
				id => q[Bleft],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ left\\n/# ],
			},
			{
				id => q[Bmid],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ mid\\n/# ],
			},
			{
				id => q[Bright],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ right\\n/# ],
			},
		],
		edges =>
		[
			{ id => q[e0], from => q[top], to => q[nodeA] },
			{ id => q[e1], from => q[top:__ALT_OUT__], to => q[nodeB] },
			{ id => q[e2], from => q[nodeA], to => q[tee2] },
			{ id => q[e3], from => q[nodeB], to => q[tee3] },
			{ id => q[e4], from => q[tee2], to => q[Aleft] },
			{ id => q[e5], from => q[tee2:__RIGHT2_OUT__], to => q[Aright] },
			{ id => q[e6], from => q[tee3], to => q[Bleft] },
			{ id => q[e7], from => q[tee3:__MID3_OUT__], to => q[Bmid] },
			{ id => q[e8], from => q[tee3:__RIGHT3_OUT__], to => q[Bright] },
		]
	};

# just export and reimport parameter values for a template
subtest 'spl0' => sub {
	plan tests => 2;

	my $template = $tdir.q[/10-vtfp-splice_nodes_00.json];
	my $template_contents = to_json($basic_linear_template);
	write_file($template, $template_contents);

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -splice_nodes rev $template |");
	my $expected = { nodes =>
			[
				{
					id => q[hello],
					type => q[EXEC],
					use_STDIN => JSON::false,
					use_STDOUT => JSON::true,
					cmd => [ q/echo/, q/Hello/ ],
				},
				{
					id => q[uc],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
				},
				{
					id => q[disemvowel],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/-d/, q/[aeiouAEIOU]/ ],
				},
				{
					id => q[output],
					type => q[OUTFILE],
					name => q/tmp.xxx/,
				},
			],
			edges =>
			[
				{ id => q/e2/, from => q/uc/, to => q/disemvowel/ },
				{ id => q/e3/, from => q/disemvowel/, to => q/output/ },
				{ id => q/hello_to_uc/, from => q/hello/, to => q/uc/ },
			]
		};

	is_deeply ($vtfp_results, $expected, '(spl0) one node in a chain spliced out');

	$vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -splice_nodes \'uc-\' $template |");
	$expected = { nodes =>
			[
				{
					id => q[hello],
					type => q[EXEC],
					use_STDIN => JSON::false,
					use_STDOUT => JSON::true,
					cmd => [ q/echo/, q/Hello/ ],
				},
				{
					id => q[rev],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/rev/ ],
				},
				{
					id => q[STDOUT_00000],
					name => q[/dev/stdout],
					type => q[OUTFILE],
				},
			],
			edges =>
			[
				{ id => q/e0/, from => q/hello/, to => q/rev/ },
				{ id => q/rev_to_STDOUT/, from => q/rev/, to => q/STDOUT_00000/ },
			]
		};

	is_deeply ($vtfp_results, $expected, '(spl0) remove last two nodes in the chain');

};

# wildcard tests
subtest 'spl1' => sub {
	plan tests => 4;

	my $template = $tdir.q[/10-vtfp-splice_nodes_01.json];
	my $template_contents = to_json($basic_linear_template);
	write_file($template, $template_contents);

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -splice_nodes \'.*[rs]e.*\' $template |");
	my $expected = {
			nodes =>
			[
				{
					id => q[hello],
					type => q[EXEC],
					use_STDIN => JSON::false,
					use_STDOUT => JSON::true,
					cmd => [ q/echo/, q/Hello/ ],
				},
				{
					id => q[uc],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
				},
				{
					id => q[output],
					type => q[OUTFILE],
					name => q/tmp.xxx/,
				},
			],
			edges =>
			[
				{ id => q/hello_to_uc/, from => q/hello/, to => q/uc/ },
				{ id => q/uc_to_output/, from => q/uc/, to => q/output/ },
			]
		};

	is_deeply ($vtfp_results, $expected, '(spl1) spliced out nodes selected with wildcard');

	$vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -prune_nodes \'disemv.*-\' $template |");
	$expected = {
			nodes =>
			[
				{
					id => q[hello],
					type => q[EXEC],
					use_STDIN => JSON::false,
					use_STDOUT => JSON::true,
					cmd => [ q/echo/, q/Hello/ ],
				},
				{
					id => q[rev],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/rev/ ]
				},
				{
					id => q[uc],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::false,
					cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
				}
			],
			edges =>
			[
				{ id => q[e0], from => q[hello], to => q[rev] },
				{ id => q[e1], from => q[rev], to => q[uc] }
			]
		};

	is_deeply ($vtfp_results, $expected, '(spl1) prune two (non-sequential) nodes using wildcard');

	$template = $tdir.q[/10-vtfp-splice_nodes_01a.json];
	$template_contents = to_json($basic_multipath_template);
	write_file($template, $template_contents);

	$vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -prune_nodes \'tee2-;tee3-\' $template |");
	$expected = {
		nodes =>
		[
			{
				id => q[top],
				type => q[EXEC],
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => q/echo "Start" | tee __ALT_OUT__/,
			},
			{
				id => q[nodeA],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::false,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedA\\n/#, ]
			},
			{
				id => q[nodeB],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::false,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedB\\n/#, ]
			},
		],
		edges =>
		[
			{ id => q[e0], from => q[top], to => q[nodeA] },
			{ id => q[e1], from => q[top:__ALT_OUT__], to => q[nodeB] }
		]
	};

	is_deeply ($vtfp_results, $expected, '(spl1) prune ends of two branches using wildcard');

	$vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -prune_nodes \'tee.*:__RIGHT.*-\' $template |");
	$expected = {
		nodes =>
		[
			{
				id => q[top],
				type => q[EXEC],
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => q/echo "Start" | tee __ALT_OUT__/,
			},
			{
				id => q[nodeA],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedA\\n/#, ]
			},
			{
				id => q[nodeB],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ addedB\\n/#, ]
			},
			{
				id => q[tee2],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tee/, ]
			},
			{
				id => q[tee3],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/tee/, q/__MID3_OUT__/ ]
			},
			{
				id => q[Aleft],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ left\\n/# ],
			},
			{
				id => q[Bleft],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ left\\n/# ],
			},
			{
				id => q[Bmid],
				type => q[EXEC],
				use_STDIN => JSON::true,
				use_STDOUT => JSON::true,
				cmd => [ q/sed/, q/-e/, q#s/$/ mid\\n/# ],
			},
		],
		edges =>
		[
			{ id => q[e0], from => q[top], to => q[nodeA] },
			{ id => q[e1], from => q[top:__ALT_OUT__], to => q[nodeB] },
			{ id => q[e2], from => q[nodeA], to => q[tee2] },
			{ id => q[e3], from => q[nodeB], to => q[tee3] },
			{ id => q[e4], from => q[tee2], to => q[Aleft] },
			{ id => q[e6], from => q[tee3], to => q[Bleft] },
			{ id => q[e7], from => q[tee3:__MID3_OUT__], to => q[Bmid] },
		]
	};

	is_deeply ($vtfp_results, $expected, '(spl1) prune ends of two branches using wildcard');
};

# exec failures
subtest 'spl2' => sub {
	plan tests => 2;

	my $template = $tdir.q[/10-vtfp-splice_nodes_02.json];
	my $template_contents = to_json($basic_linear_template);
	write_file($template, $template_contents);

	my$odir = getcwd();
	my $test = Test::Cmd->new( prog => $odir.'/bin/vtfp.pl', workdir => q());
	ok($test, 'made test object');
	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -splice_nodes \'rev;uc\' $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for splice fail test (two sequential nodes without port spec)");
};

1;

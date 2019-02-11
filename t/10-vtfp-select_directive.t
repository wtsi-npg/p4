use strict;
use warnings;
use Carp;
use Test::More tests => 7;
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

# simple test of select directive (cases array)
subtest 'select_directive_array' => sub {
	plan tests => 8;

	my $select_cmd_template = {
		description => 'Test select option, allowing default them explicitly setting the select value',
		version => '1.0',
		subst_params => [
			{ id =>  'happy', default => 0 },
		],
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => {
					select => "happy",
					cases =>
						[
							[ 'echo', "bleh" ],
							[ 'echo', "woohoo" ],
						],
				}
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_0_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','bleh',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'allow select value to default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys happy -vals 1 -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','woohoo',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'set select value to non-default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys happy -vals 0 -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','bleh',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'explicit setting of select value to default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys happy -vals 16 -verbosity_level 0 $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for select with cases array - index out of bounds");

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys happy -vals '-1' -verbosity_level 0 $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for select with cases array - negative index");
};

# simple test of select directive (cases hash)
subtest 'select_directive_hash' => sub {
	plan tests => 9;

	my $select_cmd_template = {
		description => 'Test select option, allowing default them explicitly setting the select value',
		version => '1.0',
		subst_params => [
			{ id =>  'mood', default => 'indifferent' },
		],
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => {
					select => "mood",
					cases =>
						{
							sad => [ 'echo', "whinge" ],
							happy => [ 'echo', "woohoo" ],
							indifferent => [ 'echo', "meh" ]
						},
				}
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_1_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','meh',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'allow select value to default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mood -vals happy -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','woohoo',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'set select value to non-default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mood -vals indifferent -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','meh',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'explicit setting of select value to default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mood -vals sad -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo','whinge',],
			}
		],
		edges=> [],
	};

	is_deeply ($vtfp_results, $expected_result, 'another non-default setting of select value');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mood -vals ecstatic -verbosity_level 0 $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for select with cases hash - index key not present in cases");
};

# single switch change batch of values
subtest 'select_directive_single_switch_batch_values' => sub {
	plan tests => 8;

	my $select_cmd_template = {
		version => "1.0",
		description => "batch of values assigned using one select value",
		subst_params => [
			{
				select => "mslang", default => "eng",
				cases => {
					eng =>  [
						{ id => "valA", default => "one" },
						{ id => "valB", default => "two" },
						{ id => "valC", default => "three" }
					],
					deu =>  [
						{ id => "valA", default => "eins" },
						{ id => "valB", default => "zwei" },
						{ id => "valC", default => "drei" }
					],
					spa =>  [
						{ id => "valA", default => "uno" },
						{ id => "valB", default => "dos" },
						{ id => "valC", default => "tres" }
					]
				}
			}
		],
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valA", ifnull => "one"} ]
			},
			{
				id => "B",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valB", ifnull => "two"} ]
			},
			{
				id => "C",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valC", ifnull => "three"} ]
			},
			{
				id => "P",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => ["paste", "__A_IN__", "__B_IN__", "__C_IN__" ]
			}
		],
		edges => [
			{ id => "AP", from => "A", to => "P:__A_IN__" },
			{ id => "BP", from => "B", to => "P:__B_IN__" },
			{ id => "CP", from => "C", to => "P:__C_IN__" }
		]
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_2_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "one" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
			{
				use_STDIN =>  JSON::false,
				cmd =>  [ "echo", "two" ],
				id =>  "B",
				type =>  "EXEC",
				use_STDOUT =>  JSON::true
			},
			{
				id =>  "C",
				cmd =>  [ "echo", "three" ],
				use_STDIN =>  JSON::false,
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			},
			{
				id =>  "P",
				use_STDIN =>  JSON::false,
				cmd =>  [ "paste", "__A_IN__", "__B_IN__", "__C_IN__" ],
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			}
		],
		edges =>  [
			{ from =>  "A", to =>  "P:__A_IN__", id =>  "AP" },
			{ from =>  "B", id =>  "BP", to =>  "P:__B_IN__" },
			{ from =>  "C", id =>  "CP", to =>  "P:__C_IN__" }
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'single switch/batch of values with default');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mslang -vals deu -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "eins" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
			{
				use_STDIN =>  JSON::false,
				cmd =>  [ "echo", "zwei" ],
				id =>  "B",
				type =>  "EXEC",
				use_STDOUT =>  JSON::true
			},
			{
				id =>  "C",
				cmd =>  [ "echo", "drei" ],
				use_STDIN =>  JSON::false,
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			},
			{
				id =>  "P",
				use_STDIN =>  JSON::false,
				cmd =>  [ "paste", "__A_IN__", "__B_IN__", "__C_IN__" ],
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			}
		],
		edges =>  [
			{ from =>  "A", to =>  "P:__A_IN__", id =>  "AP" },
			{ from =>  "B", id =>  "BP", to =>  "P:__B_IN__" },
			{ from =>  "C", id =>  "CP", to =>  "P:__C_IN__" }
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'single switch changes batch of values, select deu');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys mslang -vals spa -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "uno" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
			{
				use_STDIN =>  JSON::false,
				cmd =>  [ "echo", "dos" ],
				id =>  "B",
				type =>  "EXEC",
				use_STDOUT =>  JSON::true
			},
			{
				id =>  "C",
				cmd =>  [ "echo", "tres" ],
				use_STDIN =>  JSON::false,
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			},
			{
				id =>  "P",
				use_STDIN =>  JSON::false,
				cmd =>  [ "paste", "__A_IN__", "__B_IN__", "__C_IN__" ],
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			}
		],
		edges =>  [
			{ from =>  "A", to =>  "P:__A_IN__", id =>  "AP" },
			{ from =>  "B", id =>  "BP", to =>  "P:__B_IN__" },
			{ from =>  "C", id =>  "CP", to =>  "P:__C_IN__" }
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'single switch/batch of values, select spa');

	# same basic template as above, but without a default value for the select
	$select_cmd_template = {
		version => "1.0",
		description => "batch of values assigned using one select value (no default)",
		subst_params => [
			{
				select => "mslang",
				cases => {
					eng =>  [
						{ id => "valA", default => "one" },
						{ id => "valB", default => "two" },
						{ id => "valC", default => "three" }
					],
					deu =>  [
						{ id => "valA", default => "eins" },
						{ id => "valB", default => "zwei" },
						{ id => "valC", default => "drei" }
					],
					spa =>  [
						{ id => "valA", default => "uno" },
						{ id => "valB", default => "dos" },
						{ id => "valC", default => "tres" }
					]
				}
			}
		],
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valA", ifnull => "unspec"} ]
			},
			{
				id => "B",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valB", ifnull => "unspec"} ]
			},
			{
				id => "C",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {subst => "valC", ifnull => "unspec"} ]
			},
			{
				id => "P",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => ["paste", "__A_IN__", "__B_IN__", "__C_IN__" ]
			}
		],
		edges => [
			{ id => "AP", from => "A", to => "P:__A_IN__" },
			{ id => "BP", from => "B", to => "P:__B_IN__" },
			{ id => "CP", from => "C", to => "P:__C_IN__" }
		]
	};

	$template = $tdir.q[/10-vtfp-select_cmd_2_1.json];
	$template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "unspec" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
			{
				use_STDIN =>  JSON::false,
				cmd =>  [ "echo", "unspec" ],
				id =>  "B",
				type =>  "EXEC",
				use_STDOUT =>  JSON::true
			},
			{
				id =>  "C",
				cmd =>  [ "echo", "unspec" ],
				use_STDIN =>  JSON::false,
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			},
			{
				id =>  "P",
				use_STDIN =>  JSON::false,
				cmd =>  [ "paste", "__A_IN__", "__B_IN__", "__C_IN__" ],
				use_STDOUT =>  JSON::true,
				type =>  "EXEC"
			}
		],
		edges =>  [
			{ from =>  "A", to =>  "P:__A_IN__", id =>  "AP" },
			{ from =>  "B", id =>  "BP", to =>  "P:__B_IN__" },
			{ from =>  "C", id =>  "CP", to =>  "P:__C_IN__" }
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'single switch/batch of values without default');
};

# multisel 
subtest 'select_directive_multi_sel' => sub {
	plan tests => 16;

	my $select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (array)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", cases => [ "one", "two", "three", "four" ]} ]
			},
		],
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_3_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel,wordsel -vals 1,3 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "two", "four" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select multiple values from cases (array)');

	$select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (hash)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", cases => { first => "one", second => "two", third => "three", fourth => "four" }} ]
			},
		],
	};

	$template = $tdir.q[/10-vtfp-select_cmd_3_1.json];
	$template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel,wordsel -vals second,fourth $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "two", "four" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select multiple values from cases (hash)');

	$select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (array)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", "select_range" => [2,3], cases => [ "one", "two", "three", "four" ]} ]
			},
		],
	};

	$template = $tdir.q[/10-vtfp-select_cmd_3_2.json];
	$template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel -vals 1 $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for select with select range - too few index keys (only 1, must be between 2 and 3)");

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel,wordsel -vals 1,2 $template]);
	cmp_ok($exit_status>>8, q(==), 0, "expected exit status of 0 for select with select range - acceptable number of index keys (2, must be between 2 and 3)");
	$vtfp_results = from_json($test->stdout);
	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "two", "three" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'valid select with select_range (2 with 2-3)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel,wordsel,wordsel -vals 0,1,2 $template]);
	cmp_ok($exit_status>>8, q(==), 0, "expected exit status of 0 for select with select range - acceptable number of index keys (3, must be between 2 and 3)");
	$vtfp_results = from_json($test->stdout);
	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "one", "two", "three" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'valid select with select_range (3 with 2-3)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys wordsel,wordsel,wordsel,wordsel -vals 0,1,2,3 $template]);
	cmp_ok($exit_status>>8, q(==), 255, "expected exit status of 255 for select with select range - too few index keys (4, must be between 2 and 3)");

	$select_cmd_template = {
		version => "1.0",
		description => "select multiple non-unique values from cases (array)",
		subst_params => [
			{
				id => "notes",
				default => {
					select => "tune",
					cases => {
						happybirthday => [ 4, 4, 5, 4, 0, 6, 4, 4, 5, 4, 1, 0, 4, 4, 4, 2, 1, 0, 6, 2, 2, 1, 0, 1, 0 ],
						scale => [ 0, 1, 2, 3, 4, 5, 6 ]
					}
				}
			}
		],
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo",
					{ 	select => "notes",
						cases => [ "do", "re", "mi", "fa", "so", "la", "ti" ],
						default => [ 0, 2, 2, 2, 4, 4, 1, 3, 3, 5, 6, 6 ]
					}
				],
			},
		],
	};

	$template = $tdir.q[/10-vtfp-select_cmd_3_3.json];
	$template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "do", "mi", "mi", "mi", "so", "so", "re", "fa", "fa", "la", "ti", "ti" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select multiple non-unique values from cases (array)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys tune -vals happybirthday $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "so", "so", "la", "so", "do", "ti", "so", "so", "la", "so", "re", "do", "so", "so", "so", "mi", "re", "do", "ti", "mi", "mi", "re", "do", "re", "do" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select multiple non-unique values from cases (array) (hb)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys tune -vals scale $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "do", "re", "mi", "fa", "so", "la", "ti" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select multiple non-unique values from cases (array) (scale)');
};

### no_sel - explicitly switch off
subtest 'select_directive_no_sel' => sub {
	plan tests => 8;

	# with array cases
	my $select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (array)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", "default" => 3, cases => [ "one", "two", "three", "four" ]} ]
			},
		],
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_4_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "four" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select value using default from cases (array)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred -vals bloggs -nullkeys wordsel $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select no values from cases (array), overriding default with nullkeys');

	# now the same but with hash cases
	$select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (array)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", "default" => "fourth", cases => { first => "one", second => "two", third => "three", fourth => "four" }} ]
			},
		],
	};

	$template = $tdir.q[/10-vtfp-select_cmd_4_1.json];
	$template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "four" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select value using default from cases (hash)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys fred -vals bloggs -nullkeys wordsel $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select no values from cases (hash), overriding default with nullkeys');
};

### confirm distinction between 0 and undef as default value in a select directive
subtest 'select_directive_no_sel' => sub {
	plan tests => 4;

	# with array cases
	my $select_cmd_template = {
		version => "1.0",
		description => "select multiple values from cases (array)",
		nodes => [
			{
				id => "A",
				type => "EXEC",
				use_STDIN => JSON::false,
				use_STDOUT => JSON::true,
				cmd => [ "echo", {select => "wordsel", "default" => 0, cases => [ "one", "two", "three", "four" ]} ]
			},
		],
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_5_0.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo", "one" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'select value using default from cases (array)');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -nullkeys wordsel $template]);
	ok($exit_status>>8 == 0, "zero exit for test run: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		version => '1.0',
		nodes =>  [
			{
				type =>  "EXEC",
				use_STDOUT =>  JSON::true,
				cmd =>  [ "echo" ],
				use_STDIN =>  JSON::false,
				id =>  "A"
			},
		],
		edges =>  [
		],
	};

	is_deeply ($vtfp_results, $expected_result, 'forcing undef value in select directive');
};

1;

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

my $odir = getcwd();
my $test = Test::Cmd->new( prog => $odir.'/bin/vtfp.pl', workdir => q());
ok($test, 'made test object');

# simple test of select directive (cases array)
subtest 'select_directive_array' => sub {
	plan tests => 6;

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

	my $template = $tdir.q[/10-vtfp-select_cmd_.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
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
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
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
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
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
};

# simple test of select directive (cases hash)
subtest 'select_directive_hash' => sub {
	plan tests => 8;

	my $select_cmd_template = {
		description => 'Test select option, allowing default them explicitly setting the select value',
		version => '1.0',
		subst_params => [
			{ id =>  'mood', default => 'indifferent; },
		],
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => {
					select => "mood",
					cases =>
						{
							"sad": [ 'echo', "whinge" ],
							"happy": [ 'echo', "woohoo" ],
							"indifferent": [ 'echo', "meh" ]
						},
				}
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-select_cmd_.json];
	my $template_contents = to_json($select_cmd_template);
	write_file($template, $template_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
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
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
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
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
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
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
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
};

1;

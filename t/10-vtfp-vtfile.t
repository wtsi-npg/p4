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

# Test VTFILE processing by vtfp

# basic functions
subtest 'basic_checks' => sub {
	plan tests => 2;

	my $basic_container = {
		description => 'basic template containing a VTFILE node',
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', 'aeronautics']
			},
			{
				id => 'v1',
				type => 'VTFILE',
				node_prefix => 'vtf0_',
				name => "$tdir/10-vtfp-vtfile_vtf0.json"
			}
		],
		edges => [
			{ id => 'e1', from => 'n1', to => 'v1'}
		]
	};

	my $vtf0 = {
		description => 'basic VTFILE',
		version => '1.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'vowelrot',
					target_seqchksum => 'merge_output_seqchksum:__TARGET_CHKSUM_IN__',
					phix_seqchksum => 'merge_output_seqchksum:__PHIX_CHKSUM_IN__'
				}
			}
		},
		nodes => [
			{
				id => 'vowelrot',
				type => 'EXEC',
				cmd => [ 'tr', 'aeiou', 'eioua' ]
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_basic.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile = $tdir.q[/10-vtfp-vtfile_vtf0.json];
	my $vtfile_contents = to_json($vtf0);
	write_file($vtfile, $vtfile_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf0_vowelrot',
				type => 'EXEC',
				cmd => [ 'tr', 'aeiou', 'eioua' ]
			}
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf0_vowelrot'}
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'basic check');
};

subtest 'multilevel_vft' => sub {
	plan tests => 2;

	my $basic_container = {
		description => 'basic template containing a VTFILE node',
		version => '1.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', 'aeronautics']
			},
			{
				id => 'v1',
				type => 'VTFILE',
				node_prefix => 'vtf1_',
				name => { subst => 'vtfname', ifnull => "$tdir/10-vtfp-vtfile_vtf1.json" }
			}
		],
		edges => [
			{ id => 'e1', from => 'n1', to => 'v1'}
		]
	};

	my $vtf1 = {
		description => 'unary',
		version => '1.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'rev',
				}
			}
		},
		nodes => [
			{
				id => 'rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'file',
				type => 'OUTFILE',
				name => { subst_constructor => { vals => [ 'tmp.', {subst => 'ext', ifnull => 'txt', }], postproc => { op => 'concat', pad => ''} }, }
			}
		],
		edges => [
			{ id => 'e2', from => 'rev', to => 'file'}
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_multilevel0.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile = $tdir.q[/10-vtfp-vtfile_vtf1.json];
	my $vtfile_contents = to_json($vtf1);
	write_file($vtfile, $vtfile_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf1_rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'vtf1_file',
				type => 'OUTFILE',
				name => 'tmp.txt'
			}
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf1_rev'},
			{ id => 'e2', from => 'vtf1_rev', to => 'vtf1_file'}
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'flat array param_names results comparison');
};

1;

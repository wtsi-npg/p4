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

subtest 'multilevel_vtf' => sub {
	plan tests => 4;

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

	my $vtf2 = {
		description => 'binary',
		version => '1.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'tee',
				}
			}
		},
		nodes => [
			{
				id => 'tee',
				type => 'EXEC',
				cmd => [ 'tee', '__A_OUT__', '__B_OUT__' ]
			},
			{
				id => 'aout',
				type => 'VTFILE',
				name => "$tdir/10-vtfp-vtfile_vtf1.json",
				node_prefix => 'aout_',
				subst_map => { ext =>'xxx' },
			},
			{
				id => 'bout',
				type => 'VTFILE',
				name => "$tdir/10-vtfp-vtfile_vtf1.json",
				node_prefix => 'bout_',
				subst_map => { ext => 'yyy' },
			},
		],
		edges => [
			{ id => 'e3', from => 'tee:__A_OUT__', to => 'aout'},
			{ id => 'e4', from => 'tee:__B_OUT__', to => 'bout'},
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_multilevel0.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile1 = $tdir.q[/10-vtfp-vtfile_vtf1.json];
	my $vtfile_contents = to_json($vtf1);
	write_file($vtfile1, $vtfile_contents);

	my $vtfile2 = $tdir.q[/10-vtfp-vtfile_vtf2.json];
	$vtfile_contents = to_json($vtf2);
	write_file($vtfile2, $vtfile_contents);

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

	is_deeply ($vtfp_results, $expected_result, 'multilevel VTFILE nodes - first just one');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -keys vtfname -vals $vtfile2 -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	$vtfp_results = from_json($test->stdout);

	$expected_result = {
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf1_tee',
				type => 'EXEC',
				cmd => [ 'tee', '__A_OUT__', '__B_OUT__' ]
			},
			{
				id => 'aout_rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'aout_file',
				type => 'OUTFILE',
				name => 'tmp.xxx'
			},
			{
				id => 'bout_rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'bout_file',
				type => 'OUTFILE',
				name => 'tmp.yyy'
			}
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf1_tee'},
			{ id => 'e3', from => 'vtf1_tee:__A_OUT__', to => 'aout_rev'},
			{ id => 'e4', from => 'vtf1_tee:__B_OUT__', to => 'bout_rev'},
			{ id => 'e2', from => 'aout_rev', to => 'aout_file'},
			{ id => 'e2', from => 'bout_rev', to => 'bout_file'}
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'multilevel VTFILE nodes - two level (split)');
};

1;

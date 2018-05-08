use strict;
use warnings;
use Carp;
use Test::More tests => 6;
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
		version => '2.0',
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
		version => '2.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'vowelrot'
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
		version => '2.0',
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

# noop edge
subtest 'noop_edge_checks' => sub {
	plan tests => 2;

	my $basic_container = {
		description => 'basic template containing a VTFILE node',
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', 'aeronautics']
			},
			{
				id => 'v1',
				type => 'VTFILE',
				node_prefix => 'vtf00_',
				name => "$tdir/10-vtfp-vtfile_vtf00.json"
			}
		],
		edges => [
			{ id => 'e1', from => 'n1', to => 'v1'}
		]
	};

	my $vtf00 = {
		description => 'basic VTFILE',
		version => '2.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'vowelrot'
				}
			}
		},
		nodes => [
			{
				id => 'vowelrot',
				type => 'EXEC',
				cmd => [ 'tr', 'aeiou', 'eioua' ]
			}
		],
		edges => [
			{
				id => 'noop'
			}
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_basic.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile = $tdir.q[/10-vtfp-vtfile_vtf00.json];
	my $vtfile_contents = to_json($vtf00);
	write_file($vtfile, $vtfile_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for vtfp in noop edge test: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf00_vowelrot',
				type => 'EXEC',
				cmd => [ 'tr', 'aeiou', 'eioua' ]
			}
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf00_vowelrot'},
			{ id => 'noop' }
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'noop edge check');
};

subtest 'multilevel_vtf' => sub {
	plan tests => 4;

	my $basic_container = {
		description => 'basic template containing a VTFILE node',
		version => '2.0',
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
		version => '2.0',
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
		version => '2.0',
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
				cmd => [ 'tee', {'port' => 'a'} , {'port' => 'b'}, ]
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
			{ id => 'e3', from => 'tee:a', to => 'aout'},
			{ id => 'e4', from => 'tee:b', to => 'bout'},
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
		version => '2.0',
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
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf1_tee',
				type => 'EXEC',
				cmd => [ 'tee', {'port' => 'a'} , {'port' => 'b'}, ]
			},
			{
				id => 'vtf1_aout_rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'vtf1_aout_file',
				type => 'OUTFILE',
				name => 'tmp.xxx'
			},
			{
				id => 'vtf1_bout_rev',
				type => 'EXEC',
				cmd => [ 'rev' ]
			},
			{
				id => 'vtf1_bout_file',
				type => 'OUTFILE',
				name => 'tmp.yyy'
			}
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf1_tee'},
			{ id => 'e3', from => 'vtf1_tee:a', to => 'vtf1_aout_rev'},
			{ id => 'e4', from => 'vtf1_tee:b', to => 'vtf1_bout_rev'},
			{ id => 'e2', from => 'vtf1_aout_rev', to => 'vtf1_aout_file'},
			{ id => 'e2', from => 'vtf1_bout_rev', to => 'vtf1_bout_file'}
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'multilevel VTFILE nodes - two level (split)');
};

subtest 'multilevel_local_param_reeval' => sub {
	plan tests => 2;

	my $basic_container = {
		description => 'top template containing a VTFILE node',
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', 'aeronautics']
			},
			{
				id => 'v1',
				type => 'VTFILE',
				node_prefix => 'vtf11_',
				name => "$tdir/10-vtfp-vtfile_vtf11.json",
				subst_map => { component => 'xy' }
			}
		],
		edges => [
			{ id => 'e1', from => 'n1', to => 'v1'}
		]
	};

	my $vtf11 = {
		description => 'mid',
		version => '2.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'tee',
				}
			}
		},
		subst_params => [
			{ id => 'ext', subst_constructor => {vals => [ 'w', {subst => 'component'}, 'z' ], postproc => { op => 'concat', pad => ''}} }
		],
		nodes => [
			{
				id => 'tee',
				type => 'EXEC',
				cmd => [ 'tee', '__A_OUT__', '__B_OUT__' ]
			},
			{
				id => 'file',
				type => 'OUTFILE',
				name => { subst_constructor => { vals => [ 'tmp.', {subst => 'ext', ifnull => 'tat', }], postproc => { op => 'concat', pad => ''} }, }
			},
			{
				id => 'vfile',
				type => 'VTFILE',
				node_prefix => 'vtf12_',
				name => "$tdir/10-vtfp-vtfile_vtf12.json",
				subst_map => { component => 'ee' }
			},
		],
		edges => [
			{ id => 'e2', from => 'tee:__A_OUT__', to => 'file'},
			{ id => 'e3', from => 'tee:__B_OUT__', to => 'vfile'},
		]
	};

	my $vtf12 = {
		description => 'bottom',
		comment => 'the value of param ext should not be inherited from the cache of the parent, since the passed component value should force local reevaluation',
		version => '2.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'vfile',
				}
			}
		},
		nodes => [
			{
				id => 'vfile',
				type => 'OUTFILE',
				name => { subst_constructor => { vals => [ 'tmp.', {subst => 'ext'} ], postproc => { op => 'concat', pad => ''} }, }
			},
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_multilevel1.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile11 = $tdir.q[/10-vtfp-vtfile_vtf11.json];
	my $vtfile_contents = to_json($vtf11);
	write_file($vtfile11, $vtfile_contents);

	my $vtfile12 = $tdir.q[/10-vtfp-vtfile_vtf12.json];
	$vtfile_contents = to_json($vtf12);
	write_file($vtfile12, $vtfile_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 $template]);
	ok($exit_status>>8 == 0, "non-zero exit for test1: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf11_tee',
				type => 'EXEC',
				cmd => [ 'tee', '__A_OUT__', '__B_OUT__' ]
			},
			{
				id => 'vtf11_file',
				type => 'OUTFILE',
				name => 'tmp.wxyz',
			},
			{
				id => 'vtf11_vtf12_vfile',
				type => 'OUTFILE',
				name => 'tmp.weez',
			},
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf11_tee'},
			{ id => 'e2', from => 'vtf11_tee:__A_OUT__', to => 'vtf11_file'},
			{ id => 'e3', from => 'vtf11_tee:__B_OUT__', to => 'vtf11_vtf12_vfile'}
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'multilevel local param reeval');
};

subtest 'multilevel_vtf_required_param' => sub {
	plan tests => 4;

	my $basic_container = {
		description => 'top template containing a VTFILE node',
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => [ 'echo', 'aeronautics']
			},
			{
				id => 'v1',
				type => 'VTFILE',
				node_prefix => 'vtf11_',
				name => "$tdir/10-vtfp-vtfile_vtf11.json"
			}
		],
		edges => [
			{ id => 'e1', from => 'n1', to => 'v1'}
		]
	};

	my $vtf11 = {
		description => 'mid',
		version => '2.0',
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
				cmd => [ 'tee', 'left_out', 'right_out' ],
			},
			{
				id => 'lvfile',
				type => 'VTFILE',
				node_prefix => 'lvtf12_',
				name => "$tdir/10-vtfp-vtfile_vtf12.json",
				subst_map => { ext => 'xxx' },
			},
			{
				id => 'rvfile',
				type => 'VTFILE',
				node_prefix => 'rvtf12_',
				name => "$tdir/10-vtfp-vtfile_vtf12.json",
			},
		],
		edges => [
			{ id => 'e2', from => 'tee:left_out', to => 'lvfile'},
			{ id => 'e3', from => 'tee:right_out', to => 'rvfile'},
		]
	};

	my $vtf12 = {
		description => 'bottom',
		comment => 'the value of param ext should not be inherited from the cache of the parent, since the passed component value should force local reevaluation',
		version => '2.0',
		subgraph_io => {
			ports => {
				inputs => {
					_stdin_ => 'vfile',
				}
			}
		},
		nodes => [
			{
				id => 'vfile',
				type => 'OUTFILE',
				name => { subst_constructor => { vals => [ 'tmp.', {subst => 'ext', 'required' => 'true'} ], postproc => { op => 'concat', pad => ''} }, }
			},
		]
	};

	my $template = $tdir.q[/10-vtfp-vtfile_multilevel1.json];
	my $template_contents = to_json($basic_container);
	write_file($template, $template_contents);

	my $vtfile11 = $tdir.q[/10-vtfp-vtfile_vtf11.json];
	my $vtfile_contents = to_json($vtf11);
	write_file($vtfile11, $vtfile_contents);

	my $vtfile12 = $tdir.q[/10-vtfp-vtfile_vtf12.json];
	$vtfile_contents = to_json($vtf12);
	write_file($vtfile12, $vtfile_contents);

	my $exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 1 $template]);
	ok($exit_status>>8 == 255, "error exit for test multilevel_vtf_required_param: $exit_status");
	my $vtfp_err = $test->stderr;
	like ($vtfp_err, qr/No value found for required subst \(param_name: ext\)/, 'err ms check');

	$exit_status = $test->run(chdir => $test->curdir, args => qq[-no-absolute_program_paths -verbosity_level 0 -keys v1:rvfile:ext -vals yyy $template]);
	ok($exit_status>>8 == 0, "non-zero exit: $exit_status");
	my $vtfp_results = from_json($test->stdout);

	my $expected_result = {
		version => '2.0',
		nodes => [
			{
				id => 'n1',
				type => 'EXEC',
				cmd => ['echo', 'aeronautics']
			},
			{
				id => 'vtf11_tee',
				type => 'EXEC',
				cmd => [ 'tee', 'left_out', 'right_out' ]
			},
			{
				id => 'vtf11_lvtf12_vfile',
				type => 'OUTFILE',
				name => 'tmp.xxx',
			},
			{
				id => 'vtf11_rvtf12_vfile',
				type => 'OUTFILE',
				name => 'tmp.yyy',
			},
		],
		edges=> [
			{ id => 'e1', from => 'n1', to => 'vtf11_tee'},
			{ id => 'e2', from => 'vtf11_tee:left_out', to => 'vtf11_lvtf12_vfile'},
			{ id => 'e3', from => 'vtf11_tee:right_out', to => 'vtf11_rvtf12_vfile'},
		]
	};

	is_deeply ($vtfp_results, $expected_result, 'multilevel local param reeval');
};

1;

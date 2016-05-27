use strict;
use warnings;
use Carp;
use Test::More tests => 1;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);

my $tdir = tempdir(CLEANUP => 1);
my $template = q[t/data/10-vtfp-pv.json];
my $pv_file = $tdir.q[/10-vtfp-pv.pv];
my $processed_template = $tdir.q[/10-vtfp-pv-processed.json];

# just export and reimport parameter values for a template
subtest 'spl0' => sub {
	plan tests => 2;

	my $template = q[t/data/10-vtfp-splice_nodes_00.json];
	my $processed_template = $tdir.q[/10-vtfp-splice_nodes_00-processed.json];

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
					id => q[output],
					type => q[OUTFILE],
					name => q/tmp.xxx/,
				},
			],
			edges =>
			[
				{ id => q/e2/, from => q/uc/, to => q/output/ },
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

1;

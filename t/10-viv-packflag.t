use strict;
use warnings;
use Carp;
use Test::More tests => 2;
use Test::Cmd;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $tdir = tempdir(CLEANUP => 1);
my $odir=getcwd();

my $graph_file = $tdir . q[/input.json];
my $infile = q[indata.txt];
my $outfile = q[mainout.txt];

# packflag directive should resolve to a string argument for the -c flag ('3,5,7,9,10-12,17,18')
#  Note: this is a simple illustration - packflag is normally intended to pack port FIFOs into a string
#  immediately before execution
my $graph = {
	version => '2.0',
	nodes => [
		{ id => 'indata', type => 'EXEC', use_STDIN => JSON::false, use_STDOUT => JSON::true, cmd => [ "echo", "123456789ABCDEFGHIJKLMNOP", ], },
		{ id => 'cut', type => 'EXEC', use_STDIN => JSON::true, use_STDOUT => JSON::true,
			cmd => [
				"cut",
				"-c",
				{
					packflag => [
						{
							packflag => [
									"3",
									",",
									"5",
									[ ",", "7", ",", "9" ],
							],
						},
						[ ",", "10-12", ",", "17", ",", "18" ],
					],
				},
			],
		},
	],
	edges => [
		{ id => "in2cut", from => "indata", to => "cut", },
	]
};

# create test object for all subtests
my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
ok($test, 'made test object');

# create input JSON for all subtests
my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
$test->write($graph_file, $graph_json);
if($? != 0) { croak qq[Failed to create test input graph file $graph_file]; }

subtest 'test packflag directive' => sub {
    plan tests => 2;

    my $exit_status = $test->run(chdir => $test->curdir, args => "-v 0 -s -x $graph_file");
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    is($test->stdout,"3579ABCHI\n","expected final output (3579ABCHI)");
};

1;

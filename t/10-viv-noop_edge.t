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

# This should show the effect of having a "noop" edge entry (an entry without "from" and "to" attributes).
#  It should be filtered and not affect execution, an informational message should appear at appropriate 
#  verbosity levels
my $graph = {
	version => '2.0',
	nodes => [
		{ id => 'start', type => 'EXEC', use_STDIN => JSON::false, use_STDOUT => JSON::true, cmd => [ 'echo', 'Hello'], },
		{ id => 'shout', type => 'EXEC', use_STDIN => JSON::true, use_STDOUT => JSON::true, cmd => [ 'tr', '[:lower:]', '[:upper:]' ], },
	],
	edges => [
		{ id => 'e0', from => 'start', to => 'shout' },
		{ id => 'nix' }
	]
};

# create test object for all subtests
my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
ok($test, 'made test object');

subtest 'test noop_edge' => sub {
    plan tests => 3;

    local $ENV{TESTPAR} = q[TEST_VALUE];

    # create input JSON for subtest
    my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
    $test->write($graph_file, $graph_json);
    if($? != 0) { croak qq[Failed to create test input graph file $graph_file]; }

    my $exit_status = $test->run(chdir => $test->curdir, args => "-v 2 -s -x $graph_file");
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    is($test->stdout,"HELLO\n","expected final output (HELLO)");

    ok($test->stderr =~ /INFO: removing edge entry:/, "expected removing edge entry informational message");
};

1;

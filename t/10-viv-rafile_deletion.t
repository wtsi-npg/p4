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
		
		{ id => 'greet', type => 'EXEC', use_STDIN => JSON::false, use_STDOUT => JSON::true, cmd => [ 'echo', 'Hello'], },
		{ id => 'caps', type => 'EXEC', use_STDIN => JSON::true, use_STDOUT => JSON::true, cmd => [ 'tr', '[:lower:]', '[:upper:]' ], },
		{ id => 'rev', type => 'EXEC', use_STDIN => JSON::true, use_STDOUT => JSON::true, cmd => ['rev'], },
		{ id => 'tee', type => 'EXEC', use_STDIN => JSON::true, use_STDOUT => JSON::true, cmd => ['tee', {port => 'fout', direction => 'out'}], },
		{ id => 'tmpxxx', type => 'RAFILE', name => 'tmp.xxx', },
		{ id => 'tmpyyy', type => 'RAFILE', name => 'tmp.yyy', },
		{ id => 'end', type => 'OUTFILE', name => 'end.txt', }
	],
	edges => [
		{id => 'e0', from => 'greet', to => 'tmpxxx', },
		{id => 'e1', from => 'tmpxxx', to => 'caps', },
		{id => 'e2', from => 'caps', to => 'tmpyyy', },
		{id => 'e3', from => 'tmpyyy', to => 'rev', },
		{id => 'e3', from => 'rev', to => 'tee', },
		{id => 'e3', from => 'tee:fout', to => 'end', }
	]
};

# create test object for all subtests
my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
ok($test, 'made test object');

subtest 'test rafile_deletion' => sub {
    plan tests => 8;

    # create input JSON for subtest
    my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
    $test->write($graph_file, $graph_json);
    if($? != 0) { croak qq[Failed to create test input graph file $graph_file]; }

    my $exit_status = $test->run(chdir => $test->curdir, args => "-v 2 -s -x $graph_file");
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    is($test->stdout,"OLLEH\n","expected final output (OLLEH)");

    ok($test->stderr =~ /INFO: Unlinking tmp.xxx/, "expected unlinking tmp.xxx informational message");
    ok($test->stderr =~ /INFO: Unlinking tmp.yyy/, "expected unlinking tmp.yyy informational message");

    my $outfile = q/end.txt/;
    my $outdata;
    my $read_file = $test->read(\$outdata, $outfile);
    ok($read_file, "read test output: $outfile");

    is($outdata,"OLLEH\n","expected final output (OLLEH)");

    my @ra_files = (q/tmp.xxx/, q/tmp.yyy/,);
    for my $ra_file (@ra_files) {
      my $raf_fp = $test->workdir . '/' . $ra_file;
      `test ! -f $raf_fp`;
      ok($? == 0, "non-existence of intermediate file (RAFILE node) $ra_file");
    }
};

1;

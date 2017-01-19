use strict;
use warnings;
use Carp;
use Test::More tests => 4;
use Test::Cmd;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);
use Cwd;

my $odir=getcwd();

my $graph_file = q[input.json];
my $infile = q[indata.txt];
my $outfile = q[mainout.txt];

# passing a string through this graph should uppercase it, reverse it, remove the vowels and write it to an output file
my $graph = {
	nodes => [
		{ id => 'infile', type => 'INFILE', name => $infile, },
		{ id => 'cap', type => 'EXEC', cmd => [ "tr", "[:lower:]", "[:upper:]"], use_STDIN => q[JSON::XS::true], use_STDOUT => q[JSON::XS::true], },
		{ id => 'rev', type => 'EXEC', cmd => [ "rev", ], use_STDIN => q[JSON::XS::true], use_STDOUT => q[JSON::XS::true], },
		{ id => 'disemvowel', type => 'EXEC', cmd => [ "tr", "-d", "aeiouAEIOU" ],  use_STDIN => q[JSON::XS::true], use_STDOUT => q[JSON::XS::true],},
		{ id => 'outfile', type => 'OUTFILE', name => $outfile, },
	],
	edges => [
		{ id => "in2cap", from => "infile", to => "cap", },
		{ id => "cap2rev", from => "cap", to => "rev", },
		{ id => "rev2disemvowel", from => "rev", to => "disemvowel", },
		{ id => "disemvowel2outfile", from => "disemvowel", to => "outfile", },
	]
};

# create test object for all subtests
my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q());
ok($test, 'made test object');

# create input JSON for all subtests
my $graph_json = to_json($graph) or croak q[Failed to produce JSON test graph];
$test->write($graph_file, $graph_json);
if($? != 0) { croak qq[Failed to create test input graph file $graph_file]; }

subtest 'test simple graph without using -t option' => sub {
    plan tests => 3;

    # create input data file
    $test->write($infile, qq[qwertyuiop\n]);
    if($? != 0) { croak qq[Failed to create test input file $infile]; }

    my $exit_status = $test->run(chdir => $test->curdir, args => "-v 0 -s -x $graph_file");
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    my $outdata;
    my $read_file = $test->read(\$outdata, $outfile);
    ok($read_file, "read output from $outfile");

    is($outdata,"PYTRWQ\n","expected final output (PYTRWQ)");
};

subtest 'test simple graph siphoning off output from one node to a temporary file using the -t option' => sub {
    plan tests => 5;
    my $teefile1 = q[teefile1.txt];

    # create input data file
    $test->write($infile, qq[qwertyuiop\n]);
    if($? != 0) { croak qq[Failed to create test input file $infile]; }

    my $exit_status = $test->run(chdir => $test->curdir, args => "-v 0 -t cap=$teefile1 -s -x $graph_file");
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    my $outdata;
    my $read_file = $test->read(\$outdata, $outfile);
    ok($read_file, "read test output: $outfile");

    is($outdata,"PYTRWQ\n","expected final output (PYTRWQ)");

    $read_file = $test->read(\$outdata, $teefile1);
    ok($read_file, qq[read intermediate output from $teefile1]);

    is($outdata,"QWERTYUIOP\n","expected intermediate post-cap output (QWERTYUIOP)");
};

subtest 'test simple graph siphoning off output from two nodes to temporary files using the -t option' => sub {
    plan tests => 7;
    my $teefile1 = q[teefile1.txt];
    my $teefile2 = q[teefile2.txt];

    # create input data file
    $test->write($infile, qq[qwertyuiop\n]);
    if($? != 0) { croak qq[Failed to create test input file $infile]; }

    my $exit_status = $test->run(chdir => $test->curdir, args => qq[-v 0 -t "cap=$teefile1;rev=$teefile2" -s -x $graph_file]);
    ok($exit_status>>8 == 0, "non-zero exit for test: $exit_status");

    my $outdata;
    my $read_file = $test->read(\$outdata, $outfile);
    ok($read_file, "read output from $outfile");

    is($outdata,"PYTRWQ\n","expected final output (PYTRWQ)");

    $read_file = $test->read(\$outdata, $teefile1);
    ok($read_file, "read intermediate output from $teefile1");

    is($outdata,"QWERTYUIOP\n","expected intermediate post-cap output (QWERTYUIOP)");

    $read_file = $test->read(\$outdata, $teefile2);
    ok($read_file, "read intermediate output from $teefile2");

    is($outdata,"POIUYTREWQ\n","expected intermediate post-rev output (POIUYTREWQ)");
};

1;

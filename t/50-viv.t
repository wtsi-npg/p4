use strict;
use warnings;
use Test::More tests => 11;
use Test::Cmd;
use Cwd;

my$odir=getcwd();

my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q()); #, match_sub => sub{my($ret,$exp)=@_; return 0 ; $ret=~m/\Q$exp\E/smx} );
ok($test, 'made test object');
foreach(
  ['50-viv_failing_io_pipeline0.vtf', 255, 'Node d has poorly described port __IN1__'],
  ['50-viv_failing_io_pipeline1.vtf', 255, 'Node d has no port __IN_N2__'],
  ['50-viv_failing_io_pipeline2.vtf', 255, 'Node d port __OUT_2__ connected as "to"'],
  ['50-viv_failing_pipeline.vtf', 10, 'Exiting due to abnormal return from child n2'],
  ['50-viv_pipeline.vtf', 0, '(viv) - Done']
){
  my($vtf, $estatus, $eerror)=@$_;
  my$exit_status = $test->run(chdir => $test->curdir, args => "-s -x $odir/t/data/$vtf");
  cmp_ok($exit_status>>8, q(==), $estatus, "expected exit status of $estatus for $vtf");
  like($test->stderr,qr(\Q$eerror\E)smx, "expected err info for $vtf");
}



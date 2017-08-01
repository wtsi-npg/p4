use strict;
use warnings;
use Test::More tests => 21;
use Test::Cmd;
use Cwd;

my$odir=getcwd();

my $test = Test::Cmd->new( prog => $odir.'/bin/viv.pl', workdir => q()); #, match_sub => sub{my($ret,$exp)=@_; return 0 ; $ret=~m/\Q$exp\E/smx} );
ok($test, 'made test object');
foreach(
  ['50-viv_failing_io_pipeline0.vtf', 255, 'ERROR: to port d:__IN1__ referenced in edge (n2:__stdout__ => d:__IN1__), but no corresponding port found in nodes'],
  ['50-viv_failing_io_pipeline1.vtf', 255, 'ERROR: to port d:__IN_N2__ referenced in edge (m:__stdout__ => d:__IN_N2__), but no corresponding port found in nodes'],
  ['50-viv_failing_io_pipeline2.vtf', 255, 'ERROR: to port to_id:__OUT_2__ refers to output port in node'],
  ['50-viv_failing_pipeline.vtf', 10, 'Exiting due to abnormal status return from child n2'],
  ['50-viv_pipeline.vtf', 0, '(viv) - Done'],
  ['50-viv_failing_io_pipeline0.v2.vtf', 255, 'ERROR: to port to_id:__IN1__ refers to output port in node'],
  ['50-viv_failing_io_pipeline1.v2.vtf', 255, 'ERROR: to port d:__IN_N2__ referenced in edge (m:__stdout__ => d:__IN_N2__), but no corresponding port found in nodes'],
  ['50-viv_failing_io_pipeline2.v2.vtf', 255, 'ERROR: to port to_id:__OUT_2__ refers to output port in node'],
  ['50-viv_failing_pipeline.v2.vtf', 10, 'Exiting due to abnormal status return from child n2'],
  ['50-viv_pipeline.v2.vtf', 0, '(viv) - Done'],
){
  my($vtf, $estatus, $eerror)=@$_;
  my$exit_status = $test->run(chdir => $test->curdir, args => "-s -x $odir/t/data/$vtf");
  cmp_ok($exit_status>>8, q(==), $estatus, "expected exit status of $estatus for $vtf");
#print ">>>> ", $test->stderr;
  like($test->stderr,qr(\Q$eerror\E)smx, "expected err info for $vtf");
}



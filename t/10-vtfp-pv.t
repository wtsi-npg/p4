use strict;
use warnings;
use Carp;
use Test::More tests => 3;
use Test::Deep;
use Perl6::Slurp;
use Data::Dumper;
use JSON;

my $template = q[t/data/10-vtfp-pv.json];
my $pv_file = q[t/data/10-vtfp-pv.pv];
my $processed_template = q[t/data/10-vtfp-pv-processed.json];

# just export and reimport parameter values for a template
subtest 'pv0' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => []};
	cmp_deeply ($pv_data, $expected, '(ts1) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~The~,q~funeral~,q~ends~,q~with~,q~a~,q~mournful~,q~fireworks~,q~display~], type => q~EXEC~, id => q~n1~}]};
	cmp_deeply ($vtfp_results, $c, '(ts1) json config generated using pv file matches original generated config');
	cmp_deeply ($vtfp_results, $expected, '(ts1) json config generated using pv file as expected');
};

# export parameter values from a template, overriding default for parameter "subject" from the command-line. Reimport the parameter values.
subtest 'pv1' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file -keys subject,adj -vals party,deafening $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => [ {subject => q~party~, adj =>q~deafening~, }]};
	cmp_deeply ($pv_data, $expected, '(ts2) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~The~,q~party~,q~ends~,q~with~,q~a~,q~deafening~,q~fireworks~,q~display~], type => q~EXEC~, id => q~n1~}]};
	cmp_deeply ($vtfp_results, $c, '(ts2) json config generated using pv file matches original generated config');
	cmp_deeply ($vtfp_results, $expected, '(ts2) json config generated using pv file as expected');
};

# export parameter values from a template, overriding defaults for parameters "subject" and "prepobj" from the command-line. Reimport the parameter values.
subtest 'pv2' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file -keys subject,prepobj -vals world,whimper -nullkeys adj $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => [ {subject => q~world~, prepobj => q~whimper~, adj => undef}]};
	cmp_deeply ($pv_data, $expected, '(ts3) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {edges=> [], nodes => [ {cmd => [q~/bin/echo~,q~The~,q~world~,q~ends~,q~with~,q~a~,q~whimper~], type => q~EXEC~, id => q~n1~}]};
	cmp_deeply ($vtfp_results, $c, '(ts4) json config generated using pv file matches original generated config');
	cmp_deeply ($vtfp_results, $expected, '(ts4) json config generated using pv file as expected');
};

1;

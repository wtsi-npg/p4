use strict;
use warnings;
use Carp;
use Test::More tests => 4;
use File::Slurp;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);

my $tdir = tempdir(CLEANUP => 1);

my $template = q[t/data/10-vtfp-pv.json];
my $pv_file = $tdir.q[/10-vtfp-pv.pv];
my $processed_template = $tdir.q[/10-vtfp-pv-processed.json];
my $which_echo = `which echo`;
chomp $which_echo;

# just export and reimport parameter values for a template
subtest 'pv0' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => [], ops => { splice => [], prune => [], }};
	is_deeply ($pv_data, $expected, '(ts1) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {version => q[1.0], edges=> [], nodes => [ {cmd => [qq~$which_echo~,q~The~,q~funeral~,q~ends~,q~with~,q~a~,q~mournful~,q~fireworks~,q~display~], type => q~EXEC~, id => q~n1~}]};
	is_deeply ($vtfp_results, $c, '(ts1) json config generated using pv file matches original generated config');
	is_deeply ($vtfp_results, $expected, '(ts1) json config generated using pv file as expected');
};

# export parameter values from a template, overriding default for parameter "subject" from the command-line. Reimport the parameter values.
subtest 'pv1' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file -keys subject,adj -vals party,deafening $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => [ {subject => q~party~, adj =>q~deafening~, }], ops => { splice => [], prune => [], }};
	is_deeply ($pv_data, $expected, '(ts2) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {version => q[1.0], edges=> [], nodes => [ {cmd => [qq~$which_echo~,q~The~,q~party~,q~ends~,q~with~,q~a~,q~deafening~,q~fireworks~,q~display~], type => q~EXEC~, id => q~n1~}]};
	is_deeply ($vtfp_results, $c, '(ts2) json config generated using pv file matches original generated config');
	is_deeply ($vtfp_results, $expected, '(ts2) json config generated using pv file as expected');
};

# export parameter values from a template, overriding defaults for parameters "subject" and "prepobj" from the command-line. Reimport the parameter values.
subtest 'pv2' => sub {
	plan tests => 3;

	system(qq[bin/vtfp.pl -verbosity_level 0 -o $processed_template -export_param_vals $pv_file -keys subject,prepobj -vals world,whimper -nullkeys adj $template]) == 0 or croak q[Failed to export params];
	my $pv_data = from_json(slurp $pv_file);
	my $expected = {assign_local => {} ,param_store => [], assign => [ {subject => q~world~, prepobj => q~whimper~, adj => undef}], ops => { splice => [], prune => [], }};
	is_deeply ($pv_data, $expected, '(ts3) exported parameter values as expected');

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -param_vals $pv_file $template |");
	my $c = from_json(slurp $processed_template);
	$expected = {version => q[1.0], edges=> [], nodes => [ {cmd => [qq~$which_echo~,q~The~,q~world~,q~ends~,q~with~,q~a~,q~whimper~], type => q~EXEC~, id => q~n1~}]};
	is_deeply ($vtfp_results, $c, '(ts4) json config generated using pv file matches original generated config');
	is_deeply ($vtfp_results, $expected, '(ts4) json config generated using pv file as expected');
};

# test node splice/prune via param file
subtest 'pv3' => sub {
	plan tests => 2;

	my $basic_linear_template = {
			description => q[simple linear chain (stdin->stdout) of nodes],
			version => q[1.0],
			nodes =>
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
					cmd => [ q/rev/ ]
				},
				{
					id => q[uc],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
				},
				{
					id => q[disemvowel],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/-d/, q/[aeiouAEIOU]/ ],
				},
				{
					id => q[output],
					type => q[OUTFILE],
					name => q/tmp.xxx/,
				},
			],
			edges =>
			[
				{ id => q[e0], from => q[hello], to => q[rev] },
				{ id => q[e1], from => q[rev], to => q[uc] },
				{ id => q[e2], from => q[uc], to => q[disemvowel] },
				{ id => q[e3], from => q[disemvowel], to => q[output] }
			]
	};

	my $template = $tdir.q[/10-vtfp-pv_splice.json];
	my $template_contents = to_json($basic_linear_template);
	write_file($template, $template_contents);

	my $splice_pv = {assign_local => {} ,param_store => [], assign => [ ], ops => { splice => [ q{rev}, ], prune => [], }};
	my $pv = $tdir.q[/10-vtfp-pv_splice_prune_pvin.json];
	my $pv_contents = to_json($splice_pv);
	write_file($pv, $pv_contents);

	my $vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -no-absolute_program_paths -param_vals $pv $template |");

	my $expected = { 
			version => q[1.0],
			nodes =>
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
					id => q[disemvowel],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::true,
					cmd => [ q/tr/, q/-d/, q/[aeiouAEIOU]/ ],
				},
				{
					id => q[output],
					type => q[OUTFILE],
					name => q/tmp.xxx/,
				},
			],
			edges =>
			[
				{ id => q/e2/, from => q/uc/, to => q/disemvowel/ },
				{ id => q/e3/, from => q/disemvowel/, to => q/output/ },
				{ id => q/hello_to_uc/, from => q/hello/, to => q/uc/ },
			]
		};

	is_deeply ($vtfp_results, $expected, '(pv3) one node in a chain spliced out');

	my $prune_pv = {assign_local => {} ,param_store => [], assign => [ ], ops => { splice => [], prune => [ q{disemvowel-}], }};
	$pv = $tdir.q[/10-vtfp-pv_prune_pvin.json];
	$pv_contents = to_json($prune_pv);
	write_file($pv, $pv_contents);

	$vtfp_results = from_json(slurp "bin/vtfp.pl -verbosity_level 0 -no-absolute_program_paths -param_vals $pv $template |");

	$expected = {
			version => q[1.0],
			nodes =>
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
					id => q[uc],
					type => q[EXEC],
					use_STDIN => JSON::true,
					use_STDOUT => JSON::false,
					cmd => [ q/tr/, q/[:lower:]/, q/[:upper:]/ ],
				},
			],
			edges =>
			[
				{ id => q/e0/, from => q/hello/, to => q/rev/ },
				{ id => q/e1/, from => q/rev/, to => q/uc/ },
			]
		};
	is_deeply ($vtfp_results, $expected, '(pv3) prune final two nodes in a chain (output to STDOUT switched off)');
};

1;

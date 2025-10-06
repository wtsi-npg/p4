use strict;
use warnings;
use Test::More tests => 1;
use File::Slurp;
use Perl6::Slurp;
use JSON;
use File::Temp qw(tempdir);

my $tdir = tempdir(CLEANUP => 1);

my $splice_bug_template = {
    description => q[Graph to test splice bug with unspecified destination from a named port],
    version => q[1.0],
    nodes => [
        { id => q[A], type => q[EXEC], use_STDIN => JSON::false, use_STDOUT => JSON::true, cmd => [q/echo/, q/A/] },
        { id => q[B], type => q[EXEC], use_STDIN => JSON::true, use_STDOUT => JSON::false, cmd => "cat > __B_OUT__" },
        { id => q[C], type => q[EXEC], use_STDIN => JSON::true, use_STDOUT => JSON::true, cmd => [q/cat/] },
        { id => q[D], type => q[OUTFILE], name => q/output.txt/ },
    ],
    edges => [
        { id => q[e1], from => q[A], to => q[B] },
        { id => q[e2], from => q[B:__B_OUT__], to => q[C] },
        { id => q[e3], from => q[C], to => q[D] },
    ]
};

my $template_file = $tdir . q[/splice_bug_template.json];
write_file($template_file, to_json($splice_bug_template));

# The splice operation 'B:__B_OUT__-' should remove C and D, and connect B:__B_OUT__ to a new STDOUT node.
my $vtfp_results = from_json(slurp "bin/vtfp.pl -no-absolute_program_paths -verbosity_level 0 -splice_nodes 'B:__B_OUT__-' $template_file |");

my $expected_results = {
    version => q[1.0],
    nodes => [
        { id => q[A], type => q[EXEC], use_STDIN => JSON::false, use_STDOUT => JSON::true, cmd => [q/echo/, q/A/] },
        { id => q[B], type => q[EXEC], use_STDIN => JSON::true, use_STDOUT => JSON::false, cmd => "cat > __B_OUT__" },
        { id => q[STDOUT_00000], name => q[/dev/stdout], type => q[OUTFILE] }
    ],
    edges => [
        { id => q[e1], from => q[A], to => q[B] },
        { id => q/B:__B_OUT___to_STDOUT/, from => q[B:__B_OUT__], to => q[STDOUT_00000] }
    ]
};

is_deeply($vtfp_results, $expected_results, 'Splice with unspecified destination from a named port should work correctly');

1;
#!/usr/bin/perl

use strict;
use warnings;

my $last_pn = "";
my $pp = "";

while (<>) {
    chomp;
    if (/^\@PG/) {
	if (/\tPP:([^\t]+)/) {
	    next if ($1 ne $pp);
	    ($pp) = /ID:([^\t]+)/;
	} else {
	    if ($last_pn) { $_ .= "\tPP:$last_pn"; }
	    ($last_pn) = /ID:([^\t]+)/;
	    $pp = $last_pn;
	}
    } elsif (/^\@SQ/ && /\tSN:MN908947.3/ && !/\tM5:/) {
	$_ .= "\tUR:https://www.ncbi.nlm.nih.gov/nuccore/MN908947.3?report=fasta\tAS:MN908947.3\tM5:105c82802b67521950854a851fc6eefd\tSP:SARS-CoV-2 isolate Wuhan-Hu-1";
    }
    print "$_\n";
}

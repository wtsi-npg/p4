#!/usr/bin/env perl

use strict;
use warnings;

use File::Slurp;

#print "file: $ARGV[0]\n";

my @a=read_file($ARGV[0]);
chomp @a;
my %h;
for my $i (@a) {
  $h{$i} = 1;
}

while(<STDIN>) {
  my @b = split "\t";
  if($b[0] =~ /^@/ or not $h{$b[0]}) {print join "\t", @b;  }
}


#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

my @fns = grep {-f } @ARGV;
my @fhs = map { open my $fh, '<', $_; $fh } @fns;

for my $fh (@fhs) {
  while(<$fh>) {
    if(/taxid\|9606$/) { print }
  }
}


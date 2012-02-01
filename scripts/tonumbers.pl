#!/usr/bin/perl

# converts file format to numbers for use with SVM light and
# liblinear.  This version is for multi-class classification (classes
# are the natural numbers)
#
# This version of the script takes an "outcome" flag (-o) which allows
# you to easily do multiway or one-versus-all classification.  If -o
# is "all", all outcomes seen in the incoming stream (first field) are
# output directly after being converted to number.  If it's anything
# else (say, "X"), then outcomes matching the request are passed
# through, but outcomes not matching are mapped to "not{X}".

use File::Basename;
use Getopt::Std;
use strict;
use warnings;

my %opts = (
  o => "all"
);
getopts('o:', \%opts);

my %ids;

# make sure the positive class gets assigned first
if ($opts{o} ne "all") {
  $ids{$opts{o}} = 1;
  $ids{"not$opts{o}"} = 2;
}

# count the number of outcomes
foreach my $file (@ARGV) {
  open READ, $file or die;
  while (my $line = <READ>) {
	chomp($line);
	my ($outcome) = split(' ',$line);

	$outcome = "not$opts{o}" if ($opts{o} ne "all" and $opts{o} ne $outcome);

	if (! exists $ids{$outcome}) {
	  $ids{$outcome} = scalar (keys %ids) + 1;
	}
  }
  close(READ);
}

my $numkeys = scalar keys %ids;
if ($numkeys == 2) {
  my @keys = keys %ids;
  $ids{$keys[0]} = "+1";
  $ids{$keys[1]} = "-1";
}

# now procss the files
foreach my $file (@ARGV) {
  open READ, $file or die;
  my $base = basename($file);
  open WRITE, ">$base.id" or die "can't write to $base";
  select(WRITE);
  while (my $line = <READ>) {
	chomp($line);
	my ($outcome,@features) = split(' ',$line);

	$outcome = "not$opts{o}" if ($opts{o} ne "all" and $opts{o} ne $outcome);

	if (! exists $ids{$outcome}) {
	  $ids{$outcome} = scalar (keys %ids) + 1;
	}
	print "$ids{$outcome}";

	my %features;
	foreach my $feature (@features) {
	  my ($name,$val) = split(':',$feature);
	  if (! exists $ids{$name}) {
		$ids{$name} = scalar (keys %ids) + 1;
	  }
	  my $id = $ids{$name};

	  $features{$id} = $val;
	}

	foreach my $key (sort { $a <=> $b } keys %features) {
	  if (defined $features{$key}) {
		print " $key:$features{$key}";
	  } else {
		print " $key";
	  }
	}

	print $/;
  }
  close(WRITE);
  close(READ);
}


foreach my $key (sort { $ids{$a} <=> $ids{$b} } keys %ids) {
  print STDERR "$ids{$key} $key\n";
}
  

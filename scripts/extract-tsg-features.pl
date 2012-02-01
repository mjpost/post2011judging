#!/usr/bin/perl

# computes TSG features from a TSG derivation

use strict;
use warnings;
use List::Util qw/reduce max/;
use TSG;

my $feature = shift or die "need a feature!";
if ($feature ne "heights" and $feature ne "terms" and $feature ne "trees" and $feature ne "rules") {
  die "invalid feature!";
}

while (my $derivation = <>) {
  chomp $derivation;
  
  if ($derivation eq "" or $derivation eq "(TOP)") {
	print "\n";
	next;
  }

  my %fragments;
  my @fragments;
  my $tree = build_subtree($derivation);
  extract_subtrees($tree, \@fragments);

  my $subtree_count = 0;
  my $lex_fragment_count = 0;
  my (%heights, %lexheights, %terms, %lexterms);
  foreach my $str (@fragments) {
	$fragments{remove_punc($str)}++;

	my $subtree = build_subtree($str);
	$heights{makebin($subtree->{depth})}++;
    $subtree_count++ if $subtree->{depth} > 1;

    my @frontier = split(' ',$subtree->{frontier});
    my $numterms = scalar @frontier;
    my $numlex = scalar (grep /^_.*_$/, @frontier);
	$lex_fragment_count++ if $subtree->{depth} > 1 and $numlex;

    $terms{makebin($numterms)}++;
    $lexterms{makebin($numlex)}++;

    $lexheights{makebin($subtree->{depth})}++ if $numlex;
  }

  my @features;

  if ($feature eq "heights") {
	foreach my $key (keys %heights) {
	  push @features, "heights/$key:$heights{$key}"
	}
	foreach my $key (keys %lexheights) {
	  push @features, "lexheights/$key:$lexheights{$key}"
	}
  } elsif ($feature eq "terms") {
	foreach my $key (keys %terms) {
	  push @features, "terms/$key:$terms{$key}"
	}
	foreach my $key (keys %lexterms) {
	  push @features, "lexterms/$key:$lexterms{$key}"
	}
  } elsif ($feature eq "trees") {
	push @features, "trees:$subtree_count lextrees:$lex_fragment_count";
  } elsif ($feature eq "rules") {
	push @features, join(" ", map { "$_:$fragments{$_}" } (keys %fragments) );
  }

  print join(" ", @features) . "\n";
}

sub makebin {
  my $num = shift;

  if ($num <= 5) {
	return $num;
  } elsif ($num <= 10) {
	return "6-10";
  } else {
	return "10+";
  }
}

sub remove_punc {
  my ($arg) = @_;
  $arg =~ s/:/_COLON_/g;
  $arg =~ s/ /_/g;
  return $arg;
}

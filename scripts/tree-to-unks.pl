#!/usr/bin/perl

# Takes a PTB-style tree, grabs the leaves, and UNKs the ones not
# found in the lexicon

use strict;
use warnings;

my $lexicon = shift or die "usage: cat PTB_file | $0 <lexicon file>";
my %lexicon;
open LEX, $lexicon or die;
while (my $word = <LEX>) {
  chomp($word);
  $lexicon{$word} = 1;
}
close LEX;

while (my $line = <>) {
  chomp($line);

  if ($line eq "(())") {
	print "$line\n";
	next;
  }

  my @tokens = split(' ', $line);
  for my $i (0..$#tokens) {
	my $token = $tokens[$i];
	if ($token =~ /([^\)]+)(\)+)/) {

	  my $word = $1;
	  my $brackets = $2;

	  # print "TOKEN: $word -- $brackets\n";

	  $word = signature($word);;
	  $tokens[$i] = "$word$brackets";
	}
  }
  print join(" ", @tokens) . $/;
}

sub signature {
  my $word = shift;

  # get rid of lex markers
  $word =~ s/^_|_$//g;

  # known words are their own signature, as are already-UNKed words
  return $word if exists $lexicon{$word} or $word =~ /^UNK/;

  my $sig = "UNK";
  my $lowered = lc($word);

  if ($word =~ /^[A-Z]/) {
	if (lcfirst($word) eq $lowered) { # only 1st char is uppercase
	  $sig = "$sig-INITC";
	  $sig = "$sig-KNOWNLC", if exists $lexicon{$lowered};
	} else { $sig = "$sig-CAPS"; }
  } else { 
	if ($word ne $lowered) {
	  $sig = "$sig-CAPS";
	} else { 
	  $sig = "$sig-LC"; } 
  }

  $sig = "$sig-NUM", if ($word =~ /[0-9]/);
  $sig = "$sig-DASH", if ($word =~ /[-]/);

  my $len = length($word);
  if ($len>=3 && $lowered =~ /s$/){
	$sig = "$sig-s", if !($lowered =~ /ss$/ || $lowered =~ /us$/ || $lowered =~ /is$/);
  }


  if ($len>=5) {
	$sig = "$sig-ed", if ($lowered =~ /ed$/);
	$sig = "$sig-ing", if ($lowered =~ /ing$/);
	$sig = "$sig-ion", if ($lowered =~ /ion$/);
	$sig = "$sig-er", if ($lowered =~ /er$/);
	$sig = "$sig-est", if ($lowered =~ /est$/);
	$sig = "$sig-al", if ($lowered =~ /al$/);
	if ($lowered =~ /y$/){
	  if ($lowered =~ /ly$/){ 
		$sig = "$sig-ly"; 
	  } else { 
		if ($lowered =~ /ity$/) {  
		  $sig = "$sig-ity"; 
		} else { 
		  $sig = "$sig-y"; 
		} 
	  }
	}
  }

  return $sig;
}

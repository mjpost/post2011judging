#!/bin/bash

# To use this: place a file named "words" in the directory you are
# building.  This file is the set of sentences that are to be
# classified.  You can then call the script in any of the following
# ways:
#
# ./builddir.sh DIR
# dir=DIR ./builddir.sh

######################################################################
# SET THESE ##########################################################
######################################################################

basedir=/path/to/unpacked/tarball/that/matt/post/sent
DPTSG=/path/to/dptsg

######################################################################

trap exit SIGINT

set -u
set -e

: ${dir=$1}

lex=$basedir/data/lex.02-21
stopwords=$basedir/data/stopwords.dat
extract_tsg=$basedir/scripts/extract-tsg-features.pl

if test ! -d "$dir"; then
	echo "$dir does not exist! quitting"
	exit
fi

if ! test -e "$dir/words"; then
	echo "can't find corpus '$dir/words'! quitting"
	exit
fi

# parse with TSG parser
cd $dir

[[ ! -d "tsg" ]] && mkdir tsg
cd tsg

# The Johnson parser can't deal with unknown words, so preprocess them
# to UNKs
cat ../words | perl $DPTSG/scripts/corpus2unks.pl -lexicon $basedir/data/lex.02-21 > corpus.UNK

# Parse the data
#
# (1) Parallel version.  To use this, edit parallelize/LocalConfig.pm
# so that your environment is detected and the appropriate arguments
# are passed to qsub.
#
#cat corpus.UNK | perl $basedir/parallelize/parallelize.pl -j 100 -- $basedir/cky/llncky - $basedir/data/rule_probs.mj > parse.out
# 
# (2) Sequential version.  This version will run much slower since the Johnson CKY parser is exhaustive, but it should be reasonably fast.
#
cat corpus.UNK | $basedir/cky/llncky - $basedir/data/rule_probs.mj > parse.out

# Split out the parses and the scores
cat parse.out | $basedir/scripts/splittabs.pl scores parses

# Expand the TSG rules from their flattened CFG representations
cat parses | $DPTSG/scripts/convert_from_johnson.pl -map $basedir/data/rule_probs.map -scrub 0 -delex 0 > parses.full

# Extract TSG fragments and aggregate features
for feature in rules heights terms trees; do
	cat tsg/parses.full $extract_tsg $feature > $feature
done

# Extract UNKed TSG fragments
cat tsg/parses.full | $basedir/scripts/tree-to-unks.pl $stopwords | $extract_tsg rules > rules


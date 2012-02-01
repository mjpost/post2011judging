#!/bin/bash

. ~/.bashrc
. $CACHEPIPE/bashrc

set -u

dir=$1

cd $dir

[[ ! -d "tsg" ]] && mkdir tsg
cd tsg

cachecmd unks "cat ../words | perl /home/hltcoe/mpost/code/dptsg/scripts/corpus2unks.pl -lexicon /home/hltcoe/mpost/expts/lsa11/data/lex.02-21 > corpus.UNK" ../words corpus.UNK

cachecmd parse "cat corpus.UNK | perl /home/hltcoe/mpost/code/cdec/vest/parallelize.pl -j 100 -- /home/hltcoe/mpost/code/cky/llncky - /home/hltcoe/mpost/expts/lsa11/data/rule_probs.mj > parse.out" corpus.UNK parse.out 

cachecmd split "cat parse.out | ~/bin/splittabs.pl scores parses" parse.out scores parses

cachecmd restore "cat parses | $DPTSG/scripts/convert_from_johnson.pl -map /home/hltcoe/mpost/expts/lsa11/data/rule_probs.map -scrub 0 -delex 0 > parses.full" parses parses.full

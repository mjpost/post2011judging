#!/bin/bash

# This script does training and classification for a given set of
# features.  It is called with a list of features desired in the
# model; it then constructs training and test data sets by looking for
# files corresponding to those features in each of six directories:
# {train,dev,test}/{$sys1,$sys2}/FEATURE.
#
# Features in files should have the format FEATURENAME:VALUE.


#################################################################
# SET THESE #####################################################
#################################################################

train=~/code/liblinear-1.7/train
predict=~/code/liblinear-1.7/predict

#################################################################

set -u

basedir=$(pwd)
: ${rundir=$basedir/run.test}
: ${sys1=good}    # directory containing system 1 output (e.g., good)
: ${sys2=bad}     # directory containing system 2 output (e.g., bad)
: ${force=0}      # run even if the directory exists

if [[ ! -e "$train" || ! -e "$predict" ]]; then
   echo "can't find classifier binaries"
   exit
fi

# concatenate the feature names, and use it to create the run
# directory where the model files will go
concat=$(echo $@ | sed 's/ /-/g')
rundir=run.$concat

if [[ -d $rundir ]]; then
  if [[ $force -eq 1 ]]; then
    rm -rf $rundir
  else
    echo "$rundir exists, refusing to proceed."
    echo "Remove it, or set force=1 to have it removed for you."
    exit
  fi
fi

echo "using rundir $rundir"
mkdir $rundir
cd $rundir


# construct the feature sets
for item in $@; do 
    for which in train dev test; do
        for type in $sys1 $sys2; do

			numlinesneeded=$(cat $basedir/$which/$type/words | wc -l)
			numlines=$(cat $basedir/$which/$type/$item | wc -l);
			if test $numlines -ne $numlinesneeded; then
				echo "* FATAL: feature file '$which/$type/$item' has wrong number of lines ($numlines instead of $numlinesneeded)"
				exit
			fi

            grep ":" $basedir/$which/$type/$item > /dev/null
            if [[ $? -eq 1 ]]; then
                echo "* FATAL: file $basedir/$which/$type/$item does not seem to have the right"
                echo "format. Features should be listed in the format feature:value (as many as"
                echo "you'd like per line."
                exit
            fi
                
            cat $basedir/$which/$type/$item >> .$which.$item
        done
    done
done

# generate the outcome labels (the first column in svm-light/liblinear)
# this uses the "words" file to know how many lines to use, and the value
# of $sys1 and $sys2 as positive and negative labels
for which in train dev test; do
	for type in $sys1 $sys2; do
        cat $basedir/$which/$type/words | perl -pe "s/.*/$type/" >> .$which._
 	done
done

for name in train dev test; do
        # modify data points for unparseable sentences
        #paste .$name.* | perl -pe 's/inf/99999/g' > $name.txt
    paste .$name.* | perl -pe 's/\S*\.(\S*):-inf/$1.failed:1/g' > $name.txt

        # remove data points for unparsed sentences
#       paste .$name.* | grep -v inf > $name.txt
done

# train
~/expts/lsa11/scripts/tonumbers.pl {train,dev,test}.txt 2> map
gzip -9 *.txt

# find best smoothing parameter
best=0
bestsmooth=0.00001
for smooth in 0.00001 0.0001 0.001 0.01 0.1 1 10 100; do
	$train -q -B 1 -c $smooth train.txt.id
	mv train.txt.id.model train.txt.id.model-$smooth
	accuracy=$($predict dev.txt.id train.txt.id.model-$smooth /dev/null | awk '{print $3}' | sed 's/%//')
	echo "SMOOTH $smooth ACC $accuracy BEST $best ($bestsmooth)" | tee -a results
	improved=$(echo "$accuracy > $best" | bc)
	if test $improved -eq 1; then
		best=$accuracy
		bestsmooth=$smooth
	fi
done
echo "best smooth on dev was $bestsmooth ($best)" | tee -a results

$predict test.txt.id train.txt.id.model-$bestsmooth /dev/null | awk '{print $3}' | sed 's/%//' | tee -a results
grep nr_feature train.txt.id.model-$bestsmooth | tee -a results

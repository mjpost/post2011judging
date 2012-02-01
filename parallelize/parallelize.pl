#!/usr/bin/env perl

# Author: Adam Lopez
#
# This script takes a command that processes input
# from stdin one-line-at-time, and parallelizes it
# on the cluster using David Chiang's sentserver/
# sentclient architecture.
#
# Prerequisites: the command *must* read each line
# without waiting for subsequent lines of input
# (for instance, a command which must read all lines
# of input before processing will not work) and
# return it to the output *without* buffering
# multiple lines.

#TODO: if -j 1, run immediately, not via sentserver?  possible differences in environment might make debugging harder

#ANNOYANCE: if input is shorter than -j n lines, or at the very last few lines, repeatedly sleeps.  time cut down to 15s from 60s

my $SCRIPT_DIR; BEGIN { use Cwd qw/ abs_path /; use File::Basename; $SCRIPT_DIR = dirname(abs_path($0)); push @INC, $SCRIPT_DIR, "$SCRIPT_DIR"; }
use LocalConfig;

use File::Temp qw/ tempfile /;
use Getopt::Long;
use IPC::Open2;
use strict;
use POSIX ":sys_wait_h", "setsid";
use Cwd qw(getcwd);

my $tailn=5; # +0 = concatenate all the client logs.  5 = last 5 lines
my $recycle_clients;    # spawn new clients when previous ones terminate

my $stay_alive;      # dont let server die when having zero clients
my $joblist = "";
my $errordir="";
my $multiline;
my $default_numnodes = 8;
my $numnodes = $default_numnodes;
my $user = $ENV{"USER"};
my $default_pmem = "2g";
my $pmem = $default_pmem;
my $default_queue = undef;
my $queue = $default_queue;
my $qsub_args;
my $basep=50300;
my $randp=300;
my $tryp=50;
my $no_which;
my $no_cd;

my $DEBUG=$ENV{DEBUG};
print STDERR "DEBUG=$DEBUG output enabled.\n" if $DEBUG;
my $verbose = 1;
sub verbose {
    if ($verbose) {
        print STDERR @_,"\n";
    }
}
sub debug {
    if ($DEBUG) {
        my ($package, $filename, $line) = caller;
        print STDERR "DEBUG: $filename($line): ",join(' ',@_),"\n";
    }
}
sub abspath($) {
    my $p=shift;
    my $a=`readlink -f $p`;
    chomp $a;
    $a
}
my $is_shell_special=qr.[ \t\n\\><|&;"'`~*?{}$!()].;
my $shell_escape_in_quote=qr.[\\"\$`!].;
sub escape_shell {
    my ($arg)=@_;
    return undef unless defined $arg;
    return '""' unless $arg;
    if ($arg =~ /$is_shell_special/) {
        $arg =~ s/($shell_escape_in_quote)/\\$1/g;
        return "\"$arg\"";
    }
    return $arg;
}
sub preview_files {
    my ($l,$skipempty,$footer,$n)=@_;
    $n=$tailn unless defined $n;
    my @f=grep { ! ($skipempty && -z $_) } @$l;
    my $fn=join(' ',map {escape_shell($_)} @f);
    my $cmd="tail -n $n $fn";
    `$cmd`.($footer?"\nNONEMPTY FILES:\n$fn\n":"");
}
sub prefix_dirname($) {
    #like `dirname but if ends in / then return the whole thing
    local ($_)=@_;
    if (/\/$/) {
        $_;
    } else {
        s#/[^/]$##;
        $_ ? $_ : '';
    }
}
sub ensure_final_slash($) {
    local ($_)=@_;
    m#/$# ? $_ : ($_."/");
}
sub extend_path($$;$$) {
    my ($base,$ext,$mkdir,$baseisdir)=@_;
    if (-d $base) {
        $base.="/";
    } else {
        my $dir;
        if ($baseisdir) {
            $dir=$base;
            $base.='/' unless $base =~ /\/$/;
        } else {
            $dir=prefix_dirname($base);
        }
        my @cmd=("/bin/mkdir","-p",$dir);
        system(@cmd) if $mkdir;
    }
    return $base.$ext;
}

my $abscwd=abspath(&getcwd);
sub print_help;

my $use_fork;
my @pids;

# Process command-line options
unless (GetOptions(
      "stay-alive" => \$stay_alive,
      "recycle-clients" => \$recycle_clients,
      "error-dir=s" => \$errordir,
      "multi-line" => \$multiline,
      "use-fork" => \$use_fork,
      "verbose!" => \$verbose,
      "jobs=i" => \$numnodes,
      "pmem=s" => \$pmem,
      "queue=s" => \$queue,
	  "qsub-args=s" => \$qsub_args,
      "baseport=i" => \$basep,
      "no-which!" => \$no_which,
      "no-cd!" => \$no_cd,
      "tailn=s" => \$tailn,
) && scalar @ARGV){
  print_help();
    die "bad options.";
}

my $cmd = "";
my $prog=shift;
if ($no_which) {
    $cmd=$prog;
} else {
    $cmd=`which $prog`;
    chomp $cmd;
    die "$prog not found - $cmd" unless $cmd;
}
#$cmd=abspath($cmd);
for my $arg (@ARGV) {
    $cmd .= " ".escape_shell($arg);
}
die "Please specify a command to parallelize\n" if $cmd eq '';

my $cdcmd=$no_cd ? '' : ("cd ".escape_shell($abscwd)."\n");

my $executable = $cmd;
$executable =~ s/^\s*(\S+)($|\s.*)/$1/;
$executable=`basename $executable`;
chomp $executable;


print STDERR "Parallelizing ($numnodes ways): $cmd\n\n";

# create -e dir and save .sh
use File::Temp qw/tempdir/;
unless ($errordir) {
    $errordir=tempdir("$executable.XXXXXX",CLEANUP=>1);
}
if ($errordir) {
    my $scriptfile=extend_path("$errordir/","$executable.sh",1,1);
    -d $errordir || die "should have created -e dir $errordir";
    open SF,">",$scriptfile || die;
    print SF "$cdcmd$cmd\n";
    close SF;
    chmod 0755,$scriptfile;
    $errordir=abspath($errordir);
    &verbose("-e dir: $errordir");
}

# set cleanup handler
my @cleanup_cmds;
sub cleanup;
sub cleanup_and_die;
$SIG{INT} = "cleanup_and_die";
$SIG{TERM} = "cleanup_and_die";
$SIG{HUP} = "cleanup_and_die";

# other subs:
sub numof_live_jobs;
sub launch_job_on_node;


# vars
my $mydir = `dirname $0`; chomp $mydir;
my $sentserver = "$mydir/sentserver";
my $sentclient = "$mydir/sentclient";
my $host = `hostname`;
chomp $host;


# find open port
srand;
my $port = $basep+int(rand($randp));
my $endp=$port+$tryp;
sub listening_port_lines {
    my $quiet=$verbose?'':'2>/dev/null';
    `netstat -a -n $quiet | grep LISTEN | grep -i tcp`
}
my $netstat=&listening_port_lines;

if ($verbose){ print STDERR "Testing port $port...";}

while ($netstat=~/$port/ || &listening_port_lines=~/$port/){
  if ($verbose){ print STDERR "port is busy\n";}
  $port++;
  if ($port > $endp){
    die "Unable to find open port\n";
  }
  if ($verbose){ print STDERR "Testing port $port... "; }
}
if ($verbose){
  print STDERR "port $port is available\n";
}

my $key = int(rand()*1000000);

my $multiflag = "";
if ($multiline){ $multiflag = "-m"; print STDERR "expecting multiline output.\n"; }
my $stay_alive_flag = "";
if ($stay_alive){ $stay_alive_flag = "--stay-alive"; print STDERR "staying alive while no clients are connected.\n"; }

my $node_count = 0;
my $script = "";
# fork == one thread runs the sentserver, while the
# other spawns the sentclient commands.
if (my $pid = fork) {
  sleep 8; # give other thread time to start sentserver
  $script =
      qq{wait
$cdcmd$sentclient $host:$port:$key $cmd
};
  if ($verbose){
    print STDERR "Client script:\n====\n";
    print STDERR $script;
    print STDERR "====\n";
  }
  for (my $jobn=0; $jobn<$numnodes; $jobn++){
    launch_job();
  }
  if ($recycle_clients) {
    my $ret;
    my $livejobs;
    while (1) {
      $ret = waitpid($pid, WNOHANG);
      #print STDERR "waitpid $pid ret = $ret \n";
      last if ($ret != 0);
      $livejobs = numof_live_jobs();
      if ($numnodes >= $livejobs ) {  # a client terminated, OR # lines of input was less than -j
        print STDERR "num of requested nodes = $numnodes; num of currently live jobs = $livejobs; Client terminated - launching another.\n";
        launch_job();
      } else {
        sleep 15;
      }
    }
  }
  waitpid($pid, 0);
  cleanup();
} else {
#  my $todo = "$sentserver -k $key $multiflag $port ";
  my $quiet = ($verbose > 0) ? "" : "-q";
  my $todo = "$sentserver -k $key $multiflag $port $stay_alive_flag $quiet";
  if ($verbose){ print STDERR "Running: $todo\n"; }
  my $rc = system($todo);
  if ($rc){
    die "Error: sentserver returned code $rc\n";
  }
}

sub numof_live_jobs {
  if ($use_fork) {
    die "not implemented";
  } else {
    my @livejobs = grep(/$joblist/, split(/\n/, `qstat`));
    return ($#livejobs + 1);
  }
}
my (@errors,@outs,@cmds);

sub launch_job {
    if ($use_fork) { return launch_job_fork(); }
    my $errorfile = "/dev/null";
    my $outfile = "/dev/null";
    $node_count++;
    my $clientname = $executable;
    $clientname =~ s/^(.{4}).*$/$1/;
    $clientname = "$clientname.$node_count";
    if ($errordir){
      $errorfile = "$errordir/$clientname.ER";
      $outfile = "$errordir/$clientname.OU";
      push @errors,$errorfile;
      push @outs,$outfile;
    }
    my $todo = qsub_args($pmem,$queue) . " -N $clientname -o $outfile -e $errorfile $qsub_args";
    push @cmds,$todo;

    print STDERR "Running: $todo\n";
    local(*QOUT, *QIN);
    open2(\*QOUT, \*QIN, $todo) or die "Failed to open2: $!";
    print QIN $script;
    close QIN;
    while (my $jobid=<QOUT>){
      chomp $jobid;
      if ($verbose){ print STDERR "Launched client job: $jobid"; }
      $jobid =~ s/^(\d+)(.*?)$/\1/g;
            $jobid =~ s/^Your job (\d+) .*$/\1/;
      print STDERR " short job id $jobid\n";
            if ($verbose){
                print STDERR "cd: $abscwd\n";
                print STDERR "cmd: $cmd\n";
            }
      if ($joblist == "") { $joblist = $jobid; }
      else {$joblist = $joblist . "\|" . $jobid; }
            my $cleanfn="`qdel $jobid 2> /dev/null`";
      push(@cleanup_cmds, $cleanfn);
    }
    close QOUT;
}

sub launch_job_fork {
  my $errorfile = "/dev/null";
  my $outfile = "/dev/null";
  $node_count++;
  my $clientname = $executable;
  $clientname =~ s/^(.{4}).*$/$1/;
  $clientname = "$clientname.$node_count";
  if ($errordir){
    $errorfile = "$errordir/$clientname.ER";
    $outfile = "$errordir/$clientname.OU";
    push @errors,$errorfile;
    push @outs,$outfile;
  }
  if (my $pid = fork) {
    my ($fh, $scr_name) = get_temp_script();
    print $fh $script;
    close $fh;
    my $todo = "/bin/sh $scr_name 1> $outfile 2> $errorfile";
    print STDERR "EXEC: $todo\n";
    my $out = `$todo`;
    print STDERR "RES: $out\n";
    unlink $scr_name or warn "Failed to remove $scr_name";
    exit 0;
  }
}

sub get_temp_script {
  my ($fh, $filename) = tempfile( "workXXXX", SUFFIX => '.sh');
  return ($fh, $filename);
}

sub cleanup_and_die {
  cleanup();
  die "\n";
}

sub cleanup {
  print STDERR "Cleaning up...\n";
  for $cmd (@cleanup_cmds){
    print STDERR "  Cleanup command: $cmd\n";
    eval $cmd;
  }
  print STDERR "outputs:\n",preview_files(\@outs,1),"\n";
  print STDERR "errors:\n",preview_files(\@errors,1),"\n";
  print STDERR "cmd:\n",$cmd,"\n";
  print STDERR " cat $errordir/*.ER\nfor logs.\n";
  print STDERR "Cleanup finished.\n";
}

sub print_help
{
  my $name = `basename $0`; chomp $name;
  print << "Help";

usage: $name [options] -- <command>

  Automatic black box for embarrassingly parallel
  computations.

  <command> should be a command with the following
  characteristics:
  1) It reads and writes to standard input and output
     without buffering between lines.
  2) It produces one line of input for each line of
     output.
  3) There are no dependencies between each line.

  If these conditions are met, $name will spawn 
  multiple instances of <command> to process standard
  input.  $name threads the results of these instances
  back together in the correct order on standard
  output.

  Note that <command> may be an invocation that 
  contains flags.

options:

  --use-fork
    Instead of using qsub, use fork.

  -e, --error-dir <dir>
    Retain output files from jobs in <dir>, rather
    than silently deleting them.

  -m, --multi-line
    Expect that command may produce multiple output
    lines for a single input line.  $name makes a
    reasonable attempt to obtain all output before
    processing additional inputs.  However, use of this
    option is inherently unsafe.

  -v, --verbose
    Print diagnostic informatoin on stderr.

  -j, --jobs <N>
    Number of jobs to use (default: $default_numnodes).

  -p, --pmem <M>
    memory requested for each job (default: $default_pmem).
  
  -q, --queue <Q>
    which qsub queue to submit the job to (default: not defined).

  --no-which
    Do not use which to determine executable.

  --no-cd
    Prevents spawned instances from being run in the
    directory where $name was invoked.
  
  --stay-alive
    Prevents server instance from exiting when there 
    are no spawned instances.

  --recycle-clients
    Automatically respawn jobs if number decreases
    below number requested.

  --baseport <I>
    Default server port number for socket connections.

  --tailn <N>
    Preview <N> lines of client error files on exit.

examples:

  cat input | $name -- foo > output
    Produces the same result as:
    > cat input | foo > output 
    

Help
}


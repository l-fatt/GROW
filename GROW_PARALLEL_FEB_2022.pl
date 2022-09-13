#! /usr/bin/perl -w
use warnings;
use strict;
use Data::Dumper;
use POSIX; 
use LWP::Simple;
use Parallel::ForkManager; 
use List::Util qw(sum);
use List::Util qw[min max sum];
use Scalar::Util qw(looks_like_number);
use Math::Trig;


# GROWTH BY OPTIMIZATION OF WORK: A tool to predict fracture growth
# Feb 2022
# By: Jess McBeck, Michele Cooke, Betsy Madden, and extensive debugging by Laura Fattaruso

# THIS VERSION ASSUMES THAT ALL FRACTURES AND BOUNDARIES ARE DEFINED ELEMENT BY ELEMENT
# IN THE INPUT FILE.

## GENERAL USAGE #########################################################################################
# GROW.pl <filename.in>  <increment angle> <start angle>  <end angle> <forecast parameters> 
#        <filename.in> fric2d input file, must exist in the current directory, and end in ".in"
#        <increment angle> the number of degrees between each potential crack
#        <start angle> the angle at which to start searching efficient orietations
#        <end angle> the angle at which to end searching (last crack orientation test < end angle)
#        <forecast parameters> i.e. 'min-0.80', 'max-0.95'
#         min/max designating min or max of envelope to construct, 
#         and percentage (80% = 0.80) to determine extent of envelope

# DESCRIPTION OF FILES GENERATED ##########################################################################
# Input filename   : foo.in
# foo.eff          : fric2d input file of most efficient geometry found so far
# foo.raw          : summary of work calculated for various orientations, 
#                    nearly identical to standard output
# foo_cont<num>.in : If any faults propagate for more than 5 iterations, this program 
#                  restarts the process with the same input parameters, except the new input
#                  file, which contains the contents of the most efficient geometry found in the 
#                  last iteration of crack growth. This automatic restart frees memory.  
# standard output: fric2d output statements, work calculated for each scenario, 
#                  scenario number of most efficient geometry for each propagation
#                  if any scenario did not produce slip on the pupative element just created
# Testing filenames: i.e. files generated to test all possible orientations
# foo_prop_fault_end_angle.in : prop = propagation number, fault = fault name, 
#                               end = end growing from (1 or 2), 
#                               angle = clockwise orientation of potential element
# foo_tune_prop_fault_end_angle.in : same values as file described above, but "tune"
#                  indicates that the faults are being tuned
# foo.prev_seq     : the input file of the geometry before a sequential growth of the faults
#                  this input file is preserved so the linear search of the most efficient orientations
#                  can use this input file to generate correct geometries for new geometries to test

# *Crack INPUT LINE USAGE #################################################################################
# *Crack properties represent intact rock values.
# *Fault properties represent fault values.
# In FRIC2D input file:
# Line that specifies the new fault characteristics of the potential element
#    -Must contain the tag *Crack at the beginning of the input file line
#    -Be placed after the fault header that contains the fault name,  but before the list of individual fault segments 
# For example:
# *----------------------
# *Fault Conditions
# *----------------------
# *fault	name	grow_tails?	from_end1?	from_end2?
# *num	xbeg	ybeg	xend	yend	                stiffS	   stiffN	ten-str	init-coh slid-coh stat-fric dy-fric crit-slip dist
# *----	----	----	----	----	                ------	   ------	---     ---      -----    -------   ------  ---------
# fault	left	no	no	yes					
# *tag	                                                stiffS	   stiffN	ten-str	shear-str   coh	int-fric dy-fric crit-dist  
# *Crack					        1.00E+10   1.00E+10	100	0.00008	    10	 1.35	 1.35	 0     
# 41	0	10	20.670	         10	        1.00E+10   1.00E+10	100.0	0.0	    0	 0.6	 0.6	 0
#
# After one element is added to this fault the input file reads:
# *----------------------
# *Fault Conditions
# *----------------------
# *fault	name	grow_tails?	from_end1?	from_end2?
# *num	xbeg	ybeg	xend	yend	                stiffS	   stiffN	ten-str	init-coh slid-coh stat-fric dy-fric crit-slip dist
# *----	----	----	----	----	                ------	   ------	---     ---      -----    -------   ------  ---------
# fault	left	no	no	yes	
# *tag	                                                stiffS	   stiffN	ten-str	shear-str   coh	int-fric dy-fric crit-dist
# *Crack					        1.00E+10   1.00E+10	100	0.00008	    10	 1.35	 1.35	 0     	
# 41	0	10	20.670	        10	        1.00E+10   1.00E+10	100.0	0.0	    0	 0.6	 0.6	 0
# 1	20.670	10	20.31351470	10.35648530	1.00E+10   1.00E+10	100	0.00008	    10	 1.35	 1.35	 0
#
#  WHEN GROWING FROM A POINT ########################################################################################################## 
# In FRIC2D input file:
# The lines that specifies the point from which a new flaw will grow:
#    -Muat be placed after the Fault Conditions header
#    -Must contain *Flaw-Intact at the beginning of the line, then name, x coordinate of point, y coordinate of point, element length
#         and remaining characteristics of intact rock through which crack propagates
#    - Must be preceded with *Flaw-Fault line if the user wants to change properties modelling intact rock to fault characteristics
# For example:  
# *----------------------													
# *Fault	Conditions												
# *----------------------	
# *Tag 	fault 		xcoor 	ycoor 			length 	grow_both? stiffS stiffN 	cohes	friction - s friction -d L 
# *Flaw-Fault 			 				   	   1e10	  1e10		0	0.62	     0.58	0.00025	
# *Flaw-Intact 	backthrust	0.055424 0.01173379	0.002	yes	   1e10	  1e10		100	0.96	     0.72	0.00025 

# WHEN RUNNING SANDBOX
# GROW.pl <input.in> <inc angle> <start angle> <end angle> <topo.topo> <forecast parameters> <DB>
#     <input.in> = fric2d input filename  
#     <inc angle> = angle increment (resolution of search for orientations)
#     <start angle> the angle at which to start searching efficient orietations
#     <end angle> the angle at which to end searching
#     <topo.topo> = fric2d topography filename
#     <forecast parameters> i.e. 'min-0.80', 'max-0.95'
#         min/max designating min or max of envelope to construct, 
#         and percentage (0.80) to determine extent of envelope
#     DB if debugging

# If you want to update the topography from the previous output file,
# write in the Fric2D input file
#*Update topography in GROW? ('YES' or 'NO'), must have spaces on either side of =
#*Update = YES

# Choosing the run mode:
#* Run sequentially (each fault in alphanumeric order at each increment) or serially (only the most efficient fault grows at each increment)
#* 'SEQUENTIAL' or 'SERIAL', must have spaces on either side of =
#*Run_Mode = SERIAL

#* Only test growth from fault tips within 10% of max KI in serial run mode (YES to limit, NO to not limit)
#*Limit_Test = YES

# Choosing to continue to check not growing tips
#  must have spaces on either side of =
#* Continue to check fault tips for growth that stopped growing previously (YES to continue, or NO to not check)
#*Continue_Check = YES

# FUNCTION DECLARATIONS
########################################################################################################################################
# propagate more than one fault with sequential search of minimum work
sub grow;

# return range of angles to test 
sub get_angles;
# returns a hash table listing hashes of scenarios that specify
# the fault name and the angle for which to calculate work
sub get_scenarios;
# reads first input file to determine if
# using stress or displacement conditions, returns true
# if minimizing work (false is maximizing is more efficient config)
sub get_efficient_criteria;
# get mode that we are running fric2d
sub get_run_mode;
# check that input values are as we expect
sub check_input;

# format and write output
sub write_output;
sub write_index; 
sub format_std_output; 
sub print_work_summary; 

# copy file to another with the shell
sub transfer_file;

# get name and end of the fault that is growing
sub get_fault_names;
sub check_final_intersections;
sub check_flags;
# get the coordinates and length of the
# crack that will propagate from this flaw
sub get_flaw_info;
# make the various input/output filenames 
sub make_names;

# find most efficient faults and grow them,
# either sequenially (propagate each in alphabetic order) or serially (try all, propagate one)
sub execute;

# find max and min in list
sub max_list;
sub min_list;

sub update_topo; # update the topography in the input file using previous output file
sub get_update_topo; # determine if we should update the topography

sub check_single; # remove coordinates where element length = 0

sub branch_faults; # split faults where coulomb stress > S0

# EXECUTING MAIN FUNCTION  
####################################################
grow;

# FUNCTION DEFINITIONS
#####################################################
# Main function
sub grow
{
    my ($input_filename, $inc_angle, $start_angle, $end_angle, $topo_filename, $forecast) = @ARGV[0..6];   

    # check that input file ends in .in, and angle values are appropriate
    check_input($input_filename, $inc_angle, $start_angle, $end_angle);      

    # not using a work criterion for now
    my $input_criterion = 0; 

    # if we are passing work from previous run
    my $prev_run_work = 0; 
    # if last input parameter is a number (a work value)
    # then set intial work to value found in last GROW call
    if ($ARGV[-1] =~ /^\d+\.\d+/) 
    {
	$prev_run_work = $ARGV[-1]; 
    }

    # determine what mode we are running GROW
    # DB (debugging without growing from pt), 
    # "sand debug" (growing from pt and debugging)
    # "sand" (growing from a point), 
    # "fric" just plain old fric2d
    my $run_mode = get_run_mode($input_filename, $ARGV[-2], $ARGV[-1]);

    # if choosing smallest angle = 'min', if choosing largest angle = 'max'
    # and # multiplied by max delwext/A
    if ($topo_filename && !($topo_filename =~ /.topo/) && ($topo_filename =~ /min/ || $topo_filename =~ /max/))
    {
	$forecast = $topo_filename;
    }
    if ($forecast && ($forecast =~ /min/ || $forecast =~ /max/))
    {
	$forecast =~ s/-/ /g;
	# ensure forecast parameters correct
	my ($limit, $p) = split(/\s+/, $forecast);
	if ($p > 1 || $p <= 0)
	{
	    die "ERROR: FORECAST PERCENTAGE P MUST BE BETWEEN 0 AND 1 \n";
	}
    }
    # if forecast parameter read in, but does not contain min or max key words
    # set to zero, for later if statements
    if ($forecast && !($forecast =~ /min/ || $forecast =~ /max/))
    {
	$forecast = '';
    }

    # string to accumulate with the work data 
    my $raw_output = "Executing GROW version Feb 2022\n\n"
    ."WARNING: All element node positions of fractures and boundaries must be explicitly defined in the input file.\n"
	."Reading FRIC2D input file: $input_filename \n"
	."\tIncrement angle: $inc_angle \n"
	."\tStarting angle: $start_angle \n"
	."\tEnding angle: $end_angle \n"; 

    my $topo_file_orig = '';
    my $is_update_topo = 1; # decide whether to turn on and off

    if ($topo_filename && ($topo_filename =~ /.topo/))
    {
	$raw_output = $raw_output."\tTopo file: $topo_filename \n"; 
	$topo_file_orig = $topo_filename;
    }

    if ($forecast && ($forecast =~ /min/ || $forecast =~ /max/))
    {
	$raw_output = $raw_output."\tForecast parameters: $forecast \n";
    }
    
    print "\n$raw_output"; 
    

    # make the various file names
    my $root = substr($input_filename, 0, -3); 
    my ($prev_filename, $efficient_filename, $testing_filename,
	$fric_output_filename, $output_filename, $out_raw_filename, $restart_filename) = 
	    make_names($root);

    # copy the input file to a new file
    transfer_file($input_filename, $prev_filename);
    
    # set the initial most efficient configuration to the input file
    transfer_file($input_filename, $efficient_filename);
	
    # get a list of all the faults and flaws that are growing:
    # here, the end value of flaws doesn't matter
    my @fault_names = get_fault_names($prev_filename);
	
    my $fault = "";
    # only get the name of a fault to calculate work criterion
    # in function get_initial_work
    if ($input_criterion != 0)
    {
	$fault = substr($fault_names[0], 0, -2); 
    }
	
    my $eff_file_out = substr($input_filename, 0, -2)."out";

    # get the initial work of the system, 
    # use a random fault to get the work criterion
    my ($prev_work, $crit_work, $new_work_out, $new_raw_out) = 
	get_initial_work($input_filename, $fric_output_filename, $fault,
			 $run_mode, $prev_run_work, 
			 $input_criterion, 
			 $topo_filename);
			 
    # keep list of all most efficient work found so far
    my @works = ($prev_work);
    my @works_unnorm = ($prev_work); 
	
    # update the print statements
    $raw_output = $raw_output.$new_raw_out; 

    my ($is_minimizing, $is_serial, $is_topo, $is_check, $is_limit, $is_branch) = get_efficient_criteria($prev_filename); 
    if ($is_minimizing) 
    {
	print "\tUsing displacements: minimizing work.\n";
    }
    else
    {
	print "\tUsing stress: maximizing work.\n";
    }

    if ($is_serial) 
    {
	print "\tRunning in single run mode (serially) by propagating only the fault that is most efficient.\n";

	if ($is_limit)
	{
	    print "\tLimiting search in single (serial) run mode.\n";
	}
	else
	{
	    print "\tNot limiting search in single (serial) run mode.\n";
	}

    }
    else
    {
	print "\tRunning in multiple run mode (sequentially) by propagating each fault at each turn in alphanumeric order.\n";
	if ($is_limit)
	{
	    print "\tLimiting search in multiple (sequentially) run mode.\n";
	}
	else
	{
	    print "\tNot limiting search in multiple (sequentially) run mode.\n";
	}

    }

    if ($is_topo)
    {
	print "\tUpdating postion of model boundaries.\n";
    }
    else
    {
	print "\tNot updating position of boundaries.\n";
    }

    if ($is_check)
    {
	print "\tRechecking stopped growing tips.\n";
    }
    else
    {
	print "\tNot checking stopped growing tips.\n";
    }

    if ($is_branch)
    {
	print "\tSplitting faults where Coulomb stress > shear strength.\n\n";
    }
    else
    {
	print "\tNot splitting faults where Coulomb stress > shear strength.\n\n";
    }

    # if no faults are propagating and not running the sandbox version
    if (scalar(@fault_names) == 0 && !($run_mode =~ /sand/))
    {
	die "NO FAULTS PROPAGATING: check flags in input file.\n";
    }
    
    # number of iterations of propagation
    my $prop_num = 0;

    # if running a sand box model, if so 
    # find the geometry that minimizes work for the first iteration
    # after this iteration, let GROW function as usual 
    if ($run_mode =~ /sand/)
    {
	# get flaw names, only if not followed by fault propertie
	my @flaw_names = get_flaw_names($prev_filename);

	# if there are flaws propagating in the input file
	if (scalar(@flaw_names) != 0)
	{
	    $prop_num++;

	    # get range of angles: test full circle to test both up and down orientations
	    my @flaw_angles = get_angles(0, 359, $inc_angle);

	    # get a hash table of scenarios to test for the first
	    # iteration
	    my ($flaw_scen_ref, $flaw_scen_num) = get_sequence(\@flaw_names, \@flaw_angles); 
	    my %flaw_scenarios = %$flaw_scen_ref;
	     
	    # execute sequence with $is_sand = 1
	    my ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out_new) = 
		execute ($is_serial, $run_mode, $forecast, 1, $is_check, $is_limit, $is_topo, $prev_work, $inc_angle, $flaw_scen_ref, $prop_num, $is_minimizing, 
			      $prev_filename, $efficient_filename, $eff_file_out, $raw_output,
			      $output_filename, $out_raw_filename, $topo_filename); 

	    if (-e $eff_file_out_new)
	    {
		$eff_file_out = $eff_file_out_new;
	    }

	    if ($is_topo && $eff_file_in && $is_update_topo && !($run_mode =~ /debug/))
	    {
		$topo_filename = update_topo($eff_file_in, $efficient_filename, $topo_filename);
	    }

	    check_flags($efficient_filename);

	    # update the print statements
	    $raw_output = $new_raw_out2; 
	    
	    # add to list of work values to print cumulative summary
	    if ($min_work != -1)
	    {
		push(@works, $min_work);
		push(@works_unnorm, $min_work_unnorm);
	    }	
	    # if no elements slip, use last minimum work (probably better to use min work found in this iteration)
	    else
	    {
		push(@works, $prev_work);
		push(@works_unnorm, $prev_work);
	    }

	    $prev_work = $works_unnorm[-1];

	    # continue to propagate unless the Coulomb criteria was not satisfied
	    # if the criteria was not satisfied, $min_work = -1, 
	    # if no more fauls are growing, $min_work = 0 
	    my $continue_grow = test_prop_many($prev_work, $min_work,
						 0, # critical work value not used 
						 1); # faults will always be growing at this point

	    # if we should not propagate any more
	    # exit execution
	    if (!$continue_grow)
	    {
		print "NO FAILURE ON FLAWS AT SPECIFIED POINT(S). \n";
	    }

	}
	else
	{
	    print "WARNING: Running sandbox, but no Flaws found in input file. \n"; 
	}
    }

    # get range of angles to search for larger search
    my @angle_range = get_angles($start_angle, $end_angle, $inc_angle);

    # get a list of all the faults that are growing     # FORMATTED: fault_name end_growing 
    # at this point, if using sandbox version all *Flaws are written as full fric2d faults now
    # now this will include *Flaws that are growing
    @fault_names = get_fault_names($efficient_filename);

    # test if any faults are propagating
    if (scalar(@fault_names) == 0)
    {
	die "NO FAULTS PROPAGATING: check flags in $efficient_filename \n";
    }

    # if ran sandbox model and faults are still propagating
    # replace fault properties for single element listed
    # with *Flaw-Fault properties
    if ($run_mode =~ /sand/)
    {
	reset_flaw_all($efficient_filename, \@fault_names);
    }


    # get hash of scenarios to test for each iteration of crack growth
    # assumes that all the fault names are fully listed faults in fric2d input file
    # Key: fault name, values: list of angles to check
    my $sequence_ref = get_sequence(\@fault_names, \@angle_range);
    my %sequence = %$sequence_ref;  

    # start growing the fault
    # continue_propagate = 0 when fault intersects 
    # or none of newly added elements are slipping
    my $continue_propagate = 1;
    while ($continue_propagate)
    {
	# increment the number that indicates the
	# step of crack growth
	$prop_num++;
	
	# reset the last input geometry to the most efficient
	# geometry found after adding the last sequential growth sequence
	transfer_file($efficient_filename, $prev_filename);    

	# grow the faults sequentially by minimizing work for individual fault
	# here, GROW always thinks we are not propagating from point
	my ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out_new) = 
	    execute ($is_serial, $run_mode, $forecast, 0, $is_check, $is_limit, $is_topo, $prev_work, $inc_angle, $sequence_ref, $prop_num, $is_minimizing, 
			      $prev_filename, $efficient_filename, $eff_file_out, $raw_output,
			      $output_filename, $out_raw_filename, $topo_filename); 
	
	if (-e $eff_file_out_new)
	{
	    $eff_file_out = $eff_file_out_new;
	}

	# update the print statements
	$raw_output = $new_raw_out2; 

	# add to list of work values to print cumulative summary
	# @works now contains delWext/A values 
	# @works_unnorm, contains Wext values
	push(@works, $min_work); # delWext/delA
	push(@works_unnorm, $min_work_unnorm);
	
	# reset previous work value to normalize work in next iteration
	$prev_work = $works_unnorm[-1];

	
	# test if the end points of any faults intersect, 
	# if true, then set growing flag to "no" in efficient input file
	#if (!$is_check)
	#{
	#check_final_intersections($efficient_filename);	
	#}

	if ($is_topo && $eff_file_in && $is_update_topo && !($run_mode =~ /debug/))
	{
	    $topo_filename = update_topo($eff_file_in, $efficient_filename, $topo_filename);
	}
	
	# get the new list of scenarios to test, in case
	# any faults are intersecting boundary
	# get the name of faults still growing, after checking the intersections
	@fault_names = get_fault_names($efficient_filename); 

	# branch the faults 
	if ($is_branch && -e $eff_file_out_new)
	{
	    my $isb = branch_faults($eff_file_out, \@fault_names);

	    # get the new list of fault names in case we branched any faults
	    if ($isb)
	    {
		my $eff_in = substr($eff_file_out, 0, -4).".in";
		#@fault_names = get_fault_names($eff_in); 

		transfer_file($eff_in, $efficient_filename);
	    }
	}

	# test if any of the growing faults connect with two other fault tips
	# if so, set the flags to now
	check_flags($efficient_filename);
	# get the new list of growing faults
	@fault_names = get_fault_names($efficient_filename); 

	my $eff_prop = $root."P$prop_num.eff";
	transfer_file($efficient_filename, $eff_prop);

	print "Growing faults, from flags in input file: \n";
	foreach(@fault_names)
	{
	    print "$_ \n";
	}

	# update the sequence if any faults are still growing
	$sequence_ref = get_sequence(\@fault_names, \@angle_range);

	# check if  no more faults are growing
	my $if_sequence = 1;
	if (scalar(@fault_names) == 0)
	{
	    $if_sequence = 0;
	}

	# continue to propagate unless the Coulomb criteria was not satisfied
	# if the criteria was not satisfied, $min_work = -1, $min_scenario = -1
	# if no more fauls are growing, $min_work = 0
	$crit_work = 0; 
	$continue_propagate = test_prop_many($prev_work, $min_work,
					     $crit_work, 
					     $if_sequence); 

	

	# print most efficient work values calculated so far
	my $out_stat = "\nCUMULATIVE SUMMARY\n".sprintf("%-10s %-20s %-20s\n", "PROP", "Wext(J)", "delWext/delA (J/m^2)");

	for my $i (0..$#works)
	{
	    my $label = $i;

	    if ($i == 0)
	    {
		$label = "Initial";
		# normalized value of initial work not reported
		$works[0] = 'N/A'; 
	    }
	    # if most efficient work not found because no failure
	    elsif ($works[$i] == -1)
	    {
		$works[$i] = $works[$i-1];;
	    }
	
	    $out_stat = $out_stat.sprintf("%-10s %-20s %-20s\n", $label, $works_unnorm[$i], $works[$i]);
	}
	
	$out_stat = $out_stat."\n";
	print "$out_stat";
	$raw_output = $raw_output.$out_stat;
	write_output($out_raw_filename, $raw_output);	

	# for testing purposes
	#if ($prop_num == 2)
	#{
	#    print "done two steps\n";
	#    die;
	#}

	# if we will continue to grow faults
	if ($continue_propagate)
	{
	    %sequence = %$sequence_ref; 
	    
	    # reset the previous work of the system 
	    # to the minimum work found at this iteration
	    $prev_work = $works_unnorm[-1];	  

	    if ($prop_num == 5 && $run_mode =~ 'debug')
	    {
		die;
	    }

	    # restart the program to clear memory if propagated 9 times
	    if ($prop_num == 9)
	    {
		# copy contents of .eff to file named "next_filename"
		transfer_file($efficient_filename, $restart_filename);
		my $out = "\nRESTARTING PROCESS TO FREE MEMORY\n\tRECORDING: $efficient_filename \n\tAND CONTINUING WITH: $restart_filename \n";
		print $out; 
		$raw_output = $raw_output.$out;
		write_output($out_raw_filename, $raw_output);

		# set the new input file to the most efficient file found during the last iteration
		$ARGV[0] = $restart_filename;

		# if there is a topography file, reset it to one with modfied boundaries
		if ($is_topo && $topo_filename && $is_update_topo)
		{
		    $ARGV[4] = $topo_filename;
		}

		# remember unnormalized work calculated for this file, so we don't recalculate in next iteration
		push(@ARGV, $min_work_unnorm); 
		my $formatted = join("\t", @ARGV);
		print "PASSING INPUT ARGUMENTS\n\t$formatted\n";

		exec($^X, $0, @ARGV);
	    }
	}
	else
	{
	    print "EFFICIENT FILE: $efficient_filename\n";
	}
    }
}

# FUNCTIONS TO MODIFY FRI2D INPUT FILES
# set flags in input file to stop growing of a fault
sub stop_grow; 
# generate FRIC2D input file with 1 new element
sub make_input_file;
# make the input file that describes this scenario, with multiple faults
sub make_input_file_scenario;

# FUNCTIONS TO CALCULATE WORK
# get the work of the system
sub calc_work;
# run FRIC2D
sub run_FRIC2D;
# run the sandbox version of FRIC2D
sub run_sandbox; 
# calculate external work
sub get_work;
# removes from hash table any scenario that does not contain slipping pupative element
sub remove_not_slipping_ineff; 
sub remove_not_slipping_many;

# function that returns work value normalized by length of
# propagating fault in the input file
sub normalize_work;

# get max and min of list of numbers
#sub max;
#sub min;

# counter number of possible strucutres an element tip bay intersect with
# 2*number of faults + number of boundary segments
sub get_intersect_structs;

sub execute_serial; # propagate faults serially
sub execute_sequence; # propagate faults sequentially

sub execute
{
    my ($is_serial, $run_mode, $forecast, $is_sand, $is_check, $is_limit, $is_topo, $prev_work, $inc_angle, $sequence_ref, $prop_num,
	$is_min,
	$prev_filename, $efficient_filename, $eff_file_out,
	$raw_output,
	$output_filename, $out_raw_filename, 
	$topo_filename) = @_;

    if ($is_serial)
    {
	my ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out) = 
	    execute_serial ($run_mode, $forecast, $is_sand, $is_check, $is_limit, $is_topo, $prev_work, $inc_angle, $sequence_ref, $prop_num, $is_min, 
			      $prev_filename, $efficient_filename, $eff_file_out, $raw_output,
			      $output_filename, $out_raw_filename, $topo_filename); 
	return ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out);
    }
    else
    {
	my ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out) = 
	    execute_sequence ($run_mode, $forecast, $is_sand,  $is_check, $is_limit, $is_topo, $prev_work, $inc_angle, $sequence_ref, $prop_num, $is_min, 
			      $prev_filename, $efficient_filename, $eff_file_out, $raw_output,
			      $output_filename, $out_raw_filename, $topo_filename); 
	return ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in, $eff_file_out);
    }
    
}

sub get_top_faults;

# grow the faults serially by minimizing work for growth from all faults
# called:  
# 	my ($min_work_unnorm, $min_work, $new_raw_out2, $eff_file_in) = 
#	    execute_serial ($run_mode, $forcast, $is_sand, $prev_work, $angle_inc, $sequence_ref, $prop_num, $is_minimizing, 
#			      $prev_filename, $efficient_filename, $raw_output,
#			      $output_filename, $out_raw_filename, $topo_filename); 

# input:  what program to execute (fric, sand, debug), 
#        bool = true if growing from point, false otherwise
#        angle increment of first general search
#        reference to sequence hash table fault name => list of angles to search
#        number of current iteration of crack growth
#        if we are minimizing work (true), false if otherwise
#        name of previous file, and the most efficient file found so far (?)
#        current string that represents the raw output
#        name of output filename, raw_output filename and topography filename
#             topo filename may not exist
# output: minimum Wext, minimum delWext/A
sub execute_serial
{
    my ($run_mode, $forecast, $is_sand, $is_check, $is_limit, $is_topo, $prev_prop_work, $angle_inc, $sequence_ref, $prop_num,
	$is_min,
	$prev_filename, $efficient_filename, $eff_file_out,
	$raw_output,
	$output_filename, $out_raw_filename, 
	$topo_filename) = @_;

    my %sequence = %$sequence_ref; 
    my $root = substr($efficient_filename, 0, -4);

    # hash table to remember efficient angle found for this fault
    my %eff_fault_angle;

    my $print_screen_summary; 
    my $curr_eff = 1e20;
    my $curr_work = 1e20; 
    # final work of the system to return after testing all orientations
    my $final_work = 0;
    # final unnormalized work
    my $final_work_unnorm = 0;

    # work of previous propagation of growth
    #my $prev_prop_work = $prev_work;

    # preserve the contents of the previous input file before sequential growth
    # to use in the linear growth later
    my $seq_filename; 
    # remember the contents of this file for the tuning step
    # to normalize work by the fault length added within the entire propagation sequence
    my $prev_prop_filename = $prev_filename."_seq";
    transfer_file($prev_filename, $prev_prop_filename);

    # limit propagation to faults with K1 or K2 within 10% of max
    if ($is_limit && !($run_mode =~/debug/))
    {
	print "Finding high K in: $eff_file_out \n";

	# if this does not exist, then make the file
	if (!(-e $eff_file_out))
	{
	    my $w = calc_work($run_mode, $prev_filename, 
			       $eff_file_out, $topo_filename); 
	}

	my $seq_ref = get_top_faults($sequence_ref, $eff_file_out);
	my %seq_new = %$seq_ref;
	if (keys %seq_new)
	{
	    print "Restricting growth.\n";
	    %sequence = %seq_new;
	}

    }


    # for all the faults and angles
    my @input_args = ();
    my @file_inter = ();
    my %cond_nums;
    my %opt_works;
    # for each fault listed in sequence hash table
    # these keys MUST be sorted or else the incorrect scenarios will be removed as duplicated
    for my $fault (sort keys %sequence)
    {
	my $formatted_fault = $fault;
	$formatted_fault =~ s/\s/_/;

	# get the angles to test for this fault
	my @angles = @{$sequence{$fault}}; 

	foreach (@angles)
	{
	    my $angle = $_;
	    
	    # make the testing filename (fric2d input and output files)
	    my $testing_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".in";
	    my $fric_output_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".out";
	    
	    # create the hash table that describes this scenario
	    my $pair_ref = {$fault => $angle} ;	    	    

	    # make the input file that represents this scenario at $testing_filename 
	    make_input_file_scenario($prev_filename, $testing_filename, 
				     $pair_ref, $is_sand);	    

	    # get number of structures that could be possibly intersecting
	    my $structure_num = get_intersect_structs($testing_filename);
	    my $fault_intersect = correct_intersections($testing_filename, $pair_ref, 0, $structure_num);

	    if ($fault_intersect>=0)
	    {	
		#check_single($testing_filename);

	        #push(@outputs, $fric_output_filename)
		my $data = $testing_filename." ".$fric_output_filename." ".$angle;
		push(@input_args, $data);

		if ($fault_intersect>0)
		{
		    push(@file_inter, $testing_filename);
		}
	    }
	    else
	    {
		print "Could not correct intersections in: $testing_filename \n";
	    }
	    
	} # end of loop making the input files for elements at new angles to one (currently growing) fault

    } # end loop for all faults

    my %file_work = ();
    my %file_work_unnorm = ();

    # fork the processes, if any runnable input files (not intersecting faults)
    if (scalar(@input_args))
    {
	# limit the number of processes forked to 20 at a time
	my $lim = 16; # may change

	my $i=0;
	while ($i<scalar(@input_args))
	{
	    my $end = $i+$lim;
	    if ($end >= scalar(@input_args)) 
	    {
		$end = scalar(@input_args)-1;
	    }

	    my @input_temp = @input_args[$i..$end];
	    $i = $end+1;


	    if (!($run_mode =~ /debug/))
	    {	    
		my $max_workers = scalar(@input_temp);
		my $pm = new Parallel::ForkManager($max_workers);

		foreach my $input_line (@input_temp)
		{
		    my @args = split(' ', $input_line);
			
		    my $input = $args[0];
		    my $output = $args[1];
		    my $ang = $args[2];
		    
		    print "STARTING RUN OF: ".$input." \n";
			
		    my $pid = $pm->start and next; # start process, and next skips internal loop
		    
		    # run fric2d or sandbox
		    run_code($run_mode, $input, $output, $topo_filename);
		    
		    $pm->finish; # terminates child process
		}
		    
		$pm->wait_all_children; # wait for all the children to finish running
		#sleep 10; # pause for some time
		
		print "COMPLETED SET OF RUNS----------\n";
		
	    }
	    
	    
	}

	# now get Wext from all output files
	foreach my $input_line (@input_args)
	{
	    my @args = split(' ', $input_line);

	    my $input = $args[0];
	    my $output = $args[1];
	    my $ang = $args[2];	    

	    # get work from output files
	    my $curr_work = get_work($run_mode, $output); 

	    if ($curr_work)
	    {
		my $cond_n = get_cond_num($run_mode, $output);
		$cond_nums{$input} = $cond_n;
		$opt_works{$input} = $curr_work;

		my $curr_work_unnorm = $curr_work;
		$curr_work = normalize_work($prev_prop_work, $curr_work, $input, $prev_prop_filename); 

		$file_work{$input} = $curr_work;
		$file_work_unnorm{$input} = $curr_work_unnorm;

		my @parts = split('_', substr($input, 0, -3));
		my $fault = $parts[-3]." ".$parts[-2];
		# print statement
		my $result = "$curr_work_unnorm\t$curr_work";
		my $print_screen_summary = format_std_out($output, 
							  $prop_num, $result, $fault, $ang);
		$raw_output = $raw_output.$print_screen_summary;
		write_output($out_raw_filename, $raw_output);
	    }
	    else
	    {
		print "WARNING: Could not calculate work for geometry in output file: ".$output."\n";
	    }
	}

    } # done running all input files, for each fault and each angle

    # if hash table is empty, then one fault intersects at all orientations 
    # when faults intersection work = 0
    my $inter_self = 0;
    if (!%file_work)
    {
	$inter_self = 1;
    }

    # remove scenarios from the hash table if the element(s) that were just added
    # are not slipping if we are not using debug mode (which will not produce 
    # .out files
    # save all the work calculations for the summary output
    my @not_slipping_faults = (); # do not stop growth prematuraly, allow others to continue #####################
    if (!($run_mode =~ /debug/) && !$inter_self) # && !$is_check)
    {    
	(my $ref, %file_work_unnorm) = remove_not_slipping_many(\%file_work_unnorm);
	@not_slipping_faults = @$ref;
    }
    else
    {
	print "Not removing non-slipping elements. \n";
    }
	
    my $eff_angle = -1; # used to be -1
    my $eff_work = '';
    my $eff_work_unnorm = 0;
    my $eff_fault = '';
    my $eff_file = '';
    my $formatted_fault = ''; # only create this if found efficient fault

    # for now do not stop growth
    # if there are faults that are not slipping, stop growth
    if (!%file_work_unnorm)
    {
	if (!$is_check)
	{
	    # for each of the faults not slipping 
	    foreach (@not_slipping_faults)
	    {
		my $fault = $_;
		# change the flags in the previous input file so correct fault is not growing
		# and so the next iteration uses this input file
		stop_grow($prev_filename, $fault); 

		# stop growth in efficient filename as well, so that 
		# new propagation knows that fault stopped in case not slipping
		# fault is last to grow fault
		stop_grow($efficient_filename, $fault); 

		# stop growth in previous propagation file, because this used in tuning
		stop_grow($prev_prop_filename, $fault); 

		# notify user/raw output that fault not growing anymore
		my $out = "\nNO SLIP, STOPPING GROWTH IN $fault\n";
		# signal to not copy files
		$eff_angle = -2;
		# if all orientations tested intersect that fault
		if ($inter_self)
		{
		    $out = "\nALL NEW ELEMENTS ADDED INTERSECT SAME FAULT\n\tFAULT AND END: $fault \n\tSTOPPING GROWTH\n";
		    $eff_angle = -3;
		}
		
		print $out; 
		$raw_output = $raw_output.$out; 
		write_output($out_raw_filename, $raw_output);
	    }
	}
	
    }
    # at least one added fault-element is slipping, find max delWext/A value
    else
    {
	my %valid_works = %file_work_unnorm; # should be Wext

	# find fault with most efficient angle	       
        ($eff_file, $eff_work) = get_opt_scenario($prev_prop_work, \%valid_works, \@file_inter, \%cond_nums, $is_min, $is_topo); 

	# if efficient file found
	if (-e $eff_file)
	{
	    $eff_work_unnorm = $file_work_unnorm{$eff_file};
	    $eff_work = $file_work{$eff_file}; ##
	    # get efficient angle and fault from the filename
	    my @parts = split('_', substr($eff_file, 0, -3));
	    $eff_angle = $parts[-1];
	    $eff_fault = $parts[-3]." ".$parts[-2]; 
	    $formatted_fault = $parts[-3]."_".$parts[-2]; # most efficient fault tip growin

	}

	# if forecasting
	if ($forecast)
	{
	    # make forecast_works only the work for the most efficient fault
	    my %forecast_works = ();
	    # get work values that only match the most efficient fault (and tip)
	    # remove the orienations that produce negative work
	    foreach my $file (sort keys %file_work_unnorm)
	    {
		# if file contains efficient fault name
		if ($file =~ /$formatted_fault/)
		{
		    my $curr_w = $file_work_unnorm{$file};
		    # get angle
		    # get fault
		    my @parts = split('_', substr($file, 0, -3));
		    my $angle = $parts[-1];
		    $forecast_works{$angle} = $curr_w;       
		}
	    }

	    print "FORECASTING ON EFFICIENT FAULT: $eff_fault\n";
	    print "\tAngle Wext \n";
	    foreach my $ang (sort {$a<=>$b} keys %forecast_works)
	    {
		my $work = $forecast_works{$ang};
		print "\t$ang\t$work\n";
	    }

	    ($eff_angle, $eff_work, $eff_work_unnorm) = get_wext_forecast(\%forecast_works, $forecast, $is_min, 
									  $root, $prop_num, $formatted_fault,
									  $eff_fault,	$prev_filename, $topo_filename, 
									  $raw_output, $out_raw_filename,
									  $prev_prop_work, $prev_prop_filename, $is_sand, $run_mode);

	    $eff_file = $root.'_'.$prop_num.'_'.$formatted_fault.'_'.$eff_angle.'.in';

	    $file_work_unnorm{$eff_file} = $eff_work_unnorm;
	    $file_work{$eff_file} = $eff_work;
	}
    }

    # if we calculated the work for a scenario
    # there was at least one good/not intersecting geometry (angle != -1) 
    # and one of the newly added elements is slipping (angle != -2)
    if ($eff_angle > -1) 
    {
	$seq_filename = $eff_file; 
	
	#  copy the appropriate files to the scenario that minimizes work
	transfer_file($seq_filename, $efficient_filename);
	
	# reset the last input geometry to the most efficient
	# geometry found after adding the last sequential growth sequence
	transfer_file($efficient_filename, $prev_filename);

	$eff_file_out = substr($eff_file, 0, -2)."out";

	# remember fault name and minimum angle 
	$eff_fault_angle{$eff_fault} = $eff_angle;
	
	$final_work = $eff_work;
	$final_work_unnorm = $eff_work_unnorm; 
	
	# used to normalize by work calculated after adding last element
	# now normalize by work of previous propagation
	#$prev_work = $final_work_unnorm; 
    }
    # if none of the elements added to this fault is slipping
    elsif ($eff_angle == -2)
    {
	# print statements
	$eff_angle = "No angle found because no added elements slipped or efficient";
    }
    elsif ($eff_angle == -3)
    {
	$eff_angle = "No angle found because all added elements intersect same fault";
    }
    
    # for each fault in model
    # get work value at each angle
    for my $fault_curr (sort keys %sequence)
    {
	my $formatted_fault = $fault_curr;
	$formatted_fault =~ s/\s/_/;

	my %all_faults_unnorm = ();
	my %all_faults = ();
	my $work_opt = -1e30; # if maximizing
	if ($is_min)
	{
	    $work_opt = 1e30; # if minimizing
	}

	my $eff_angle_curr = 0;
	foreach my $file (keys %file_work_unnorm)
	{
	    # if file contains efficient fault name
	    if ($file =~ /$formatted_fault/)
	    {
		my $work_unnorm = $file_work_unnorm{$file};
		my $work = $file_work{$file};
		# get angle
		# get fault
		my @parts = split('_', substr($file, 0, -3));

		my $angle = $parts[-1];
		$all_faults_unnorm{$angle} = $work_unnorm;
		$all_faults{$angle} = $work;
		if (($is_min && $work < $work_opt) || (!$is_min && $work > $work_opt))
		{
		    $work_opt = $work;
		    $eff_angle_curr = $angle;
		}
	    }	    
	}

	# print out all angle, work calculated for this fault
	$raw_output = $raw_output.print_work_summary(1, "PROPAGATION: $prop_num \nSUMMARY FOR FAULT AND END: $fault_curr\n\tEFFICIENT ANGLE: $eff_angle_curr\n", 
						     \%all_faults_unnorm, \%all_faults); 
	write_output($out_raw_filename, $raw_output);
	
    }

    # if final work not zero, then value has been found
    if ($final_work != 0)
    {
	$raw_output = $raw_output.print_work_summary(0, "BEFORE TUNING PROPAGATION: $prop_num \nMOST EFFICIENT delWext/delA (J/m^2): $final_work \nGEOMETRY IN FILE: $eff_file \n",  \%eff_fault_angle); 
	write_output($out_raw_filename, $raw_output);

	# RUN TUNING ALGORITHM, only if not forecasting
	if (!$forecast)
	{
	    ($final_work_unnorm, $final_work, my $raw_output_2, $seq_filename, $eff_file_out) = 
		tune_angles($final_work_unnorm, $final_work, $prev_prop_work, 
			    \%eff_fault_angle, $seq_filename, $angle_inc/2,
			    $run_mode, $forecast, $is_sand, $is_check, $is_topo, $prop_num, $is_min, 
			    $prev_prop_filename, $efficient_filename, $eff_file_out,
			    $raw_output,$output_filename, $out_raw_filename, $topo_filename);
	    
	    $raw_output = $raw_output_2; 
	}

    }
    # if no more faults are growing (none of the added elements are slipping)
    # so final, most efficient work not found for all faults
    else
    {
	my $out = "\nPROPAGATION: $prop_num \nNO MORE FAULTS ARE GROWING, SO DID NOT CHECK TUNED ANGLES\n"; 
	print $out;
	$raw_output = $raw_output.$out; 
	write_output($out_raw_filename, $raw_output);
	# signal that no more faults are growing
	$final_work = -1; 
       
    }

    # return minimum work for all the scenarios tested
    return ($final_work_unnorm, $final_work, $raw_output, $seq_filename, $eff_file_out); 

}

# grow the faults sequentially by minimizing work for individual faults
sub execute_sequence
{
    my ($run_mode, $forecast, $is_sand, $is_check, $is_limit, $is_topo, $prev_prop_work, $angle_inc, $sequence_ref, $prop_num,
	$is_min,
	$prev_filename, $efficient_filename, $eff_file_out,
	$raw_output,
	$output_filename, $out_raw_filename, 
	$topo_filename) = @_;

    my %sequence = %$sequence_ref; 
    my $root = substr($efficient_filename, 0, -4);

    # limit propagation to faults with K1 or K2 within 10% of max
    if ($is_limit && !($run_mode =~/debug/))
    {
	print "Finding high K in: $eff_file_out \n";

	# if this does not exist, then make the file
	if (!(-e $eff_file_out))
	{
	    my $w = calc_work($run_mode, $prev_filename, 
			       $eff_file_out, $topo_filename); 
	}

	my $seq_ref = get_top_faults($sequence_ref, $eff_file_out);
	my %seq_new = %$seq_ref;
	if (keys %seq_new)
	{
	    print "Restricting growth.\n";
	    %sequence = %seq_new;
	}

    }


    # hash table to remember efficient angle found for this fault
    my %eff_fault_angle;

    my $print_screen_summary; 
    my $curr_eff = 1e20;
    my $curr_work = 1e20; 
    # final work of the system to return after testing all orientations
    my $final_work = 0;
    # final unnormalized work
    my $final_work_unnorm = 0;

    # work of previous propagation of growth
    #my $prev_prop_work = $prev_work;

    # preserve the contents of the previous input file before sequential growth
    # to use in the linear growth later
    my $seq_filename; 
    # remember the contents of this file for the tuning step
    # to normalize work by the fault length added within the entire propagation sequence
    my $prev_prop_filename = $prev_filename."_seq";
    transfer_file($prev_filename, $prev_prop_filename);

    # for each fault listed in sequence hash table
    # these keys MUST be sorted or else the incorrect scenarios will be removed as duplicated
    for my $fault (sort keys %sequence)
    {
	my $out = "\nPROPAGATION: $prop_num \nTESTING ANGLES FOR FAULT AND END: $fault \n\n";
	print $out; 
	$raw_output = $raw_output.$out;
	write_output($out_raw_filename, $raw_output);

	my $formatted_fault = $fault;
	$formatted_fault =~ s/\s/_/;

	# get the angles to test for this fault
	my @angles = @{$sequence{$fault}}; 

	# for each angle listed in this key
	my @input_args = ();
	my @ang_inter = ();
	my %cond_nums;
	my %opt_works;
	foreach (@angles)
	{
	    my $angle = $_;
	    
	    # make the testing filename (fric2d input and output files)
	    my $testing_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".in";
	    my $fric_output_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".out";
	    
	    # create the hash table that describes this scenario
	    my $pair_ref = {$fault => $angle} ;	    	    

	    # make the input file that represents this scenario at $testing_filename 
	    make_input_file_scenario($prev_filename, $testing_filename, 
				     $pair_ref, $is_sand);	    

	    # get number of structures that could be possibly intersecting
	    my $structure_num = get_intersect_structs($testing_filename);
	    my $fault_intersect = correct_intersections($testing_filename, $pair_ref, 0, $structure_num);

	    if ($fault_intersect>=0)
	    {	
		#check_single($testing_filename);

	        #push(@outputs, $fric_output_filename)
		my $data = $testing_filename." ".$fric_output_filename." ".$angle;
		push(@input_args, $data);

		if ($fault_intersect>0)
		{
		    push(@ang_inter, $angle);
		}
	    }
	    else
	    {
	        print "Could not correct intersections in: $testing_filename \n";
	    }
	    
	} # end of loop making the input files for elements at new angles to one (currently growing) fault

	# hash table to store work calculated for this fault
	# angle => normalized work pairs
	my %this_fault = ();
	# angle => unnormalized work
	my %this_fault_unnorm = ();
	my %this_file = ();

	# fork the processes, if any runnable input files (not intersecting faults)
	if (scalar(@input_args))
	{

	    # limit the number of processes forked to 20 at a time
	    my $lim = 16; # may change

	    my $i=0;
	    while ($i<scalar(@input_args))
	    {
		my $end = $i+$lim;
		if ($end >= scalar(@input_args))
		{
		    $end = scalar(@input_args)-1;
		}

		my @input_temp = @input_args[$i..$end];
		$i = $end+1;

		if (!($run_mode =~ /debug/))
		{
			my $max_workers = scalar(@input_temp);
			my $pm = new Parallel::ForkManager($max_workers);

			foreach my $input_line (@input_temp)
			{
			    my @args = split(' ', $input_line);

			    my $input = $args[0];
			    my $output = $args[1];
			    my $ang = $args[2];

			    print "STARTING RUN OF: ".$input." \n";

			    my $pid = $pm->start and next; # start process, and next skips internal loop
			    
			    # run fric2d or sandbox
			    run_code($run_mode, $input, $output, $topo_filename);

			    $pm->finish; # terminates child process
			}
			
			$pm->wait_all_children; # wait for all the children to finish running
			#sleep 10;

			print "COMPLETED SET OF RUNS----------\n";
		    }
		}

	    # now get Wext from all output files
	    foreach my $input_line (@input_args)
	    {
		my @args = split(' ', $input_line);

		my $input = $args[0];
		my $output = $args[1];
		my $ang = $args[2];		

		# get work from output files
		my $curr_work = get_work($run_mode, $output); 

		my $curr_work_unnorm = $curr_work;
		$curr_work = normalize_work($prev_prop_work, $curr_work, $input, $prev_prop_filename); 

		my $cond_n = get_cond_num($run_mode, $output);
		$cond_nums{$ang} = $cond_n;
		$opt_works{$input} = $curr_work_unnorm;

		# record work in hash table for this fault
		$this_fault{$ang} = $curr_work; 
		# record index and filename in hash table
		$this_file{$ang} = $output; 	
		$this_fault_unnorm{$ang} = $curr_work_unnorm;

		# print statement
		my $result = "$curr_work_unnorm\t$curr_work";
		my $print_screen_summary = format_std_out($output, 
							  $prop_num, $result, $fault, $ang);
		$raw_output = $raw_output.$print_screen_summary;
		write_output($out_raw_filename, $raw_output);
	    }

	}

	# if hash table is empty, then one fault intersects at all orientations 
	# when faults intersection work = 0
	my $inter_self = 0;
	if (!%this_fault)
	{
	    $inter_self = 1;
	}
	
	my %all_faults_unnorm = %this_fault_unnorm;
	my %all_faults = %this_fault; 
	my %forecast_works = %this_fault; 
	
	# remove scenarios from the hash table if the element(s) that were just added
	# are not slipping if we are not using debug mode (which will not produce 
	# .out files
	# save all the work calculations for the summary output
	if (!($run_mode =~ /debug/) && !$inter_self) # && !$is_check)
	{    
	    #%this_fault = remove_not_slipping_ineff($is_min, \%this_file, \%this_fault); # remove from this_fault_unnorm instead
	    %this_fault_unnorm = remove_not_slipping_ineff($is_min, \%this_file, \%this_fault_unnorm);
	}
	
	my ($eff_angle, $eff_work) = ();
	my $eff_work_unnorm = 0;

	# if hash is empty after removing non-slipping scenarios
	# then work = -1
	# then signal that all elements not slipping, but continue to test the other faults
	if (!%this_fault && !$is_check)
	{
	    # change the flags in the previous input file so correct fault is not growing
	    # and so the next iteration uses this input file
	    stop_grow($prev_filename, $fault); 

	    # stop growth in efficient filename as well, so that 
	    # new propagation knows that fault stopped in case not slipping
	    # fault is last to grow fault
	    stop_grow($efficient_filename, $fault); 

	    # stop growth in previous propagation file, because this used in tuning
	    stop_grow($prev_prop_filename, $fault); 

	    # notify user/raw output that fault not growing anymore
	    my $out = "\nNO SLIP, FAULT AND END: $fault \n\tSTOPPING GROWTH\n";
	    # signal to not copy files
	    $eff_angle = -2;
	    # if all orientations tested intersect that fault
	    if ($inter_self)
	    {
		$out = "\nALL NEW ELEMENTS ADDED INTERSECT SAME FAULT\n\tFAULT AND END: $fault \n\tSTOPPING GROWTH\n";
		$eff_angle = -3;
	    }

	    print $out; 
	    $raw_output = $raw_output.$out; 
	    write_output($out_raw_filename, $raw_output);

	}
	# at least one added element is slipping
	else
	{
	    my %valid_works = %this_fault_unnorm;
	    # remove the orienations that produce negative work
	    foreach my $angle (keys %this_fault_unnorm)
	    {
		my $curr_w = $this_fault_unnorm{$angle};
		if ($curr_w < 0)
		{
		    delete $valid_works{$angle};
		}
	    }

	    # if forecasting
	    if ($forecast)
	    {
		($eff_angle, $eff_work, $eff_work_unnorm) = get_wext_forecast(\%forecast_works, $forecast, $is_min, 
									      $root, $prop_num, $formatted_fault,
									      $fault,	$prev_filename, $topo_filename, 
									      $raw_output, $out_raw_filename,
									      $prev_prop_work, $prev_prop_filename, $is_sand, $run_mode);
		$all_faults_unnorm{$eff_angle} = $eff_work_unnorm;
		$all_faults{$eff_angle} = $eff_work;
	    }
	    # if not forecasting, finding absolute min/max Wext
	    else
	    {		
		($eff_angle, $eff_work) = get_opt_scenario($prev_prop_work, \%valid_works, \@ang_inter, \%cond_nums, $is_min, $is_topo); 
		$eff_work_unnorm = $this_fault_unnorm{$eff_angle};
	    }
	}
	
	# if we calculated the work for a scenario
	# there was at least one good/not intersecting geometry (angle != -1) 
	# and one of the newly added elements is slipping (angle != -2)
	if ($eff_angle > -1) 
	{
	    $seq_filename = $root."_".$prop_num."_".$formatted_fault."_".$eff_angle.".in";
	    
	    #  copy the appropriate files to the scenario that minimizes work
	    transfer_file($seq_filename, $efficient_filename);
	    
	    # reset the last input geometry to the most efficient
	    # geometry found after adding the last sequential growth sequence
	    transfer_file($efficient_filename, $prev_filename);

	    # remember fault name and minimum angle 
	    $eff_fault_angle{$fault} = $eff_angle;
	    
	    $final_work = $this_fault{$eff_angle}; # delWext/delA
	    $final_work_unnorm =  $this_fault_unnorm{$eff_angle}; #_unnorm; # Wext

	    $eff_file_out = substr($seq_filename, 0, -2)."out";

	    # used to normalize by work calculated after adding last element
	    # now normalize by work of previous propagation
	    #$prev_work = $final_work_unnorm; 
	}
	# if none of the elements added to this fault is slipping
	elsif ($eff_angle == -2)
	{
	    # print statements
	    $eff_angle = "No angle found because no added elements slipped or efficient";
	}
	elsif ($eff_angle == -3)
	{
	    $eff_angle = "No angle found because all added elements intersect same fault";
	}

	# print out all angle, work calculated for this fault
	$raw_output = $raw_output.print_work_summary(1, "PROPAGATION: $prop_num \nSUMMARY FOR FAULT AND END: $fault\n\tEFFICIENT ANGLE: $eff_angle\n", 
						     \%all_faults_unnorm, \%all_faults); 
	write_output($out_raw_filename, $raw_output);

    } # close loop of each fault, 
    # at this point work calculated for each angle for each fault

    # if final work not zero, then value has been found
    if ($final_work != 0)
    {
	$raw_output = $raw_output.print_work_summary(0, "BEFORE TUNING PROPAGATION: $prop_num \nMOST EFFICIENT delWext/delA (J/m^2): $final_work \nGEOMETRY IN FILE: $seq_filename \n",  \%eff_fault_angle); 
	write_output($out_raw_filename, $raw_output);
		
	# RUN TUNING ALGORITHM, only if not forecasting
	if (!$forecast)
	{
	    ($final_work_unnorm, $final_work, my $raw_output_2, $seq_filename, $eff_file_out) = 
		tune_angles($final_work_unnorm, $final_work, $prev_prop_work, 
			    \%eff_fault_angle, $seq_filename, $angle_inc/2,
			    $run_mode, $forecast, $is_sand, $is_check, $is_topo, $prop_num, $is_min, 
			    $prev_prop_filename, $efficient_filename,  $eff_file_out,
			    $raw_output,$output_filename, $out_raw_filename, $topo_filename);
	    
	    $raw_output = $raw_output_2; 
	}

    }
    # if no more faults are growing (none of the added elements are slipping)
    # so final, most efficient work not found for all faults
    else
    {
	my $out = "\nPROPAGATION: $prop_num \nNO MORE FAULTS ARE GROWING, SO DID NOT CHECK TUNED ANGLES\n"; 
	print $out;
	$raw_output = $raw_output.$out; 
	write_output($out_raw_filename, $raw_output);
	# signal that no more faults are growing
	$final_work = -1; 
       
    }

    # return minimum work for all the scenarios tested
    return ($final_work_unnorm, $final_work, $raw_output, $seq_filename, $eff_file_out); 

}

# determine if two hash tables are equal
sub is_hash_equal; 
# get the angles to test in the tuning sequence 
sub get_tuned_sequence;

# called:     ;
# 	($final_work_unnorm, $final_work, my $raw_output_2) = 
#	    tune_angles($final_work_unnorm, $final_work, $prev_work, \%eff_fault_angle, $seq_filename, $angle_inc/2,
#			$run_mode, $is_sand, $prop_num, $is_min, 
#			$prev_filename_sequence, $efficient_filename, 
#			$raw_output,$output_filename, $out_raw_filename, $topo_filename);
# input: most efficient work calculated in last iteration
#        reference to hash of most efficient geometry found so dar
#        filename of most efficient input file
#        angle increment to search away from most efficient orientation
#        other variables: see above function for description
# output: most efficient work found in this iteration or last iteration
sub tune_angles
{
    # for each fault listed in the sequence hash table
       # find the minimum angle of the list of angles given
       # change current .eff to .prev, set new .prev to corresponding input file
       # remember this minimum angle and fault in hash table
    
    my ($prev_work_unnorm, $prev_work, $prev_prop_work_unnorm, $fault_angle_ref, $seq_filename, $angle_inc,
	$run_mode, $forecast, $is_sand, $is_check, $is_topo, $prop_num, $is_min,
	$prev_prop_filename, $efficient_filename, $eff_file_out, $raw_output,
	$output_filename, $out_raw_filename, $topo_filename) = @_;

    # do not forecast/interpolate between values of wext
    $forecast = 0;

    my $root = substr($efficient_filename, 0, -4)."_tune"; 

    my $print_screen_summary; 
    my $curr_eff = 1e20;
    my $curr_work = 1e20; 
    # most efficient work found in first and tuning sequence
    # set to the previous work in case most efficient work not found in tuning sequence
    my $final_work = $prev_work;
    my $final_work_unnorm = $prev_work_unnorm;	

    # get the sequence of angles to test for all faults
    my %testing_sequences = get_tuned_sequence($fault_angle_ref, $angle_inc);   

    # if no testing sequences found, because none of the faults are now growing
    if (!%testing_sequences)
    {
	my $out = "\nTUNING PROPAGATION $prop_num \n\tNO FAULTS GROWING \n";
	$raw_output = $raw_output.$out;
	write_output($out_raw_filename, $raw_output);
	return ($final_work, $raw_output); 
    }

    # most efficient geometry found thus far
    my %efficient_geometry = %$fault_angle_ref;
  
    #my @file_inter = ();
    # for each fault listed in sequence hash table
    # these keys MUST be sorted or else the incorrect scenarios will be removed as duplicated
    for my $fault (sort keys %testing_sequences)
    {
	my $formatted_fault = $fault;
	$formatted_fault =~ s/\s/_/;

	# get the angles to test for this fault
	my @angles = @{$testing_sequences{$fault}};
	# get the angles to fix for the other faults: whatever the most efficient hash table holds
	my %testing_geometry = %efficient_geometry;
	# remove the fault from the hash table that records the geometry that we are testing
	delete $testing_geometry{$fault};

	my @ang_inter = ();
	# for each angle listed in this key, which includes opt-inc/2, opt, opt+inc/2
	my @input_args = ();
	my %cond_nums;
	my %opt_works;
	foreach (@angles)
	{
	    my $angle = $_;
	    
	    # make the testing filename (fric2d input and output files)
	    my $testing_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".in";
	    my $fric_output_filename = $root."_".$prop_num."_".$formatted_fault."_".$angle.".out";
	    
	    # create the hash table that describes this scenario
	    # from the efficient hash table, and whatever angle testing during this iteration	    	    
	    $testing_geometry{$fault} = $angle;

	    # print the testing geometry
	    my $out = "\nTUNING PROPAGATION $prop_num \n";
	    $raw_output = $raw_output.$out;
	    write_output($out_raw_filename, $raw_output);

	    $out = $out."TESTING GEOMETRY\n".sprintf("\t%-10s %-10s\n", "Fault", "Angle");
	    foreach my $fault (sort keys %testing_geometry)
	    {
		$out = $out.sprintf("\t%-10s %-10s\n", $fault, $testing_geometry{$fault}); 
	    }

	    $out = $out."\n";
	    print $out; 

	    # if the testing geometry == the efficient geometry, use the efficient 
	    # geometry from the previous function, because the efficient scenario here will be 
	    # (i.e. we already tested this combination, then don't recalculate work)
	    my $previously_tested = is_hash_equal(\%testing_geometry, $fault_angle_ref);

	    # if a fault intersects itself
	    my $fault_intersect = 0;
	    # if this geometry has not been previously tested, then make the input file
	    if (!$previously_tested)
	    {

		# for all the keys in the testing geometry
		# build input file with 1 new element added to previously tested
		# test for intersections with 1 element
		# set testing file as previous file to add subsequent elements
		# but use same testing filename (??)
		my $prev_build = $prev_prop_filename;
		for my $fault (sort keys %testing_geometry)
		{
		    my $ref_one_element = {$fault => $testing_geometry{$fault}};
		    
		    make_input_file_scenario($prev_build, $testing_filename, 
					     $ref_one_element, $is_sand);
		    
		    # get number of structures that could be possibly intersecting
		    my $structure_num = get_intersect_structs($testing_filename);
		    my $new_intersect = correct_intersections($testing_filename, $ref_one_element, 0, $structure_num);

		    # if fault does not intersect itself, preserve input file and add next element
		    if ($new_intersect>=0)
		    {
			# if fault does not intersect self,
			# use just made file as new previous file and repeat
			# maintain same name as testing file
			$prev_build = $testing_filename;

			if ($new_intersect>0)
			{
			    push(@ang_inter, $angle);
			}
			$fault_intersect = $new_intersect;
		    }
		    else
		    {
			$fault_intersect = -1;
		    }
		    
		}

	    }

	    if ($fault_intersect<0)
	    {
	        print "No work calculated => A fault intersects itself, or could not correct all intersections";
		
	    }
	    elsif ($previously_tested)
	    {
	        print "Work previously calculated: $prev_work_unnorm (J)";
	    }
	    # if the faults do not intersect, and we did not previously test geometry
	    # add to list to be run
	    else
	    {
	        #push(@outputs, $fric_output_filename)
		my $data = $testing_filename." ".$fric_output_filename." ".$angle;
		#print "Adding to testing file in tuning step: $data\n";
		push(@input_args, $data);

	    } # end of loop making the input files for elements at new angles to one (currently growing) fault
	    

	} # added to list of files to run


	# hash table to store work calculated for this fault
	# angle => work pairs
	my %this_fault = ();
	my %this_fault_unnorm = ();
	my %this_file = ();

	if (scalar(@input_args))
	{
	    # limit the number of processes forked to 20 at a time
	    my $lim = 16; # may change
	    
	    my $i=0;
	    while ($i<scalar(@input_args))
	    {
		my $end = $i+$lim;
		if ($end > scalar(@input_args))
		{
		    $end = scalar(@input_args)-1;
		}
		
		my @input_temp = @input_args[$i..$end];
		$i = $end+1;
		
		if (!($run_mode =~ /debug/))
		{
			my $max_workers = scalar(@input_temp);
			my $pm = new Parallel::ForkManager($max_workers);
			
			foreach my $input_line (@input_temp)
			{
			    my @args = split(' ', $input_line);
			
			    my $input = $args[0];
			    my $output = $args[1];
			    my $ang = $args[2];

			    print "STARTING RUN OF: ".$input." \n";
			    
			    my $pid = $pm->start and next; # start process, and next skips internal loop
			    
			    # run fric2d or sandbox
			    run_code($run_mode, $input, $output, $topo_filename);
			    
			    $pm->finish; # terminates child process
			}
			
			$pm->wait_all_children; # wait for all the children to finish running
			#sleep 10;
			
			print "COMPLETED SET OF RUNS----------\n";
		    }
		}


	    # now get Wext from all output files
	    foreach my $input_line (@input_args)
	    {
		my @args = split(' ', $input_line);

		my $input = $args[0];
		my $output = $args[1];
		my $ang = $args[2];		

		# get work from output files
		my $curr_work = get_work($run_mode, $output); 

		if ($curr_work) # if was able to calculat work
		{
		    my $cond_n = get_cond_num($run_mode, $output);
		    $cond_nums{$ang} = $cond_n;
		    $opt_works{$input} = $curr_work;

		    my $curr_work_unnorm = $curr_work;
		    $curr_work = normalize_work($prev_prop_work_unnorm, $curr_work, $input, $prev_prop_filename); 

		    # record work in hash table for this fault
		    $this_fault{$ang} = $curr_work; 
		    # record index and filename in hash table
		    $this_file{$ang} = $output; 	
		    $this_fault_unnorm{$ang} = $curr_work_unnorm;

		    # print statement
		    my $result = "$curr_work_unnorm\t$curr_work";
		    my $print_screen_summary = format_std_out($output, 
							  $prop_num, $result, $fault, $ang);
		    $raw_output = $raw_output.$print_screen_summary;
		    write_output($out_raw_filename, $raw_output);
		}
		else
		{
		    print "WARNING: Could not calculate work for geometry in file: ".$output."\n";
		}
	    }
	} 

	# if hash table is empty, then one fault intersects at all orientations 
	# when faults intersection work = 0
	if (!%this_fault)
	{
	    return (0, $raw_output); 
	}
	
	my %all_faults_unnorm = %this_fault_unnorm;
	my %all_faults = %this_fault; 

	# remove scenarios from the hash table if the element(s) that were just added
	# are not slipping if we are not using debug mode (which will not produce 
	# .out files
	if (!($run_mode =~ /debug/)) # && !$is_check)
	{
	    #%this_fault = remove_not_slipping_ineff($is_min, \%this_file, \%this_fault);
	    %this_fault_unnorm = remove_not_slipping_ineff($is_min, \%this_file, \%this_fault_unnorm);
	}
	
	my ($eff_angle, $eff_work) = (); 

	# if hash is empty after removing non-slipping scenarios
	# then work = -1
	if (!%this_fault)
	{
	    # if newly added elements not slipping in tuning sequence, don't overwrite flags
	    # because previously added elements do slip

	    # notify user/raw output that fault not growing anymore
	    my $out = "\nIN TUNING NEW ELEMENTS ADDED NOT SLIPPING\n\tFAULT AND END: $fault \n";
	    print $out; 
	    $raw_output = $raw_output.$out; 
	    write_output($out_raw_filename, $raw_output);
       
	    # signal to not copy files
	    $eff_angle = -2;

	}
	else
	{	    
	    my %valid_works = %this_fault_unnorm; # use Wext instead of delWext/delA
	    # remove the orienations that produce negative work
	    foreach my $angle (keys %this_fault_unnorm)
	    {
		my $curr_w = $this_fault_unnorm{$angle};
		if ($curr_w < 0)
		{
		    delete $valid_works{$angle};
		}
	    }

	    ($eff_angle, $eff_work) = get_opt_scenario($prev_prop_work_unnorm, \%valid_works, \@ang_inter,  \%cond_nums, $is_min, $is_topo); 
	    #$eff_work_unnorm = $this_fault_unnorm{$eff_angle}; ???????
	}
	
	# if we calculated the work for a scenario
	# and the most efficient work found is less/more than last iteration,
	# then update files, hash table and work values
	if ($eff_angle > 0 && ($is_min && $eff_work < $final_work_unnorm || (!$is_min && $eff_work > $final_work_unnorm)))
	{
	    $seq_filename = $root."_".$prop_num."_".$formatted_fault."_".$eff_angle.".in";
	    
	    $eff_file_out = substr($seq_filename, 0, -2)."out";

	    #  copy the appropriate files to the scenario that minimizes work
	    transfer_file($seq_filename, $efficient_filename);
	    
	    # remember fault name and minimum angle 
	    $efficient_geometry{$fault} = $eff_angle;
	    
	    $final_work = $this_fault{$eff_angle};
	    $final_work_unnorm = $this_fault_unnorm{$eff_angle};	

	    # print the new most efficient geometry
	    my $out = "\nTUNING PROPAGATION: $prop_num \nMORE EFFICIENT Wext CALCULATED WHILE TUNING: $final_work_unnorm (J) \nRESETTING MOST EFFICENT GEOMETRY TO FILE: $seq_filename \n\tEfficient Geometry \n";
	    $out = $out.sprintf("\t%-10s %-10s\n", "Fault", "Angle");

	    foreach my $fault (sort keys %efficient_geometry)
	    {
		$out = $out.sprintf("\t%-10s %-10s\n", $fault, $efficient_geometry{$fault}); 
	    }

	    print $out; 
	    $raw_output = $raw_output.$out;
	    write_output($out_raw_filename, $raw_output);

	}

   } # close loop of each fault, 
    
    # if an efficient geometry found because at least one element slipped
    if (%efficient_geometry)
    {
	# print most efficient geometry found during or before tuning
	$raw_output = $raw_output.print_work_summary(0, "TUNING PROPAGATION: $prop_num \nMOST EFFICIENT delWext/delA (J/m^2): $final_work \nGEOMETRY IN FILE: $seq_filename \n", 
						     \%efficient_geometry); 
	write_output($out_raw_filename, $raw_output);    
    }

    
    # if a new more efficient geometry calculated, 
    # then copy and paste contents of efficient file to file named "prev_filename"
    if ($final_work != $prev_work)
    {
	transfer_file($efficient_filename, $prev_prop_filename);  
    }
    # if all added elements not slipping
    elsif (!%efficient_geometry)
    {
	my $out = "\nTUNING PROPAGATION: $prop_num \nNO TUNED ELEMENTS GROWING\n"; 
	print $out;
	$raw_output = $raw_output.$out; 
	write_output($out_raw_filename, $raw_output);

    }
    # if we have tested slipping elements, but tuning did not find more efficient geometry
    elsif (%efficient_geometry && $final_work == $prev_work)
    {
	print "\nPROPAGATION: $prop_num \n\tEFFICIENT GEOMETRY FOUND BEFORE TUNING\n\tAT delWext/delA (J/m^2): $prev_work\n\tIN FILE: $seq_filename \n";
	$raw_output = $raw_output."\nPROPAGATION: $prop_num \n\tEFFICIENT GEOMETRY FOUND BEFORE TUNING\n\tAT Wext (J): $prev_work\n\tIN FILE: $seq_filename \n";
    }

    # return minimum work for all the scenarios tested
    return ($final_work_unnorm, $final_work, $raw_output, $seq_filename, $eff_file_out); 

}

# input: input arguments given by user
# result: execution ended if input file does not end in .in, if angle values not numeric, if angles nonsensical
sub check_input
{
	my $input_filename = "";
	my $inc_angle = "";
	my $start_angle = "";
	my $end_angle = "";
	($input_filename, $inc_angle, $start_angle, $end_angle) = @_;

	my @inputs = @_;
	if ($#inputs < 3)
	{
		die "INPUT ERROR: NOT SUFFICIENT NUMBER OF INPUTS \n";
	}
	
	# if no input file name, increment angle, starting angle or end angle, then report error
	if ($input_filename =~ /\.in/)
	{
	    # if input filename name > 25 chars, 
	    # then report error because typical grow run will add at least 25 chars to filename
	    if (length($input_filename) > 25)
	    {
		# if not continuing after restarting perl
		if (!($input_filename =~ /_cont\d/))
		{
		    die "INPUT ERROR: LENGTH OF FILENAME ($input_filename) > 25 chars:\n\tLater input files may not be read by FRIC2D: Shorten name. \n";
		}
	    }

	    if ($inc_angle =~ /^[0-9,.E]+$/ && $start_angle =~ /^[0-9,.E]+$/ && $end_angle =~ /^[0-9,.E]+$/)
	    {
		if ($start_angle > $end_angle)
		{
		    die "INPUT ERROR: STARTING ANGLE ($start_angle) > ENDING ANGLE ($end_angle) \n";
		}
		if ($end_angle >= 360)
		{
		    die "INPUT ERROR: ENDING ANGLE ($end_angle) >= 360 \n";
		}
		if ($start_angle <= 0)
		{
		    die "INPUT ERROR: STARTING ANGLE ($start_angle) <= 0 \n";
		}
	    }
	    else	
	    {
		die "INPUT ERROR: INCREMENT ANGLE ($inc_angle), STARTING ANGLE ($start_angle), AND ENDING ANGLE ($end_angle) MUST BE NUMERIC \n";
	    }
	}
	else
	{
	    die "INPUT ERROR: INPUT FILENAME MUST END IN .in \n\tFILENAME GIVEN: $input_filename \n";
	}	
}

# input: fric2d input name
# output: 1 if should update, 0 if should not update
sub get_update_topo
{
    my ($file) = @_;

    # open file, or send error message 
    open FILE_HANDLER, $file or die $!;

    # signal whether saw flaw title
    my $is_topo = 0;
    my $header = 0;
    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {
    	my $line = $_; 	
	if ($line =~ /^\*Update topography in GROW?/) 
	{
	    $header = 1;
	}
	elsif ($header && $line =~ /^\*Update = /)
	{
	    my @input = split (/\s+/, $line);
	    my $bool = $input[2];

	    if ($bool =~ /YES/)
	    {
		$is_topo = 1;
	    }
	}

    }

    # close the file
    close FILE_HANDLER;

    return $is_topo;
}

sub get_Ks;

#%sequence = get_top_faults(\%sequence, $file_out);
# remove faults from the hash with K1 or K2 below 10% of max K2
sub get_top_faults
{
    my ($ref, $file) = @_;
    my %seq = %$ref; # fault and end => list of angles
    my %seq_k = ();

    # make list of growing faults "name end"
    my @growing = ();
    for my $fault_e (%seq)
    {
	push(@growing, $fault_e);
    }

    # returns hash of fault name (and end?) end element with k1 or k2 > 90% of max k1 or k2
    my $ref_fault = get_Ks($file, \@growing);
    my @faults = @$ref_fault;

    print "Limiting search to faults with high K1 or K2: \n";
    for my $fault_e (@faults)
    {
	if (exists($seq{$fault_e}))
	{
	    # find key in hash
	    my @angs = @{$seq{$fault_e}};
	    @{$seq_k{$fault_e}} = @angs;
	    
	    print "$fault_e \n";
	}
    }
    
    return \%seq_k;
}

sub branch_fault;

sub branch_faults
{
    my ($outfile, $ref) = @_;
    my @faults = @$ref;

    my $isb = 0;
    for my $fname (@faults)
    {
	$fname = substr($fname, 0, -2);
	print "Testing branching capability of fault $fname in file $outfile \n";
        my $isbc = branch_fault($fname, $outfile);
	if ($isbc)
	{
	    $isb = $isbc;
	}
    }

    return $isb;
}

# input: ($x1s[$i], $y1s[$i], $x2s[$i], $y2s[$i], $infile);
# this should only check if the 2nd element is a node, and not the first element
#my $is_node = is_branch_node('0.02173', '-0.02900', '0.02372', '-0.02883', 'bone_0004_1_first30b1_2_130.in', 'first30b2'); # correct result
#my $is_node = is_branch_node('0.02000', '-0.03000', '0.02173', '-0.02900', 'bone_0004_1_first30b1_2_130.in', 'first30b1'); # correct
#my $is_node = is_branch_node('0.02553', '-0.02968', '0.02716', '-0.03083', 'bone_0004_1_first30b1_2_130.in', 'first30b2'); # correct
#print "is node: $is_node\n";

sub is_branch_node
{
    my ($x, $y, $xsp, $ysp, $infile, $fname) = @_;

    my $isbnode = 0;

    #print "$x, $y, $xsp, $ysp, $infile, $fname \n";

    # if the fault name does not include a b and number at the end
    # then it has not been split
    if (!($fname =~ /b\d+$/))
    {
        #print "fault name does not contain b+digit \n";
        return $isbnode;
    }

    open FILE_HANDLER, $infile or die $!;
    my @x1s = ();
    my @y1s = ();
    my @x2s = ();
    my @y2s = ();

    my @o1s = ();
    my @o2s = ();

    my $readf = 0;
    my $readfo = 0;
    while (<FILE_HANDLER>)
    {
        my $line = $_;
        if ($line =~ /^fault\s+$fname\s+/)
        {
            $readf = 1;
            $readfo = 0;
        }
        elsif ($line =~ /^fault\s+/)
        {
            $readf = 0;
            $readfo = 1;
        }
        # reading desired fault
        elsif ($readf && $line =~ /^\d+\s+/)
        {
            # add to list of x coordinates
            my @dat = split(/\s+/, $line);

            push(@x1s, $dat[1]);
            push(@y1s, $dat[2]);
            push(@x2s, $dat[3]);
            push(@y2s, $dat[4]);
        }
         # reading a different fault
        elsif ($readfo && $line =~ /^\d+\s+/)
        {
            # add to list of x coordinates
            my @dat = split(/\s+/, $line);

            push(@o1s, "$dat[1] $dat[2]");
            push(@o2s, "$dat[3] $dat[4]");


        }

    }

    # if the coordinates to split on are at the end of the fault
    # then isbnode=1
    if (($x1s[0]==$x && $y1s[0]==$y && $x2s[0]==$xsp && $y2s[0]==$ysp) || ($x1s[-1]==$xsp && $y1s[-1]==$ysp))
    #if (($x2s[0]==$xsp && $y2s[0]==$ysp) || ($x1s[-1]==$xsp && $y1s[-1]==$ysp))
    {
        #print "splitting element at end of previously brnached fault \n";
        # if the splitting coordinates are equal to any of the coordinates
        # from other faults, then do not allow the sl´plit
        #if ("$xsp $ysp" ~~ @o1s || "$xsp $ysp" ~~ @o2s || "$x $y" ~~ @o1s || "$x $y" ~~ @o2s)
	# only consider this coordinate to be a node if the splitting node matches,
	# and not the other end of the fault
	if ("$xsp $ysp" ~~ @o1s || "$xsp $ysp" ~~ @o2s)
        {
            #print "found splitting coordinates in another fault \n";
            return 1;
        }

        

    }


    #print "reached end of script \n";
    return $isbnode;

}

#my $isnode = is_branch_node ('0.02217', '-0.02875', '0.02464', '-0.02832', 'bonspre.in', 'first30b2');
#my $isnode = is_branch_node ('0.02000', '-0.03000', '0.02217', '-0.02875',  'bonspre.in', 'first30b1');
#my $isnode = is_branch_node ('0.02710', '-0.02875', '0.02927', '-0.03001',  'bonspre.in', 'first30b2');
#my $isnode = is_branch_node ('0.02217', '-0.02875', '0.02464', '-0.02832',  'bonspre.in', 'first30b2');
#print "is a node of a fault $isnode \n";

#my $isb = branch_fault('first30b2', 'bone_0004_1_first30b1_2_130.out');
#print "is branched?: $isb \n";

# input: name of fault, name of output file, assumes input file exists
sub branch_fault
{
    my ($fname, $outfile) = @_;

    my $infile = substr($outfile, 0, -4).".in";
    open FILE_HANDLER, $infile or die $!;

    # get the headerlines for this fault
    my $isb = 0;
    my @headerlines = ();
    #my $oldfls = '';
    my $readl = 0;
    my $readf = 0;
    my $numfls = 0;
    my $infls = '';
    my $flines = '';
    while (<FILE_HANDLER>)
    {
        my $line = $_;
        my $hline = substr($line, 0, -1);
        if ($line =~ /^fault\s+$fname\s+/)
        {
            $readl = 1;
            $readf = 1;
            push(@headerlines, $hline);
            $infls = $infls."<NEWLINES>";
        }
        elsif ($line =~ /^fault\s+/)
        {
            $readl = 0;
            $readf = 0;
        }
        elsif ($readf && $line =~ /^\d+\s+/)
        {
            $readl = 0; 
	    $numfls++;
	    $flines = $flines.$line;
        }
        elsif ($readl ==1)
        {
            push(@headerlines, $hline);
        }

        if ($readf==0)
        {
            $infls = $infls.$line;
        }        
    }

    # HOW OFTEN SHOULD WE SPLIT?
    # only try to split the faults if there is more than a certain number of elements
    if ($numfls<5)
    {
	   return $isb;
    }

    my @x1s = ();
    my @y1s = ();
    my @x2s = ();
    my @y2s = ();
    my @ls = ();
    my @S0s = ();
    my @Us_negs = ();
    my @Us_poss = ();
    my @sigSs = ();
    my @sigNs = ();
    my @in_lines = (); # get input lines to format later

    my $getdat = 0;

    # get the output data
    open FILE_HANDLER, $outfile or die $!;
    while (<FILE_HANDLER>)
    {
        my $line = $_;
        my @dat = split(/\s+/, $line);

        if ($line =~ /^FAULT:\s+$fname\s+/)
        {
            $getdat = 1;
        }
        # if see a fault without the given fault name
        elsif ($line =~ /^FAULT:\s+/)
        {
            $getdat = 0;
        }
        # input lines
        elsif ($getdat && ($line =~ /^\s+\d+\s+/ || $line =~ /^\d+\s+/))
        {
            my $len = scalar(@dat);
            if ($len> 15)
            {
                push(@x1s, $dat[2]);
                push(@y1s, $dat[3]);
                push(@x2s, $dat[4]);
                push(@y2s, $dat[5]);
                push(@ls, $dat[6]);
                push(@S0s, $dat[11]);

                my $reformat = "1 $dat[2] $dat[3] $dat[4] $dat[5] $dat[8] $dat[9] $dat[10] $dat[11] $dat[12] $dat[14] $dat[15] $dat[16] \n";
                push(@in_lines, $reformat);
            }
            else
            {
                push(@Us_negs, $dat[3]);
                push(@Us_poss, $dat[4]);
                push(@sigSs, $dat[8]);
                push(@sigNs, $dat[9]);  
            }
        }
    }

    my @coul_maxs = ();
    my @coul_bots = ();
    my @coul_tops = ();
    my @isfail = (0);

    my $abs_max =0;
    print "index x1 y1 x2 y2 max_Coulomb S0 result\n";
    my $i = 0;
    while ($i < scalar(@Us_poss)-1)
    {
        my $delUs_pos = ($Us_poss[$i+1]-$Us_poss[$i]);
        my $delUs_neg = ($Us_negs[$i+1]-$Us_negs[$i]);
        my $delsigS = ($sigSs[$i+1]-$sigSs[$i]);
        my $delsigN = ($sigNs[$i+1]-$sigNs[$i]);
        my $S0 = ($S0s[$i+1]+$S0s[$i])/2;
        my $l = ($ls[$i+1]+$ls[$i])/2;

        my $top_grad = $delUs_pos/$l;
        my $bot_grad = $delUs_neg/$l; 
        # QUESTION: are the numbers in the below equation constants? or do they depend on
        # the model geometry?
        my $tang_top = 0.023/(1-0.2**2)*$top_grad+(0.2/(1-0.2)*($delsigN/2)); 
        my $tang_bot = 0.023/(1-0.2**2)*$bot_grad+(0.2/(1-0.2)*($delsigN/2)); 

        my $sig_xx = $delsigN/2;
        my $sig_yy = $tang_top;
        my $tau = $delsigS/2;
        my $sig_max = 0.5*($sig_xx + $sig_yy) + sqrt((0.5*($sig_xx-$sig_yy))**2 + $tau**2);
        my $sig_min = 0.5*($sig_xx + $sig_yy) - sqrt((0.5*($sig_xx-$sig_yy))**2 + $tau**2);
        my $sum = $sig_min + $sig_max;
        my $coul_top = 0.5*($sum*tan(deg2rad(30)) + ($sig_max-$sig_min)/cos(deg2rad(30)));

        $sig_yy = $tang_bot;
        $sig_max = 0.5*($sig_xx + $sig_yy) + sqrt((0.5*($sig_xx-$sig_yy))**2 + $tau**2);
        $sig_min = 0.5*($sig_xx + $sig_yy) - sqrt((0.5*($sig_xx-$sig_yy))**2 + $tau**2);
        $sum = $sig_min + $sig_max;
        my $coul_bot = 0.5*($sum*tan(deg2rad(30)) + ($sig_max-$sig_min)/cos(deg2rad(30)));

        push(@coul_tops, $coul_top);
        push(@coul_bots, $coul_bot);

        my $coul_max = max($coul_top, $coul_bot);
        $isfail[$i] = 0;
        $coul_maxs[$i] = 0;

        # only add this measurement of coulomb stress and failure if 
        # this element is not the end point of a previously branched fault
        my $is_node = is_branch_node($x1s[$i], $y1s[$i], $x2s[$i], $y2s[$i], $infile, $fname);

        #print "is this a node?: $is_node\n";
        #die; 

        if (!$is_node && $coul_max > $S0 && $coul_max > $abs_max)
        {
	    print "$i $x1s[$i] $y1s[$i] $x2s[$i] $y2s[$i] $coul_max $S0 considered for splitting\n";
            $isfail[$i] = 1;
            $coul_maxs[$i] = $coul_max;
	    $abs_max = $coul_max;
        }
	else
	{
	    print "$i $x1s[$i] $y1s[$i] $x2s[$i] $y2s[$i] $coul_max $S0 not considered for splittling\n";
	}

        $i++;
    }

    my $anyfail = sum(@isfail);
    if ($anyfail>0)
    {
        print "Splitting the fault $fname in file $infile \n";
        my $newf1 = '';
        my $newf2 = '';
        my $coulmax_abs = max(@coul_maxs);
        $i = 0;
        while ($i < scalar(@isfail))
        {
            my $coul = $coul_maxs[$i];

            # we found the element with the max coulomb stress that exceeds S0
            if ($coul == $coulmax_abs)
            {
                # always use the 2nd node of the element?
		# or should we use the 1st node?
                my $x_split = $x2s[$i]; 
                my $y_split = $y2s[$i];
		#print "splitting at: $x_split $y_split\n";

                # make 2 new faults in the place of the previous fault

                #print "$fname $x_split $y_split \n";
                # new input lines
                #*num   xbeg     ybeg    xend    yend    stiffS     stiffN      To  So   cohesion stat_fric  dyn_fric crit_slip

                # the first fault segment is beg to coordinate where end2 =  split coordinates
                # the second fault segment is the remaining

                my $is2 = 0; # not writing to the second fault
                foreach (@in_lines)
                {
                    # check if this line is the line where to split
                    my $inl = $_;

                    my @dat = split(/\s+/, $inl);
                    my $x1 = $dat[1];
                    my $y1 = $dat[2];

                    if ($x1==$x_split && $y1==$y_split)
                    {
			#print "found x and y split at the first end \n";
                        $is2 = 1;
                    }
                    
                    if ($is2)
                    {
                        $newf2 = $newf2.$inl;
                    }
                    # we are writing to the first segment of this fault
                    else
                    {
                        $newf1 = $newf1.$inl;
                    }

                }

                $i = scalar(@isfail); # exit the loop
            }
            $i++;
        }


	my $titleline = $headerlines[0];
	my $crackline = $headerlines[2];
	my $tagline = $headerlines[1];

	my $fname_new1 = $fname."b1";
	my $fname_new2 = $fname."b2";

	# for the first segment of the fault always set the end flag to growing
	# for the second segment, always set the beg flag to no, and use previous flag

	my @tit = split(/\s+/, $titleline);
	my $newtit1 = "fault $fname_new1 no $tit[3] yes";
	my $newtit2 = "fault $fname_new2 no no $tit[4]";

	my $newfaults = "$newtit1\n$tagline\n$crackline\n$newf1\n\n$newtit2\n$tagline\n$crackline\n$newf2\n\n";

	# comment out when running
	#print $newfaults;
	#die;

	my $newinfile = $infls;
	$newinfile =~ s/<NEWLINES>/$newfaults/;

	# comment out for running
	#print $newinfile;
	#die;

	# write to original input files
	#$infile = "test.in";
	open(FH, '>', $infile) or die $!;
	print FH $newinfile;
	close(FH);

	$isb = 1;
    }

    #print "reached end of script \n";
    return $isb;
}

# why is f1g not listed in growing faults with high K?
#my @growing = ('f1 2', 'f1 1', 'f2 2', 'f2 1', 'f3 2', 'f3 1', 'f4 2', 'f4 1', 'f5 2', 'f5 1', 'f6 2', 'f6 1');
#my @growing = ('f1g 1', 'f2g', 'rc238 1', 'rc238 2', 'rc250 1', 'rc250 2');
#my $ref = get_Ks('el.out', \@growing);
#my @ar = @$ref;
#foreach my $f (@ar)
#{
#    print $f;
#    print "\n";
#}

sub get_Ks
{
    my ($file, $ref_grow) = @_;

    open FILE_HANDLER, $file or die $!;

    my $ei = 0;
    my $K = 0;
    my $f = 0;
    my $f_curr = '';
    my $elem_curr = '';

    my %fault_elems = (); # fault name => list of element
    my @fault_gends = ();
    my %elems_k1s = ();
    my %elems_k2s = ();
    my %elems_pang = ();
    my %elems_fails = ();
    my %elems_ends = ();
    my $end = 0;
    my $elem_prev = 0;

    my $k1_curr = 0;
    my $k2_curr = 0;
    my $pang_curr = 0;

    my $curr_l = 0;
    my $end_load = 0;

    # remove the elements of the faults that are not growing
   my @faults_grow = @$ref_grow;

    while (<FILE_HANDLER>)
    {	
	my $line = $_;
	my @data = split(/\s+/, $line);

	# if line is part of boundary lines, then ignore, and put place marker
	# only add to data if fault is growing (in sequence ref)
	if ($curr_l == 1 && $line =~ /^FAULT: /)
	{
	    # determine if this fault is among the growing faults, 
	    # otherwise do not include
	    $f_curr = $data[1];
	    my $is_grow = 0;

	    foreach my $f_grow (@faults_grow)
	    {
		my $grow_name = substr($f_grow, 0, -2);

		if ($f_curr eq $grow_name)
		{
		    my $end_grow = substr($f_grow, -1, length($f_grow));
		    $is_grow = 1;

		    push(@fault_gends, $f_curr." ".$end_grow);
		}

	    }

	    if ($is_grow)
	    {
		$f = 1;
		$f_curr = $data[1];
		$fault_elems{$f_curr} = ''; 
		
	    }
	}
	elsif ($f && ($line =~ /^\s+\d+\s+/ || $line =~ /^\d+\s+/))
	{
	    my $elem_curr = $data[1];
	    if ($line =~ /^\d+\s+/)
	    {
		$elem_curr = $data[0]; # if more than 1000 elements
	    }

	    my $elem_prev = $fault_elems{$f_curr};
	    $elem_prev = $elem_prev." ".$elem_curr;
	    $fault_elems{$f_curr} = $elem_prev;
	    
	}
	elsif ($f && $line =~ /^\s+Elt\s+DS\s+US/)
	{
	    $f =0;
	}
	elsif ($line =~ /^DATA FROM LOADING STEP #/)
	{
	    my @data_l = split(/\s+/, $line);
	    $curr_l = $data_l[4];
	    $curr_l =~ s/#//g;
	    my $fin_l = $data_l[6];

	    if ($curr_l==$fin_l)
	    {
		$end_load = 1;
	    }
	}
	elsif ($end_load && $line =~ /BE\s+Tangential\s+/)
	{
	    $K = 1;
	    $ei=$ei+1;
	}
	elsif ($K && $line =~ /^The\s+following\s+/)
	{
	    $K = 0;
	}
	# get element number
	elsif (($K && $line =~ /^\s+tip\s+BE\s+=\s+\d+/) || ($line =~ /^\s+tip\s+BE\s+=\s+\d+/))
	{
	    if (!$K)
	    {
		$K=1;
		$ei=$ei+1;
	    }

	    $elem_curr = $data[4];
	    $elems_k1s{$elem_curr} = ''; 
	    $elems_k2s{$elem_curr} = '';
	    $elems_pang{$elem_curr} = '';
	    $elems_fails{$elem_curr} = '';

	    $end = 1;
	    # find which fault this element belongs to
	    foreach my $f (keys %fault_elems)
	    {
		my $els = $fault_elems{$f};
		my @el_list = split(/\s+/, $els);

		if ($elem_curr == $el_list[1] && $elem_curr == $el_list[$#el_list])
		{
		    $end = 3;
		}
		elsif ($elem_curr == $el_list[1])
		{
		    $end = 1;
		}
		elsif ($elem_curr == $el_list[$#el_list])
		{
		    $end = 2;
		}


		$elems_ends{$elem_curr} = $end;
	    }

	}
	# get k1 for this element
	elsif ($K && $line =~ /^\s+k1\s+/)
	{
	    my $prev = $elems_k1s{$elem_curr};
	    $prev = $prev." ".$data[3];
	    $elems_k1s{$elem_curr} = $prev;
	    $k1_curr = $data[3];
		print "$elem_curr K1 $k1_curr ";
		#if($k1_curr < 0)
		#{
		#	$k1_curr = 0;
		#}
		
	}
	# get k2 for this element
	elsif ($K && $line =~ /^\s+k2\s+/)
	{
	    my $prev = $elems_k2s{$elem_curr};
	    $prev = $prev." ".abs($data[3]);
	    $elems_k2s{$elem_curr} = $prev;
	    
	    $k2_curr = abs($data[3]);
		print "K2 $k2_curr ";	    

	    #my $f = $k1_curr**2 + $k2_curr**2;
	    
	    #$prev = $elems_fails{$elem_curr};
	    #$prev = $prev." ".$f;
	    #$elems_fails{$elem_curr} = $prev;
	    
	}
	# get pangle for this element
	elsif ($K && $line =~ /^\s+pangle\s+/)
	{
	    my $prev = $elems_pang{$elem_curr};
	    $prev = $prev." ".($data[3]);
	    $elems_pang{$elem_curr} = $prev;
	    
	    $pang_curr = $data[3];
	    my $pang_rad = $pang_curr*(3.1415926/180);
		print "pang $pang_curr $pang_rad\n";	    

	    my $f = $k1_curr*(cos($pang_rad/2)**3) - (3/2*$k2_curr*sin($pang_rad)*cos($pang_rad/2));
	    
	    $prev = $elems_fails{$elem_curr};
	    $prev = $prev." ".$f;
	    $elems_fails{$elem_curr} = $prev;
	    
	}
    }

    close FILE_HANDLER;

    my $f_max = 0;
    # find fault with this element
    foreach my $fault (keys %fault_elems)
    {
	my $elems_f = $fault_elems{$fault};
	my @elems_fs = split(/\s+/, $elems_f);

	foreach my $elem (sort(keys %elems_fails))
	{
	    my $f = $elems_fails{$elem};
	    my $end = $elems_ends{$elem};
	    my $f_e = $fault." ".$end;
	    if ($end==3) # if one element long, consider from end 1
	    {
		$f_e = $fault." 1";
	    }

	    # if high k element is in the list of fault elements
	    # add the fault name and end
	    #if (grep(/$elem/, @elems_fs) && grep(/$f_e/, @fault_gends))
	    if (grep(/^$elem$/, @elems_fs) && grep(/^$f_e$/, @fault_gends))
	    {
		if ($f>$f_max)
		{
		    $f_max = $f;
		}
	    }
	}
    }
   
    # for each k1, get max
    # get elements with K1> 90*max
    # get name of faults for these elements with name space end#
    #my $k1_max = max values %elems_k1s;  
    #my $k2_max = max values %elems_k2s;

    my @kfaults_ends = ();

    print "Assessing propensity for failure of growing fault ends:\n";
    print "fault end element# K1>0+abs(K2)\n";

    # find fault with this element
    foreach my $fault (sort (keys %fault_elems))
    {
	my $elems_f = $fault_elems{$fault};
	my @elems_fs = split(/\s+/, $elems_f);

	foreach my $elem (sort(keys %elems_fails))
	{
	    my $f = $elems_fails{$elem};
	    my $end = $elems_ends{$elem};
	    my $f_e = $fault." ".$end;

	    if ($end==3) # if one element long, consider from end 1
	    {
		$f_e = $fault." 1";
	    }

	    # if high k element is in the list of fault elements
	    # add the fault name and end
	    #if (grep(/$elem/, @elems_fs) && grep(/$f_e/, @fault_gends))
	    if (grep(/^$elem$/, @elems_fs) && grep(/^$f_e$/, @fault_gends))
	    {
		print "$fault $end $elem $f\n";
		
		if ($f > 0.9*$f_max)
		{
		    if ($end<3)
		    {
			push(@kfaults_ends, $fault." ".$end);
		    }
		    else
		    {
			push(@kfaults_ends, $fault." 1");
			push(@kfaults_ends, $fault." 2");
		    }
		}
	    }
	}

    }

    print "\n";

    return \@kfaults_ends;

}

#


#update_topo('test.in','test.eff','test.topo');

# input: original input file, name of new file, topo file
# result: topography of efficient file updated based on previous output file
# returns: name of new topography file, if it exists
sub update_topo
{
    my ($eff_in, $eff_name, $topo_filename) = @_;

    my $fline_in_len = 13; # number of values in input line
    my $fline_out_len = 17;

    my $replace_faults = 1; # replace faults with new coordinates (1) or not (0)
    my $filein = $eff_in;
    my $filein_update = $eff_name;  # name of most efficient file to copy later

    my $fileout = substr($filein, 0, -2).'out';

    my $filein_orig = $eff_in; # use initial loadining conditions from input file as input geometry

    my @loadings = ();
    # in the initial input file, get the boundary lines and conditions
    # make list of loading conditions that equal length of number of elements in each boundary line
    open FILE_HANDLER, $filein_orig or die $!;

    my $fb = 0;
    while (<FILE_HANDLER>)
    {	
	my $line = $_;
	my @data = split(/\s+/, $line);

	# if line is part of boundary lines, then ignore, and put place marker
	if ($line =~ /\*Boundary\s+Lines/)
	{
	    $fb = 1;
	}
	elsif ($fb && $line =~ /fault/)
	{
	    $fb = 0;
	}
	elsif ($fb && $line =~ /\d/ && scalar(@data) == 10)
	{
	    my $load = $data[5]." ".$data[6]." ".$data[7]." ".$data[8]." ".$data[9];
	    my $num = $data[0];
	    my $ni = 0;
	    while ($ni<$num)
	    {
		push(@loadings, $load);
		$ni=$ni+1;
	    }
	}	
    }

    close FILE_HANDLER;

    my $topo_lines = '';
    my $filetopo_new = '';
    # for each of the boundary lines, make list of coordiantes
    # closely spaced along line to identify later
    my @xbs_inf = ();
    my @ybs_inf = ();

    if ($topo_filename)
    {
	$filetopo_new = substr($topo_filename, 0, -5).'_1.topo'; # make new name for new topo file
	# make new topo file name, using old name
	# if no _ in name
	my @name = split (/_/, $topo_filename);
	if (scalar(@name) > 1)
	{
	    my $ind = $name[-1];
	    $ind =~ s/.topo//g;
	    $ind = $ind+1;
	    $filetopo_new = $name[0].'_'.$ind.'.topo';
	}
        # read in topo file, and remmber coordinates
	my @xbs = ();
	my @ybs = ();

	open FILE_HANDLER, $topo_filename or die $!;

	while (<FILE_HANDLER>)
	{
	    my $line = $_;
	    my @input = split (/\s+/, $line);

	    if (scalar(@input) == 2)
	    {
		push(@xbs, $input[0]);
		push(@ybs, $input[1]);
	    }
	    
	}

	close FILE_HANDLER;

	my $j = 0;
	while ($j < scalar(@xbs)-1)
	{
	    my $x1 = $xbs[$j];
	    my $y1 = $ybs[$j];
	    
	    my $x2 = $xbs[$j+1];
	    my $y2 = $ybs[$j+1];
	    
	    my $D = sqrt(($x1-$x2)**2+($y1-$y2)**2);

	    my $d_inc = 0.01; # increment along line
	    my $d = $d_inc;
	    while ($d < 1)
	    {
		my $x3 = $x1 + $d*($x2-$x1);
		my $y3 = $y1 + $d*($y2-$y1);
		
		push(@xbs_inf, $x3);
		push(@ybs_inf, $y3);
		$d = $d + $d_inc;
	    }
	    $j++;
	}	
    }


    # read in contents of output file
    # get boundary lines (input), recording initial position
    # get boundary lines output, get DS and DN

    my @f_lines = ();
    my @bound_lines = ();

    # bound line properties
    my @x1s = ();
    my @y1s = ();
    my @x2s = ();
    my @y2s = ();
    my @elems = ();
    my @angs = ();

    my @DSs = ();
    my @DNs = ();

   # fault properties
    my @felems = ();
    my @fx1s = ();
    my @fy1s = ();
    my @fx2s = ();
    my @fy2s = ();
    my @fangs = ();

    my @fDSs = ();
    my @fDNs = ();

    # keep track of which element is in which fault
    my @fcounts = ();

    # first element of each fault
    my @first_felems = ();

    open FILE_HANDLER, $fileout or die $!;

    my $f_num = 0;
    my $new_fault = 1;
    my $foundf = 0;
    my $found = 0;
    my $end_load = 0;
    my $curr_l = 0;
    #my $flt_i = 0;
    while (<FILE_HANDLER>)
    {
	my $line = $_;
	my @input = split (/\s+/, $line);

	# find the start of the boundary lines
	if ($line =~ /^BOUNDARY\s+LINES/ )
	{
	    $found = 1;
	}
	elsif ($line =~ /^FRACTURES/ )
	{
	    $found = 0;
	}
	elsif ($line =~ /^FAULT:/ )
	{
	    $foundf = 1;
	    $new_fault = 1;

	    if ($end_load)
	    {
		$f_num = $f_num+1;
	    }
	}
	elsif ($line =~ /^The following frictional elements slipped in this loading step:/ )
	{
	    $foundf = 0;
	}
	elsif ($line =~ /^DATA FROM LOADING STEP #/)
	{
	    my @data_l = split(/\s+/, $line);
	    $curr_l = $data_l[4];
	    $curr_l =~ s/#//g;
	    my $fin_l = $data_l[6];

	    if ($curr_l==$fin_l)
	    {
		$end_load = 1;
	    }
	}
	# found the boundary
	elsif ($found)
	{
	    # boundary input lines
	    if ($curr_l==1 && scalar(@input) == 13 && $line =~ /\d/)
	    {	    
		push(@elems, $input[1]);
		push(@x1s, $input[2]);
		push(@y1s, $input[3]);
		push(@x2s, $input[4]);
		push(@y2s, $input[5]);
		push(@angs, $input[7]);

		my $ii = 8;
		while ($ii < 13)
		{
		    if (abs($input[$ii]) < 1e-10)
		    {
			$input[$ii] = 0;
		    }
		    $ii++;
		}

		my $loading = $loadings[$input[1]-1];

		# if no loading found in input file, then use listed loading conditions
		# occurs when intersection with boundary occurs
		if (!$loading)
		{
		    $loading = sprintf("%d", $input[8])." ".sprintf("%.6f",$input[9])." ".sprintf("%.6f",$input[10])." ".sprintf("%.6f",$input[11])." ".sprintf("%.6f",$input[12]);
		}


		# for this boundary line in the output file, find the loading conditions in the original input
		my $prev_line = "1 COORS ".$loading."\n"; 
		push(@bound_lines, $prev_line);
	    }
	    # boundary output lines
	    elsif ($end_load && scalar(@input) == 10 && $line =~ /\d/)
	    {	    
		push(@DSs, $input[2]);
		push(@DNs, $input[5]);

	    }
	}
	# found the fault lines
	elsif ($foundf)
	{
	    if ($line =~ /OBSERVATION\s+LINES/)
	    {
		$foundf = 0;
	    }
	    elsif ($curr_l == 1 && scalar(@input) == $fline_out_len && $line =~ /\d/)
	    {
		push(@felems, $input[1]);	    
		push(@fx1s, $input[2]);
		push(@fy1s, $input[3]);
		push(@fx2s, $input[4]);
		push(@fy2s, $input[5]);
		push(@fangs, $input[7]);
		push(@fcounts, $f_num);

		my $props = 'PROPS';
		my $prev_line = "1 COORS ".$props."\n";

		push(@f_lines, $prev_line);

		if ($new_fault)
		{
		    push(@first_felems, $input[1]);
		    $new_fault = 0;
		}
	    }
	    elsif ($end_load && scalar(@input) == 10 && $line =~ /\d/)
	    {	    

		push(@fDSs, $input[2]);
		push(@fDNs, $input[5]);
	    }
	}
    }

    close FILE_HANDLER;

    my @xbs = (); 
    my @ybs = ();

    my $prev_line = '';

    my @elem_lens = (); # use boundary lines to get mean element size
    my $elem_len = 1; # change later

    # update boundary lines
    my $new_lines = '';
    my $i = 0;
    while ($i < scalar(@x1s))
    {
	my $x1 = $x1s[$i];
	my $x2 = $x2s[$i];
	my $y1 = $y1s[$i];
	my $y2 = $y2s[$i];
	my $ang = $angs[$i];
	my $theta = $ang*(3.1415926/180);
	my $theta_n = ($ang+90)*(3.1415926/180);

	my $DN = $DNs[$i];
	my $DS = $DSs[$i];

	# translate normal and shear components of movement into x and y components
	my $DSx = $DS*cos($theta); # assumes shear component goes from x1,y1 to x2,y2
	my $DSy = $DS*sin($theta);

	my $DNx = $DN*cos($theta_n); # assumes nomal component is negative toward element
	my $DNy = $DN*sin($theta_n);

	my $x1p = $x1 + $DSx + $DNx;
	my $x2p = $x2 + $DSx + $DNx;
	my $y1p = $y1 + $DSy + $DNy;
	my $y2p = $y2 + $DSy + $DNy;

	my $elem_len_curr = sqrt(($x1-$x2)**2+($y1-$y2)**2);
	push(@elem_lens, $elem_len_curr);
	$elem_len = sum(@elem_lens)/scalar(@elem_lens);

	# if new boundary coordinate close to previous coordinate, then
	# make it equal to boundary coordiante
	my $k = 0;
	while ($k < scalar(@xbs))
	{
	    my $dist1 = sqrt(($xbs[$k]-$x1p)**2+($ybs[$k]-$y1p)**2);
	    my $dist2 = sqrt(($xbs[$k]-$x2p)**2+($ybs[$k]-$y2p)**2);	
	    if ($dist1 < $elem_len/10)
	    {
		$x1p = $xbs[$k];
		$y1p = $ybs[$k];
	    }
	    if ($dist2 < $elem_len/10)
	    {
		$x2p = $xbs[$k];
		$y2p = $ybs[$k];
	    }
	    
	    $k++;
	}

	push(@xbs, $x1p); 
	push(@xbs, $x2p);
	push(@ybs, $y1p);
	push(@ybs, $y2p);

	$prev_line = $bound_lines[$i];
	my $coors = sprintf("%.6f", $x1p)." ".sprintf("%.6f", $y1p)." ".sprintf("%.6f", $x2p)." ".sprintf("%.6f", $y2p);

	# replace place holder with new coordinates
	my $line = $prev_line;
	$line =~ s/COORS/$coors/g;
	
	$new_lines = $new_lines.$line;

	if ($topo_filename)
	{
	    # if this coordinate is within 1mm of point on the boundary lines defined in the topo file
	    # then remember it
	    my $dist = 1e10;
	    my $j = 0;
	    while ($j < scalar(@xbs_inf))
	    {
		my $dist_curr = sqrt(($x1-$xbs_inf[$j])**2+($y1-$ybs_inf[$j])**2);
		
		if ($dist_curr < $dist)
		{
		    $dist = $dist_curr;
		}
		$j++;
	    }

	    # if the closest distance between this point and pt on boundary is less than 1 mm, 
	    # then consider this new point as part of topo file (perhaps should be changed with larger model set ups)
	    if ($dist < 0.001)
	    {
		$topo_lines = $topo_lines.$x1p.' '.$y1p."\n";
	    }
	    
	}

	$i++;
    }

    # if the first and last boundaries are not connected, then connect with extra element
    my $extra_num = 0; # will be 1 eventually

    if (!(($xbs[0] == $xbs[-1]) && ($ybs[0] == $ybs[-1])))
    {
	my $coors = sprintf("%.5f", $xbs[-1])." ".sprintf("%.5f", $ybs[-1])." ".sprintf("%.5f", $xbs[0])." ".sprintf("%.5f", $ybs[0]);
	my $line = $prev_line;
	$line =~ s/COORS/$coors/g; 
	$new_lines = $new_lines.$line;
	$extra_num = 1;
    }

    my $num_lines = scalar(@elems)+$extra_num;

    my @xfs = (); ##
    my @yfs = ();
    my @fcs = ();

    my $x2p_prev = $fx2s[0];
    my $y2p_prev = $fy2s[0];

    # update fault coordinates
    my $f_new_lines = '';
    my $f_i = 1; # tally of number of faults
    $i = 0;
    while ($i < scalar(@fx1s))
    {
	my $elem = $felems[$i];
	my $x1 = $fx1s[$i];
	my $x2 = $fx2s[$i];
	my $y1 = $fy1s[$i];
	my $y2 = $fy2s[$i];
	my $ang = $fangs[$i];
	my $theta = $ang*(3.1415926/180);
	my $theta_n = ($ang+90)*(3.1415926/180);

	my $DN = $fDNs[$i];
	my $DS = $fDSs[$i];

	my $fc = $fcounts[$i];

	# translate normal and shear components of movement into x and y components
	my $DSx = $DS*cos($theta); # assumes shear component goes from x1,y1 to x2,y2
	my $DSy = $DS*sin($theta);

	my $DNx = $DN*cos($theta_n); # assumes nomal component is negative toward element
	my $DNy = $DN*sin($theta_n);

	my $x1p = $x1 + $DSx + $DNx;
	my $x2p = $x2 + $DSx + $DNx;
	my $y1p = $y1 + $DSy + $DNy;
	my $y2p = $y2 + $DSy + $DNy;

	#my $elem_len = sqrt(($x1-$x2)**2+($y1-$y2)**2); # use average of boundary lines found earlier

	# if new fault coordinate close to boundary coordinate, then
	# make it equal to boundary coordiante
	my $k = 0;
	while ($k < scalar(@xbs))
	{
	    my $dist1 = sqrt(($xbs[$k]-$x1p)**2+($ybs[$k]-$y1p)**2);	
	    my $dist2 = sqrt(($xbs[$k]-$x2p)**2+($ybs[$k]-$y2p)**2);
	    # only one node of one element should be close to boundary at a time
	    if ($dist1 < $elem_len/2) 
	    {
		$x1p = $xbs[$k];
		$y1p = $ybs[$k];
	    }
	    elsif ($dist2 < $elem_len/2) # elif
	    {
		$x2p = $xbs[$k];
		$y2p = $ybs[$k];
	    }
	    
	    $k++;
	}


	# if close to another fault element, then update coordinate
	$k = 0;
	while ($k < scalar(@xfs))
	{
	    # if this point (k) is not in this fault (xp, yp)
	    my $fcf = $fcs[$k];

	    my $dist1 = sqrt(($xfs[$k]-$x1p)**2+($yfs[$k]-$y1p)**2);	
	    my $dist2 = sqrt(($xfs[$k]-$x2p)**2+($yfs[$k]-$y2p)**2);
	    # two nodes of an element can be close to another node of element
	    if ($dist1 < $elem_len/10)
	    {
		$x1p = $xfs[$k];
		$y1p = $yfs[$k];
	    }
	
	    if ($dist2 < $elem_len/10)
	    {
		$x2p = $xfs[$k];
		$y2p = $yfs[$k];
	    }

	    $k++;
	}

        # force the nodes of the faults to connect
	# if this is not the first element, make x1, y1 equal to previous x2, y2
	if ($elem ~~ @first_felems)
	{
	    $x2p_prev = $x2p;
	    $y2p_prev = $y2p;
	}
	else
	{
	    $x1p = $x2p_prev;
	    $y1p = $y2p_prev;

	    $x2p_prev = $x2p;
	    $y2p_prev = $y2p;
	}
	

	# if the coorindates are close, then don't add
    my $dist = sqrt(($x1p-$x2p)**2+($y1p-$y2p)**2);
	my $line = '';
	if ($dist > $elem_len/4)
	{
	    push(@xfs, $x1p); 
	    push(@xfs, $x2p);
	    push(@yfs, $y1p);
	    push(@yfs, $y2p);
	    push(@fcs, $fc);
	    push(@fcs, $fc);
	
	    my $prev_line = $f_lines[$i];
	    my $coors = sprintf("%.6f", $x1p)." ".sprintf("%.6f", $y1p)." ".sprintf("%.6f", $x2p)." ".sprintf("%.6f", $y2p);

	    # replace place holder with new coordinates
	    $line = $prev_line;
	    $line =~ s/COORS/$coors/g;	
	}
	# if the pts of the element are too close together
	# don't add this element, make previous coordinates equal to end 1
	else
	{
	    $x2p_prev = $x1p;
	    $y2p_prev = $y1p;
	}

	# if this element is the first fault element, then add a marker
	if ($elem ~~ @first_felems)
	{
	    $line = "FAULT_$f_i\n".$line;
	    #print "$f_i \n";
	    $f_i = $f_i+1;
	}

	$f_new_lines = $f_new_lines.$line;

	$i++;
    }

    my @flines = split(/\n/, $f_new_lines);
    my $fi = -1;

    my $file_lines = '';
    # read in input file
    # add in new boundary lines in appropriate place

    open FILE_HANDLER, $filein or die $!;

    my $replace_f = 0;
    my $replace = 0; # have not replaced the lines yet
    $found = 0; # have not found the boundary lines yet
    $foundf = 0;

    $f_i = 0; # number of faults found so far
    while (<FILE_HANDLER>)
    {
	my $line = $_;
	my @data = split(/\s+/, $line);

	# if line is part of boundary lines, then ignore, and put place marker
	if ($line =~ /\*Boundary\s+Lines/)
	{
	    $found = 1;
	}
	elsif ($line =~ /^fault\s+/)
	{
	    $found = 0;
	    if ($replace_faults)
	    {
		$foundf = 1;
		$replace_f = 0; # have not replaced this fault
		$f_i=$f_i+1; # add to number of faults
	    }
	}
	# adjust the number of boundary lines
	elsif ($line =~ /^nblines\s+=/)
	{
	    $line = 'nblines =   '.$num_lines."\n";
	}
	# if found the boundary lines
	elsif ($found && $line =~ /\d/ && scalar(@data)==10) 
	{
	    if ($replace == 0) # if have not replaces boundary lines yet
	    {
		$line = $new_lines;
	    }
	    else # if have replaces them
	    {
		$line = '';
	    }

	    $replace = 1;
	}
	elsif ($foundf && $line =~ /\d/ && scalar(@data)== $fline_in_len)
	{
	    # replace preexisting COORs with new

	    if (!$replace_f)
	    {
		my $search1 = 'FAULT_'.$f_i;
		my $search2 = 'FAULT_'.($f_i+1);	

		my $fault_curr = '';
	        while ($fi < scalar(@flines)-1)
		{
		    $fi++;
		    my $fline = $flines[$fi];
		    if ($fline =~ $search1)
		    {
			$foundf = 1;
		    }
		    elsif ($fline =~ $search2)
		    {
			last; # exit loop if found the search line
		    }
		    elsif ($foundf)
		    {
			$fault_curr = $fault_curr.$fline."\n"; 
		    }
		}

		# replace all the 'PROPS' place holders with values in the input file
		my $props = $data[5]." ".$data[6]." ".$data[7]." ".$data[8]." ".$data[9]." ".$data[10]; # only works with homogeneous fault props

		if ($fline_in_len > 11) # if not sandbox get al the properties
		{
		    $props = $data[5]." ".$data[6]." ".$data[7]." ".$data[8]." ".$data[9]." ".$data[10]." ".$data[11]." ".$data[12]; 
		}

		$fault_curr =~ s/PROPS/$props/g;

		# remove FAULT tag if it exists...although it shouldn't exist...

		$replace_f = 1;
		$line = $fault_curr;
	    }
	    else # if have already replaced this fault
	    {
		$line = '';
	    }
	
	}

	$file_lines = $file_lines.$line;
    }

    close FILE_HANDLER;

    # write to new file

    open my $filehandle, '>', $filein_update;
    print {$filehandle} $file_lines;
    close $filehandle;

    # write to the new topography file
    # if we found the lines
    if ($topo_filename && $topo_lines)
    {
	$topo_lines = $topo_lines."end\n\n";
	open my $handle, '>', $filetopo_new;
	print {$handle} $topo_lines;
	close $handle;
	return $filetopo_new;
    }

    return $topo_filename;
    
}


#   my $run_mode = get_run_mode($input_filename, $ARGV[-2], $ARGV[-1]);
# input: fric2d input filename, last two input arguments (to check if debugging)
# output: string representing mode that we are running
sub get_run_mode
{
    my ($file, $arg1, $arg2) = @_;
    
     # open file, or send error message 
    open FILE_HANDLER, $file or die $!;

    # signal whether saw flaw title
    my $is_flaw = 0;
    my $fault_after_flaw = 0;
    my $no_break = 1;
    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {
    	my $line = $_; 	
	if ($line =~ /^\*Flaw/) 
	{
	    $is_flaw = 1;
	    $no_break = 1;
	}
	elsif ($is_flaw && $no_break && $line =~ /^fault/)
	{
	    $fault_after_flaw = 1;
	}
	elsif ($is_flaw && !$fault_after_flaw && ($line =~ /^\n/ || $line =~ /^\s+\n/))
	{
	    $no_break = 0;
	}
    }

    # close the file
    close FILE_HANDLER;

    # if found one flaw, that is not followed by a *Crack line
    #   this implementation will set the runmode to
    #   sandbox if *Flaw in input file, and is not followed by *Crack
    # if the user chooses to grow from a point
    #   and run the regular fric2d, 
    #   the calc_work function will determine whether to run fric2d or sandbox
    #   by whether the user includes a topo file
    if (!$fault_after_flaw && $is_flaw)
    {
	# if running in debug mode
	if ($arg1 =~ /DB/ || $arg2 =~ /DB/)
	{
	    return "sand debug";
	}
	# if running with a topography file (or without), run sand if found flaw
	#if ($arg1 =~ /\.topo/ || $arg2 =~ /\.topo/)
	#{
	    return "sand";
	#}

    }

    # if did not find flaw
    
    # if debuggin
    if ($arg1 =~ /DB/ || $arg2 =~ /DB/)
    {
	return "debug";
    }

    # if not growing from point, and not debuggin
    return "fric";
}

# normalize work by length of newly added element (or elements)
# called: $curr_work = normalize_work($curr_work, $testing_filename, $prev_filename);
# input: value of Wext calculated, testing filename
# output: input Wext/length of propagating fault
sub normalize_work
{
    my ($prev_work, $work, $testing_filename, $prev_filename) = @_;
    
    # if calculating normalized work value, just report Wext value
    if ($prev_filename eq "")
    {
	return $work;
    }
	
    # get the end points of all the faults growing in current increment of growth
    my ($a, $fault_ref_curr) = get_end_points($testing_filename);
    # get end points of previous faults
    my ($b, $fault_ref_prev) = get_end_points($prev_filename);
	
    # for all of the end points of the growing fault
    # calculate distance 
    my %fault_hash_curr = %$fault_ref_curr;
    my %fault_hash_prev = %$fault_ref_prev;
	
    # get the length of faults in current (testing) filename
    my $length_curr = 0;
    foreach (keys %fault_hash_curr)
    {
	my $fault = $_;
	my @end_pts = split(/\n/, $fault_hash_curr{$fault}); 

	# for each line of 'xb yb xe ye'
	foreach(@end_pts)
	{
	    # convert string to arrays
	    my ($xb, $yb, $xe, $ye, $foo) = split(/\s+/, $_);
	    $length_curr = $length_curr + sqrt(($xb-$xe)**2 + ($yb-$ye)**2);	    
	}
    }

    # get the length of faults in previous filename
    my $length_prev = 0;
    foreach (keys %fault_hash_prev)
    {
	my $fault = $_;
	my @end_pts = split(/\n/, $fault_hash_prev{$fault}); 

	# for each line of 'xb yb xe ye'
	foreach(@end_pts)
	{
	    # convert string to arrays
	    my ($xb, $yb, $xe, $ye, $bar) = split(/\s+/, $_);
	    $length_prev = $length_prev + sqrt(($xb-$xe)**2 + ($yb-$ye)**2);	    
	}
    }
	
    my $del_length = $length_curr - $length_prev;
 
    # if no change in length of faults, then no change in work
    #   so return work - prev_work, which should be close to 0
    if (abs($del_length) < 1e-10)
    {
	
	return $work-$prev_work; 
    }

    # do not return absolute value of difference in work
    # because sometimes current work > prev_work with no slip on added faults
    # so if using displacements, this ensures correct optimum work value selected
    return ($work-$prev_work)/$del_length;
}


# returns true if the most efficient scenario minimizes work
# called:    my $is_minimizing = get_efficient_criteria($prev_filename);
# input: name of file
# output: true if minimizing work, false otherwise
sub get_efficient_criteria
{
    my @file = @_;

    my $is_serial = 0; # assume not running serially, unless otherwise specified
    my $is_update_topo = 0;
    my $is_continue_check = 0;
    my $is_limit = 0; # limit checking to top 10% of max KI
    my $is_branch = 0;

    # open file, or send error message 
    open HANDLER, "@file" or die $!;

    # minimizing work if using displacement conditions (and all other bc = 0)
    # maximize work if using stress conditions (and all other bc = 0)

    # find the value of knode of the boundary condition
    # that has non-zero stresses or displacements

    # assumes that each non-zero boundary with have same knode value
    my $read_bound = 0;
   # my %nodes;
    my $is_disp_bc = 2; # initialize to not real value
    my $prev_disp = $is_disp_bc;
    READ: 
    { while (<HANDLER>)
      {
	  my $line = $_;
		
	  my @info = split(/\s+/, $line);

	  # if line begins with *Boundary Lines, set flag to reading bounds
	  if ($line =~ /\*Boundary\s+Lines/ || $line =~ /\*BOUNDARY\s+LINES/)
	  {
	      $read_bound = 1;
	  }
	  # if line begins with *Boundary Lines, set flag to reading bounds
	  elsif ($line =~ /\*Update\s+=\s+/)
	  {
	      if ($line =~ /\*Update\s+=\s+YES\s+/)
	      {
		  $is_update_topo = 1;
	      }
	      elsif ($line =~ /\*Update\s+=\s+NO\s+/)
	      {
		  $is_update_topo = 0;
	      }
	  }
	  elsif ($line =~ /\*Continue_Check\s+=\s+/)
	  {
	      if ($line =~ /\*Continue_Check\s+=\s+YES\s+/)
	      {
		  $is_continue_check = 1;
	      }
	      elsif ($line =~ /\*Continue_Check\s+=\s+NO\s+/)
	      {
		  $is_continue_check = 0;
	      }
	  }
	  elsif ($line =~ /\*Run_Mode\s+=\s+/)
	  {
	      if ($line =~ /\*Run_Mode\s+=\s+SERIAL\s+/)
	      {
		  $is_serial = 1;
	      }
	      elsif ($line =~ /\*Run_Mode\s+=\s+SEQUENTIAL\s+/)
	      {
		  $is_serial = 0;
	      }
	  }
	  elsif ($line =~ /\*Limit_Test\s+=\s+/)
	  {
	      if ($line =~ /\*Limit_Test\s+=\s+YES\s+/)
	      {
		  $is_limit = 1;
	      }
	      elsif ($line =~ /\*Limit_Test\s+=\s+NO\s+/)
	      {
		  $is_limit = 0;
	      }
	  }
      elsif ($line =~ /\*Branch_faults\s+=\s+/)
      {
          if ($line =~ /\*Branch_faults\s+=\s+YES\s+/)
          {
          $is_branch = 1;
          }
          elsif ($line =~ /\*Branch_faults\s+=\s+NO\s+/)
          {
          $is_branch = 0;
          }
      }
	  # if we are reading the boundaries
	  # if line starts with a digit, and contains 10 digits
	  # if one of the shear or normal components is not zero, 
	  # add the knode value to the list
	  elsif ($line =~ /^\d/ && scalar(@info) == 10 
		 && (abs($info[-1]) < 1e-10 || abs($info[-2]) < 1e-10  || abs($info[-3]) < 1e-10  || abs($info[-4]) < 1e-10))
	  {	     
	      $read_bound = 1;
 
	      # assume the non-zero value is a shear component
	      my $is_shear = 1;
	      my $knode = $info[-5];

	      # find non-zero loading conditions
	      my $bc_s = $info[-2];
	      my $bc_n = $info[-1];
	      if ($info[-1] == 0 && $info[-2] == 0)
	      {
		  $bc_s = $info[-4];
		  $bc_n = $info[-3]
	      }

	      # displacement conditions if 
	      if (($knode == 2 && ($bc_s != 0 || $bc_n != 0)) || ($knode == 3 && $bc_s != 0) || ($knode == 4 && $bc_n != 0))
	      {
		  $is_disp_bc = 1;
	      }
	      # traction boundary conditions
	      elsif (($knode == 1 && ($bc_s != 0 || $bc_n != 0)) || ($knode == 3 && $bc_n != 0) || ($knode == 4 && $bc_s != 0))
	      {
		  $is_disp_bc = 0;
	      }

	      if (($prev_disp != 2 && $is_disp_bc != 2) && ($prev_disp != $is_disp_bc))
	      {
		  die "\nABORTING RUN: Using nonzero stresses and displacements in boundary conditions.\n\tMust use only stresses or displacements.\n";
	      }

	      $prev_disp = $is_disp_bc;

	  }
     
	  # if reading the bounds and this line is a carriage return
	  # exit the loop
	  elsif ($read_bound && $line eq "\n")
	  {
	      last READ;
	  }  
      }
    }

    close HANDLER; 

    if ($read_bound == 0)
    {
	 die "COULD NOT FIND BOUNDARY CONDITIONS\n\tBe sure to include '*Boundary Lines' header in input file at start of line: @file \n";
    }

    if ($is_disp_bc == 2)
    {
	 die "COULD NOT FIND NONZERO BOUNDARY CONDITIONS\n\tCannot determine if GROW should maximize or minimize work in file: @file \n";
    }

    return ($is_disp_bc, $is_serial, $is_update_topo, $is_continue_check, $is_limit, $is_branch); 

}

# 
# called:  my @fault_name = get_fault_names($prev_filename); 
# input: name of a file
# output: list of faults with end that they are propagating from appended
#         if propagating from both sides, then list contains "fault 1", "fault 2"
sub get_fault_names
{
    my @file = @_;

    # remember the name of the faults and the direction of growing
    my @faults; 
    
    # open file, or send error message 
    open FILE_HANDLER, "@file" or die $!;

    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {

    	my $this_Line = $_; 
	
        # if the line starts with the word "fault", 
	# remember how the fault is growing
	if ( $this_Line =~ /^fault\s/ ) #|| $this_Line =~ /^\*flaw/ ) 
	{     
	    
	    my ($el, $name , $grow_tail, $from_end1, $from_end2) = 
		split(/\s+/, $this_Line);

	   
	    if ($from_end1 eq "yes" && $from_end2 eq "yes")
	    {
		push(@faults, $name." 1");
		push(@faults, $name." 2");
	    }
	    elsif ($from_end1 eq "yes")
	    {
		push(@faults, $name." 1");
	    }
	    elsif ($from_end2 eq "yes")
	    {
		push(@faults, $name." 2");
	    }
	    
	}


    }

    # close the file
    close FILE_HANDLER;

    # return the information
    return @faults;
    
}


# called:  my @fault_name = get_flaw_names($prev_filename); 
# input: name of a file
# output: list of faults with end that they are propagating from appended
#         if propagating from both sides, then list contains "fault 1", "fault 2"
sub get_flaw_names
{
    my @file = @_;

    # remember the name of the faults and the direction of growing
    my @faults; 
    
    # open file, or send error message 
    open FILE_HANDLER, "@file" or die $!;

    # signal whether saw flaw title
    my $found_flaw = 0;
    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {

    	my $this_Line = $_; 
	
	if ($this_Line =~ /^\*Flaw-Intact\s/)
	{
	    my @info = split(/\s+/, $this_Line);
	    # always assume that the flaw is growing from end 2
	    push (@faults, $info[1]." 2");
	    $found_flaw = 1;
	}
	# if found flaw in previous line and this line starts with fault, 
	# then don't need to search from a point because a crack exists
#	elsif($found_flaw && $this_Line =~ /^fault\s+/)
	#{
	#    $found_flaw = 0;
	    # remove last element added 
	#    pop(@faults);
	#}
	# if found flaw in previous line
	#elsif ($found_flaw)
#	{
	 #   $found_flaw = 0;
#	}

    }

    # close the file
    close FILE_HANDLER;

    # return the information
    return @faults;   
}

# called:($flaw_x, $flaw_y, $length) = get_flaw_info($prev_filename, $fault_name);
# input: name of the file, name of fault from which growing point
# output: x-coordinate, y-coordinate and length given by the user, properties of rock given by user
sub get_flaw_info
{
    my ($file, $fault_name) = @_;
    
    # open file, or send error message 
    open FILE_HANDLER, "$file" or die $!;

    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {
    	my $this_Line = $_; 	
        # if the line starts with the word "fault", 
	# remember how the fault is growing
	if ($this_Line =~ /\*Flaw-Intact\s+$fault_name\s+/) 
	{     
	    # close the file, return info
	    close FILE_HANDLER;
	    my @info = split(/\s+/, $this_Line);
	    return @info[2..4];
	}
    }
}

#############################################################
#FUNCTIONS TO RETURN THE SCENARIO THAT OPTIMIZES WORK
#############################################################


# input: reference to list of angles, and absolute value of delwextdelA, percent and max/min for forecasting
# output: interpolated angle (rounded to nearest degree) representing that percent and max or min range of envelope
sub get_interp_angle
{
    my ($ang_ref, $delwextA_ref, $percent, $forecast) = (@_);

    my @angs = @$ang_ref;
    my @delwextA = @$delwextA_ref; 

    my $delwextA_max = max_list(@delwextA);
    # set envelop range as some percent between max and min value
    my $delwextA_min = min_list(@delwextA);
    if ($delwextA_min < 0) # this should not happen because using absolute value of delwextdelA
    {
	$delwextA_min = 0;
    }

    #my $delwextA_env = ($delwextA_max-$delwextA_min)*$percent + $delwextA_min;

    my $delwextA_env = ($delwextA_max)*$percent;
    
    my $i = 0;
    my $ang1 = 0;
    my $ang2 = 0;
    my $delwextA1 = 0;
    my $delwextA2 = 0;
    my $found_angs = 0;
    # find angles in wext equal or above percent value
    while ($i < $#angs && !$found_angs)
    {	
	my $curr_delwextA = $delwextA[$i];
	my $curr_ang = $angs[$i];

	if (($delwextA[$i] <= $delwextA_env && $delwextA[$i+1] >= $delwextA_env && $forecast =~ /min/) ||
	    ($delwextA[$i] >= $delwextA_env && $delwextA[$i+1] <= $delwextA_env && $forecast =~ /max/))
	{
	    $ang1 = $angs[$i];
	    $ang2 = $angs[$i+1];
	    
	    $delwextA1 = $delwextA[$i];
	    $delwextA2 = $delwextA[$i+1];

	    if ($forecast =~ /min/)
	    {
		$found_angs = 1;
	    }
	}

	$i++;
    }

    # if we did not find max and min angles, return limit of testing range
    # because max delwextA is max angle, and finding max extent
    # because max delwext is min angle, and findinng min extent
    # other cases?
    my $angle_interp= 0;
    if (!$found_angs && !$ang1)
    {
	if ($forecast =~ /min/)
	{
	    # return minimum angle
	    $angle_interp = $angs[0];
	}
	else
	{
	    # return largest angle
	    $angle_interp = $angs[-1];
	}
    }
    else
    {
	# find slope and y-intercept of line between two data points
	my $m = ($delwextA2-$delwextA1)/($ang2-$ang1);
	my $b = $delwextA1 - ($m*$ang1);

	$angle_interp = (($delwextA_env - $b)/$m);
	
    }

    my $angle_interp_round = sprintf("%0.2f", $angle_interp);
    return $angle_interp_round;

}

# input: reference to hash table containing scenario index numbers
#        => work at this iteration, whether work should be min or maxed, if minimizing or max
# output:  index,  work calced, use linear interp between wext values
#        
sub get_wext_forecast
{
    my ($hash_ref, $forecast, $is_min, 
	$root, $prop_num, $formatted_fault,
	$fault,	$prev_filename, $topo_filename, $raw_output, $out_raw_filename,
	$prev_prop_work, $prev_prop_filename, $is_sand, $run_mode) = @_;

    my %hash = %$hash_ref; 
       
    # make this an input at some point
    my @fore_data = split(/\s+/, $forecast);
    my $percent = $fore_data[-1];

    # make list of delwexts/A and angles from hash table
    my @angs = ();
    my @delwextA = ();

    # sort keys in hash by smallest to largest
    foreach my $scen_index (sort {$a <=> $b} keys %hash)
    {
	push(@angs, $scen_index);
	push(@delwextA, abs($hash{$scen_index})); # reported delwext/A neg if applied disp

    }

    my $interp_angle = get_interp_angle(\@angs, \@delwextA, $percent, $forecast);

    # make input file with new element at interpolated angle, at this fault
    # create the hash table that describes this scenario
    # make the testing filename (fric2d input and output files)
    my $testing_filename = $root."_".$prop_num."_".$formatted_fault."_".$interp_angle.".in";
    my $fric_output_filename = $root."_".$prop_num."_".$formatted_fault."_".$interp_angle.".out";
	    
    my $pair_ref = {$fault => $interp_angle} ;	    	    

    # make the input file that represents this scenario at $testing_filename 
    make_input_file_scenario($prev_filename, $testing_filename, 
			     $pair_ref, $is_sand);	    

    # get number of structures that could be possibly intersecting
    my $structure_num = get_intersect_structs($testing_filename);
    my $fault_intersect = correct_intersections($testing_filename, $pair_ref, 0, $structure_num);

    # calculate work of this new geometry
    my $interp_work_unnorm;
    my $interp_work;
    my $result; 
    if ($fault_intersect<0)
    {
	# print statement
	$result = "No work calculated => A fault intersects itself, or could not correct all intersections";
	
    }
    # if a fault does not  intersect itself
    else
    {	
	# calculate the work
	my $curr_work = calc_work($run_mode, $testing_filename, 
			       $fric_output_filename, $topo_filename); 

	if ($curr_work eq "nan")
	{
	    die "FRIC2D ERROR: Work calculated as nan for file: $fric_output_filename \n";
	}
	if (!$curr_work)
	{
	    die "PASSING ERROR: Work was not passed, or not calculated. \n";
	}

	# normalize work by total length of propagating fault ## now normalize by newly added fracture area
	# record not normalized work
	$interp_work_unnorm = $curr_work;
	# normalize work
	#$interp_work = normalize_work($prev_prop_work, $interp_work_unnorm, $testing_filename, $prev_prop_filename); 
	#print "normalizing while forecasting \n";			
	$interp_work = normalize_work($prev_prop_work, $interp_work_unnorm, $testing_filename, $prev_prop_filename); 
	
	# print statement
	$result = "$interp_work_unnorm\t$interp_work";
    }
    
    print "\nINTERPOLATED RESULTS\n";
    # print statements, also print these?
    my $print_screen_summary = format_std_out($fric_output_filename, 
					      $prop_num, $result, $fault, $interp_angle);
    $raw_output = $raw_output."\n\n".$print_screen_summary;
    write_output($out_raw_filename, $raw_output);


    if ($interp_angle && $interp_work && $interp_work_unnorm)
    {
	return ($interp_angle, $interp_work, $interp_work_unnorm);
    }

    # if wext function fails, calculate as absolute max or min
    # stop process
    die "Could not find envelope angle.\n";

}

#my @inters = ();
#my %works = (90 => 3, 100 => 4, 120 => 100, 130 => 3, 140 => 4, 150 => "nan", 200 => -2);
#my %cnums = (90 => 1e4, 100 => 1e4, 120 => 1e4, 130 => 1e10, 140 => 1e4, 150 => "Inf", 200 => 1e4);
#my ($ang, $work) = get_opt_scenario(\%works, \@inters, \%cnums, 1);
#print $ang." ".$work."\n";

sub median
{
    my @list = @_;

    if ((scalar @list) == 0)
    {
	return 0;
    }

    my @list_cl = ();
    foreach (@list)
    {
	my $n = $_;
	if (looks_like_number($n) && ($n ne "nan") && ($n ne "inf"))
	{
	    push(@list_cl, $n);
	}
    }
    

    my @vals = sort {$a <=> $b} @list_cl;
    my $len = @vals;
    if ($len%2)
    {
	return $vals[int($len/2)];
    }
    else
    {
	return ($vals[int($len/2)-1] + $vals[int($len/2)])/2;
    }
}

# input: reference to hash table containing scenario index numbers
#        => work at this iteration
# output: scenario of minimum index,  minimum work calculated, 
sub get_opt_scenario
{
    my ($work_prev, $hash_ref, $inter_ref, $cond_ref, $is_min, $is_topo) = @_;
    my %hash_all = %$hash_ref; 
    my %hash_cond = %$cond_ref;
    my @inters = @$inter_ref;

    # keys can be angles or files
    my $is_bias = 0; # bias by chosing intersecting geometries

    my %hash = %hash_all;
    # if there any intersections
    # make new hash table containing only those geometries
    if ($is_bias && scalar(@inters))
    {
	foreach my $file (sort keys %hash_all)
	{
	    # if file in inters list then add to new hash
	    if ($file ~~ @inters)
	    {
		$hash{$file} = $hash_all{$file};
	    }
	}

	# if the hash is empty, then set it to the original
	# occurs when intersecting elements do not slip
	if (!%hash)
	{
	    %hash = %hash_all;
	}

    }


    # remove the values of work that are outliers
    my %hash_clean = %hash;
    my @works = ();
    my @conds = ();
    # remove works with high condition numbers before considering in median calc
    foreach my $ind (keys %hash_cond)
    {	
	push(@conds, $hash_cond{$ind});
    }

    my $med_c = median(@conds);
    my $lim_c = 5*$med_c;

    print "\nSelecting fault configurations using condition number and Wext:\n";
    print "Median and limiting condition numbers: $med_c, $lim_c \n";

    # loop through work values
    foreach my $ind (keys %hash)
    {
	my $work = $hash{$ind};
	my $del_work = $work-$work_prev;

	if (exists $hash_cond{$ind} && $work >0 && (!$is_topo && $is_min && $del_work>0 || !$is_topo && !$is_min && $del_work<0))
	{
	    my $cnum= $hash_cond{$ind};
	    if ($cnum < $lim_c && looks_like_number($work) && ($work ne "nan") && ($work ne "inf"))
	    {
		push(@works, $work);
	    }
	}

    }

    # if there are some work calculations
    # remove the work values > 10 times the median, 
    # and the values with condition numbers > 5 the medain
    if (scalar @works >0)
    {
	my $med = median(@works);
	my $lim = 10*$med;      
	print "Median and limiting Wext: $med $lim \n";

	foreach my $ind (keys %hash)
	{
	    my $work = $hash{$ind};
	    my $cnum = 0;
	    if (exists $hash_cond{$ind})
	    {
		$cnum = $hash_cond{$ind};
	    }
	    if ($work > $lim || $work < 0 || $cnum > $lim_c)
	    {
		delete $hash_clean{$ind};
	    }
	}

	%hash = %hash_clean;
    }

    
    print "Following filtering, considering for growth:\n";
    foreach my $ind (sort {$hash{$a} <=> $hash{$b}} keys %hash)
    {
	print $ind." ".$hash{$ind}."\n";
    }


    if ($is_min)
    {
	# sort keys in hash by smallest to largest, return smallest value
	foreach my $scen_index (sort {$hash{$a} <=> $hash{$b}} keys %hash)
	{
	    return ($scen_index, $hash{$scen_index});
	}
    }
    else
    {
	# sort keys in hash by smallest to largest, return smallest value
	foreach my $scen_index (sort {$hash{$b} <=> $hash{$a}} keys %hash)
	{
	    return ($scen_index, $hash{$scen_index});
	}
    }

    #if the hash is empty, then no minima was calculated
    # because no slipping elements
    return (-1, -1); 
 
}


###################################################################
#FUNCTIONS TO CALCULATE THE GEOMETRY OF NEW COORDINATES
####################################################################


# test if the number is actually zero presented in the computer
# and reformat to 8 decimals
sub check_number; 

# called:   @old_geo = get_init_geometry($flaw_x, $flaw_y, $length); 
# input: coordinates of the end of initial microcrack
# output: coordinates of beginning and end of hypothetical crack and length
#        x coor of end of  crack is always < than x coor of beg   
sub get_init_geometry
{
    my ($input_x, $input_y, $length) = @_;
 
    my $begx = $input_x - $length;

    # coordinates inputted by the user are always
    # the end of the element from which new cracks will grow
    return ($begx, $input_y, $input_x, $input_y, $length); 

}

# get any digits in a string separated by white space
sub get_digits;
# get coordinates of head and tail of element that will propagate pup crack
#   and the length of the new element (m)
sub get_geometry;

# get coordinates of head and tail of element that will propagate pup crack
#        and the length of the element
# called:  @old_geo = get_geometry
#		($prev_filename, $fault_name, $curr_end);
# input: filename of FRIC2D input file, the end of the fault we are growing from
# output: coordinates of the beginning and end of the pup crack, length of the element
sub get_geometry
{
    my ($file, $fault_name, $curr_end) = @_; 

    # variable used to accumulate the info related to one fault
    my $this_Fault_Geo = ''; 

    # set the initial value of found fault to false
    my $found_Fault = 0; 
	
    # open file, or send error message 
    open FILE_HANDLER, "$file" or die $!;
	
    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    while (<FILE_HANDLER>)
    {
	my $this_Line = $_; 
	my @info = split(/\s+/, $this_Line);

        # if a line read in before contained "fault",
	# signifying the start of a fault geometry
	# and this line is not a new line
	# and this line does not describe the crack characteristics
        # remember this information
	if ($found_Fault && scalar(@info) > 10 &&  $this_Line =~ /^\d+\s+/)
	{
	    $this_Fault_Geo = $this_Fault_Geo.$this_Line;
	}
        # if the line starts with the word "fault", 
	# and contains the name of the fault
	elsif ($this_Line =~ /^fault\s+$fault_name\s+/) 
	{     
	    $this_Fault_Geo = $this_Fault_Geo.$this_Line;

	    # signify that this fault was found
	    $found_Fault = 1;

	}     
	# if line starts with "fault" and the name of fault that is not the current fault
	elsif ($this_Line =~ /^fault\s+/)
	{
	    $found_Fault = 0;
	}
	elsif ($this_Line =~ /^\n/)
	{
	    $found_Fault = 0;
	}
	
    }

    # close the file
    close FILE_HANDLER;

    # return the coordinates of the new pup crack
    #print "this fault: \n$this_Fault_Geo \n";

    my @this_Fault_Data = split(/\n+/, $this_Fault_Geo);

    # remove white spaceß
    my @flines = ();
    foreach (@this_Fault_Data)
    {
	my $line = $_;
	if (scalar(split(/\s+/, $line))>2)
	{
	   push(@flines, $line."\n");
	}
    }
    @this_Fault_Data = @flines;
    #print "last crack: \n$this_Fault_Data[-1] \n";

    # if propagating from end1 (beginning of the last crack)
    # then this is the second line of the fault info
    my $last_Crack = $this_Fault_Data[1];
    if ($curr_end > 1)
    {
	$last_Crack = $this_Fault_Data[-1];
    }

    #print "last crack: $last_Crack \n";
    # get the geometry of the last crack generated
    my ($num, $xbeg, $ybeg, $xend, $yend) = get_digits($last_Crack);  

    # calculate the relative location of 
    # of this fault
    my $dx = ($xend - $xbeg)/$num;
    my $dy = ($yend - $ybeg)/$num;

    if ($curr_end == 1)  
    {
	my $x = $xbeg+$dx;
	my $y = $ybeg+$dy;
	my $length = sqrt(($x-$xbeg)**2+($y-$ybeg)**2);

	return ($x, $y, $xbeg, $ybeg, $length);
    }
    else
    {
	my $x = $xend-$dx;
	my $y = $yend-$dy;
	my $length = sqrt(($x-$xend)**2+($y-$yend)**2);

	return ($x, $y, $xend, $yend, $length);
    }

}


# called:  my ($num, $xbeg, $ybeg, $xend, $yend) = get_digits($last_Crack);  
# input: string with digits separated by white space
# output: array of any digits in this string
sub get_digits
{
    my @input = @_;
    my @info = split(/\s+/, join("", @input));
 
    
    my @digits;
    foreach(@info)
    {
	my $index = $_;
	if ($index =~ /[-+]?[0-9]*\.?[0-9]+/)
	{
	    push(@digits, $index);
	  }
    }
    
    return @digits; 
    
}

sub check_zero;

# get the coordinates of the new element
sub get_coors_pup;

# called:   my @new_coors = get_coors_pup($curr_angle, @old_coors);
# input: the current angle to propagate the new pupative crack, 
#        the coordinates of the beginning and end of the crack
#        (xbeg, ybeg, xend, yend) 
#        (the beginning of an element, the end of the element)
#        new cracks should connect to the end of the element
# output: the coordinates of the head of the new pup crack (x,y)
sub get_coors_pup
{
    # get the input
    my $angle_Degrees = $_[0];
    my $elem_x = $_[1]; 
    my $elem_y = $_[2];
    my $ex = $_[3];
    my $ey = $_[4];

    my $pi = 3.14159265358979323846264338327950288419716939937510582;
	
    $elem_x = check_number($elem_x);
    $elem_y = check_number($elem_y);
    $ex = check_number($ex);
    $ey = check_number($ey);

    # get the distance between the head and tail of the pup
    my $d = sqrt(($elem_x-$ex)**2 + ($elem_y-$ey)**2);

    # get the angle in radians
    my $angle_Rad = $angle_Degrees * ($pi/180);

    # init variables to calculate correct angle measure for 
    # parametric equations
    my $t;

    # get the angle between the end points
    my $theta;

    # find the correct angle to use in the parametric eqs
    
    # if the segment is vertical
    if ($elem_x == $ex)
    {
	$theta = $pi/2; 
    }
    # if the segment is not vertical
    else
    {
	$theta = atan(($elem_y-$ey)/($elem_x-$ex)) ;
    }
    
    $t = 2*$pi + $theta - $angle_Rad; 
    
    if ($ey > $elem_y && $elem_x == $ex) ## new addition for shits and gigs
    {
	$t = $t + $pi;
    }
    
    if ($elem_x < $ex)
    {
	$t = $t + $pi;
    }   
    
    # find the coordinates of the head of new pup from 
    # the parametric equation of a circle
    my $x = $ex + ($d*cos($t));
    my $y = $ey + ($d*sin($t));

    # make sure that -0.000 is not being reported as a number
    $x = check_zero($x);
    $y = check_zero($y);

    return ($x, $y); 

} 

sub check_zero
{
    my ($num) = @_;

    if (abs($num) < 1e-15)
    {
	return 0; 
    }
    
    return $num; 
}

#################################################
# FUNCTIONS TO DETERMINE IF ANY NEW ELEMENTS SLIPPED
# I.E. SATISFY THE COULOMB CRITERION
#################################################

sub is_Coulomb_slip;
sub list_contains;
sub get_slip_numbers;
sub get_element_numbers;
sub is_hash_equal;

# get the sequence of angles to test for all faults
#    my %testing_sequences = get_tuned_sequence($fault_angle_ref, $angle_inc);   
# input: reference to hash table containing most efficient geometry 
#            found before tuning step
#        angle increment to search away from efficient angle
# output: hash table fault 1 => list of angles to test in tuning sequence
#        this hash table can be empty if all the faults are no longer growing
sub get_tuned_sequence
{
    my ($ref, $inc) = @_;

    my %hash = %$ref;
    my %tuned;
    foreach my $fault (sort keys %hash)
    {
	my $angle = $hash{$fault};
	if ($angle > 0)
	{
	    @{$tuned{$fault}} = ($angle-$inc, $angle, $angle+$inc);
	}
    }

    return %tuned;

}


#     ($new_scenarios_ref, $scen_num) = remove_tested_scenario($new_scenarios_ref, $tested_scenarios_ref); 
# input: reference to scenario hash table describing new scenarios to be tested
#        reference to hash table describing previously tested scenarios
# output: reference to updated hash table, total new number of scenarios
sub remove_tested_scenario
{
    my ($new_ref, $old_ref) = @_;
    my %new_scenarios = %$new_ref;
    my %old_scenarios = %$old_ref;
    my %removed_scenarios = %new_scenarios; 

    my $removed = 0;
    my $total;

    # after new_index erased when old_index matched, still stuck in old index for loop
    foreach my $new_index (sort keys %new_scenarios)
    {
	# while there are old scenarios to test, and the new scenario exists
	while (($_, my $old_ref) = each (%old_scenarios))
	{

	    my %new_geometry = %{$new_scenarios{$new_index}};
	    my %old_geometry = %$old_ref;
	    
	    my $is_equal = is_hash_equal(\%old_geometry, \%new_geometry);  
	    # if the hashes are equal, then delete scenario from hash table
	    if ($is_equal)
	    {
		delete $removed_scenarios{$new_index};
		$removed = $removed + 1;
		
		print "REMOVING SCENARIO PREVIOUSLY TESTED $new_index \n"; 
		foreach my $fault (sort keys %new_geometry)
		{
		    printf "\t%-15s %-15s\n", $fault, $new_geometry{$fault};
		}
		print "\n";
	    }
	    
	}
	# keep track of the largest index found
	$total = $new_index;
    }
    
    return (\%removed_scenarios, $total-$removed);
}

# called: my $is_equal = is_hash_equal(\%old_geometry, \%new_geometry);
# input: refernce to hash, reference to hash, both string -> digit
# output: true if hashes are equal, false if otherwise
sub is_hash_equal
{
    my ($ref1, $ref2) = @_;
    my %hash1 = %$ref1;
    my %hash2 = %$ref2;

    # if hashes have different number of keys, not equal
    if ((scalar keys %hash1) != (scalar keys %hash2))
    {
	return 0; 
    }

    foreach my $fault (sort keys %hash1)
    {
	if ($hash1{$fault} != $hash2{$fault})
	{
	    return 0;
	}
    }
    
    return 1; 
}


# called: %this_fault = remove_not_slipping_ineff($is_min, \%this_file, \%this_fault)
# input: angle_file: angle => file pairs
#  this_fault: angle=> work pairs for one fault
# output: scenario_work hash table with index, work pairs removed that do not contain a slipping elementm 
#          or inefficient elements that do not reduce work (if minimizing)
sub remove_not_slipping_ineff
{
    my ($is_min, $file_ref, $fault_ref) = @_;  
    my %angle_file = %$file_ref;
    my %angle_work = %$fault_ref;

    my @removed_angles = ();
    foreach my $angle (sort {$a <=> $b} keys %angle_file)
    {
	my $not_slipped_element = is_Coulomb_slip($angle_file{$angle});
	my $delwext_A = $angle_work{$angle};

	# remove index, work pair from index, work pairs
	if ($not_slipped_element)
	{
	    print "\nNewly added element not slipping/opening: $angle_file{$angle} \n"; 
	    push(@removed_angles, $angle); 
	    delete $angle_work{$angle};
	}
    }

    return %angle_work; 

}

# (my $ref, %file_work_unnorm) = remove_not_slipping_many(\%file_work_unnorm);
# input: hash with keys as files
# return 
sub remove_not_slipping_many
{
    my ($file_ref) = @_;  
    my %angle_file = %$file_ref;
    my %file_work = %angle_file;

    my @removed = ();
    foreach my $file (keys %angle_file)
    {
	my $out_file = substr($file, 0, -2)."out";
	my $not_slipped_element = is_Coulomb_slip($out_file);

	# remove index, work pair from index, work pairs
	if ($not_slipped_element)
	{
	    print "\nNewly added element not slipping/opening: $file \n"; 
	    push(@removed, $file); 
	    delete $file_work{$file};
	}
    }

    return (\@removed, %file_work); 

}

# function determines what elements were added by the name of the input file
#   and so will not check all the new elements in a tuning sequence
#   but we can assume that the name of the fault in the input file of a tuning sequence
#   is the fault that is being tuned, and the unmentioned fault(s) are oriented
#   at the most efficient orientation found in the broad search algorithm
# called: my $is_slipped = is_Coulomb_slip($index_file{$index});
# input: fric2d output filename
# output: true if the element(s) that were just added slipped
#         false otherwise
sub is_Coulomb_slip
{
    my ($out_file) = @_;

    my $in_file = substr($out_file, 0, -4).".in";

    # get the slipping element number(s) listed in the fric2d output file (at the end)
    my @slip_elements = get_slip_numbers($out_file); 

    # if there are no new slipping elements, return true (signalling no slipping element)
    if (scalar(@slip_elements) == 0)
    {
	return 1; 
    }

    # if there are slipping elements 
    # test to see if the newly added elements are slipping in the fric2d output file

    # find the name of the faults growing, 
    # and the end of the fault from which growing 

    # use name of file
    my @file_list = split('_', substr($out_file, 0, -4));
    my @growing = ("$file_list[-3] $file_list[-2]");

    # if could not find any faults growing (or connected to fault/boundary)
    if (!@growing)
    {
	die "ERROR: Could not find any growing faults to determine slipping elements in file: $out_file \n";
    }

    # for each fault and end listed, 
    # get the corresponding element number from the fric2d output file
    my @new_elements = get_element_numbers($out_file, @growing);

    # if could not find new elements
    if (!@new_elements)
    {
	die "ERROR: Could not find newly added elements in output file $out_file \n";
    }

    # returns element number of first newly added element not slipping
    # or false if all newly added elements are slipping
    return (not_all_slip(\@new_elements, \@slip_elements));
    
}


# called: my @slip_elements = get_slip_numbers($out_file);
# input: fric2d output filename
# output: list of elements that are slipping according to Coulomb
sub get_slip_numbers
{
    my ($file) = @_;
    my @elements = ();

    open HANDLE, "$file" or die $!;

    my $found_end_load = 0;
    my $found_slipping = 0;
    my $slipped_string = "";
    while (<HANDLE>)
    {	
	my $line = $_;
	
	if ($line =~ /^DATA FROM LOADING STEP #/)
	{
	    my @data_l = split(/\s+/, $line);
	    my $curr_l = $data_l[4];
	    $curr_l =~ s/#//g;
	    my $fin_l = $data_l[6];

	    if ($curr_l==$fin_l)
	    {
		$found_end_load = 1;
	    }

	}
	elsif ($found_end_load && $line =~ /The following frictional elements slipped in this loading step:/)
	{
	    $found_slipping = 1;
	}
	# if found slipping title and line begins with a new line
	# stop while loop
	elsif ($found_end_load && $line =~ /The following frictional elements opened in this loading step:/)
	{
	    $found_slipping = 1; 
	}
	# if found the slipping title and line contains a digit
	# add line to string of slipping elements
	elsif($found_slipping && $line =~ /\s+\d+\s+/)
	{
	    $slipped_string = $slipped_string.$line;
	}

    }

    close HANDLE;

    # split string by spaces
    my @data = split(/\s+/, $slipped_string);
    foreach my $element (@data)
    {
	# if element of data contains any non-digit, do not add to list
	if ($element =~ /\D/)
	{
	}
	elsif ($element =~ /\d/)
	{
	    push(@elements, $element);
	}
    }   
    return @elements;
}

sub get_first_last;



# called: my @new_elements = get_element_numbers($out_file, @fault_end)
# input:  fric2d output filename, list of fault" "end pairs
# output: list of element numbers of newly added elements
sub get_element_numbers
{
    my ($file, @fault_ends) = @_;
    my @elements = ();

    # read through fric2d output file and get first and last element listed
    # of all faults
    my %fault_element = get_first_last($file);

    # if growing the fault from end 1, use the first element, 
    # otherwise use the second element
    foreach my $fault (@fault_ends)
    {
	my ($name, $end) = split(/\s+/, $fault);

	if ($end == 1)
	{
	    push(@elements, $fault_element{$name}{"first"});
	}
	elsif ($end == 2)
	{
	    push(@elements, $fault_element{$name}{"last"});
	}
    }

    return @elements;
}

# called:  my %fault_element = get_first_last($file);
# input: fric2d output file
# output: hash table of fault name => first => element number
#                                    last  => element number
sub get_first_last
{
    my ($file) = @_;
    my %fault_elements;

    open HANDLE, "$file" or die $!;

    my $fault = 0;
    my $first = 0;
 
    while (<HANDLE>)
    {
	my $line = $_;
	my @info = split(/\s+/, $line);		

       # if the first element of info is not a number, pop it
	if (@info && !($info[0] =~ /\d+/))
	{
	    shift(@info);
	}

	# if see another fault
	# change name of fault being read in
	if ( $line =~ /^FAULT:/)
	{
	    $fault = $info[-1];
	    $first = 0; 
	}
	
	# if just started reading in fault info and line contains a digit
	# and have not seen first digit yet
	# add to the "first" slot of hash table
	elsif ($fault && !$first && $line =~ /^(\s+)?\d+\s+/)
	{	    
	    $fault_elements{$fault}{"first"} = $info[0];
	    $first = 1;
	}
	
	# if read in first slot and line begins with number
	# remember number, this will happen many times
	elsif ( $first && $line =~ /^(\s+)?\d+\s+/)
	{ 
	    $fault_elements{$fault}{"last"} = $info[0];	    
	}	
	  
	# stop reading in fault data,
	elsif ($line =~ /tip BE/)
	{
	    close HANDLE;
	    return %fault_elements;
	}

    }

    # in case closing line not found
    close HANDLE;
    return %fault_elements;

}
      
# called: list_contains(\@new_elements, \@slip_elements)
# input: reference to list of newly added elements, 
#        ref to list of all slipping elements in model
# output: element number of newly added element that is not slipping or
#        false if all newly added elements are slipping
sub not_all_slip
{
    my ($ref1, $ref2) = @_;
    my @new = @$ref1;
    my @slipped = @$ref2;
    
    foreach my $new_e (@new)
    { 
	# grep returns a list of all the element that match
	# the value of new_e, so if the length of this list = 0
	# then there are no matches
	if ($new_e)
	{
	    if (scalar(grep {$_ == $new_e} @slipped ) == 0)
	    {
		return $new_e;
	    }
	}
    }

    return 0;
}

#################################################
# FUNCTIONS TO CORRECT INTERSECTIONS
#################################################

# test if any elements are intersecting other elements
# or boundaries in the fric2d input file
sub test_intersect;
# test if any faults that have been added at this iteration
# intersect the elements of any other faults or boundaries
sub test_intersect_scenario; 
# correct any intersections of faults with other faults 
# or with boundaries
sub correct_intersections;
# function to readjust input files when faults need to link
sub correct_faults;
# corrects any intersections with boundaries
sub correct_bounds; 

sub is_inter;

# input: input filename
# result: if length of any elements = 0, then remove line(s), rewrite file
sub check_single
{
    my ($file) = @_;

    my @lines = ();
    my @f1s = ();
    my @b1s = ();
    my @f2s = ();
    my @b2s = ();
    my @bs = ();
    my @fs = ();

    my $is_b = 0;
    my $is_f = 0;

    my $len_tot =0;
    my $n = 0;

    my $b_num = 0;
    my $li = 0;
    # read in input file
    open FILE_HANDLER, $file or die $!;
    while (<FILE_HANDLER>)
    {
	my $line = $_;

	if ($line =~ /Boundary\s+Lines/)
	{
	    $is_b = 1;
	}
	elsif ($line =~ /^fault\s+/)
	{
	    $is_b = 0;
	}
	elsif ($line =~ /^\d+\s+/)
	{
	    my @data = split(/\s+/, $line);
	    
	    my $x1 = sprintf("%.5f", $data[1]);
	    my $y1 = sprintf("%.5f", $data[2]);
	    my $x2 = sprintf("%.5f", $data[3]);
	    my $y2 = sprintf("%.5f", $data[4]);
	    my $num = $data[0];

	    my $len = sqrt(($x1-$x2)**2 + ($y1-$y2)**2)/$num;
	    $len_tot = $len_tot+$len;
	    $n++;

	    # if same element appears in faults, remove it
	    if (grep(/$x1 $y1 $x2 $y2/, @fs))
	    {
		#print "same element: $x1 $y1 $x2 $y2 \n";
		#die;
		$line = '';
	    }

	    if ($is_b)
	    {
		$b_num++;

		push(@b1s, "$x1 $y1");
		push(@b2s, "$x2 $y2");
		push(@bs, "$x1 $y1 $x2 $y2")
	    }
	    else
	    {
		push(@f1s, "$x1 $y1");
		push(@f2s, "$x2 $y2");
		push(@fs, "$x1 $y1 $x2 $y2");
	    }


	}

	$lines[$li] = $line;
	$li++;

    }    
    close FILE_HANDLER;

    my $avg_len = $len_tot/$n;

    my $add = 1;
    
    my $obs_fill = "nblines = XXX \n";

    $is_b = 0;
    my $inlines = '';
    my @newlines = ();
    $li = 0;
    while ($li<$#lines)
    {
	$add = 1;
	my $line = $lines[$li];
        if ($line =~ /Boundary\s+Lines/)
	{
	    $is_b = 1;
	}
	elsif ($line =~ /^fault\s+/)
	{
	    $is_b = 0;
	}
	elsif ($line =~ /^nblines\s+=/)
	{
	    $line = $obs_fill; #"nolines = XXX \n";
	}
	elsif ($line =~ /^\d+\s+/)
	{
	    # get coorinates
	    my @data = split(/\s+/, $line);
	    
	    my $x1 = sprintf("%.5f", $data[1]);
	    my $y1 = sprintf("%.5f", $data[2]);
	    my $x2 = sprintf("%.5f", $data[3]);
	    my $y2 = sprintf("%.5f", $data[4]);

	    my $num = $data[0];
	    my $curr_len = sqrt(($x1-$x2)**2 + ($y1-$y2)**2)/$num;
	    
	    if ($curr_len <= $avg_len/2) 
	    {
		my $line_p = $lines[$li-1];
		my $line_n = $lines[$li+1];

		my $str = 'fault';

		# if node connects boundary node and fault node
		# then make new lines equal to prev beg, intersection coors, and next end
		# if this is boundary element, check fault nodes for intersection
		if ($is_b)
		{
		    $str = 'boundary';
		    $b_num = $b_num -1;
		}

		print "Removing elements <50% of the average element length: $avg_len \n";
		print "Removing small element: $x1 $y1 $x2 $y2 in $str of $file \n";

		# look to see if beg or end in fault or boundary

		# this point is a boundary point,
		# so check if it connects to any faults
		my $beg = "$x1 $y1";
		my $end = "$x2 $y2";

		# 0, if no intersection, 1 if inter at beg, 2 if at end
		my $inter = is_inter($is_b, $beg, $end, \@f1s, \@f2s, \@b1s, \@b2s);

		# if short coordinate is intersection coordinate
		# and previous and next line exist
		if ($inter && $line_p =~ /^\d+\s+/ && $line_n =~ /^\d+\s+/)
		{
		    # preserve beg of this line
		    # lengthen next element from beg of inter to end of next
		    if ($inter ==1)
		    {
			my @data_n = split(/\s+/, $line_n);

			my $x2n = $data_n[3];
			my $y2n = $data_n[4];

			$data[3] = $x2n;
			$data[4] = $y2n;

			$li++; # add to counter to skip the next line
			$line = join(" ", @data)."\n";

		    }
		    # preserve end of this element
		    else
		    {
			my @data_p = split(/\s+/, $line_p);
			
			my $x1p = $data_p[1];
			my $y1p = $data_p[2];
			
			$data[1] = $x1p;
			$data[2] = $y1p;
		    
			# remove the previous line from list
			$inlines =~ s/$line_p//g;

			$line = join(" ", @data)."\n";

		    }
		}
		# no intersection
		# if previous line is an element
		# end 2
		elsif ($line_p =~ /^\d+\s+/)
		{		    
		    my @data_p = split(/\s+/, $line_p);

		    my $x1p = $data_p[1];
		    my $y1p = $data_p[2];

		    $data[1] = $x1p;
		    $data[2] = $y1p;
		    
		    # remove the previous line from list
		    $inlines =~ s/$line_p//g;

		    $line = join(" ", @data)."\n";

		}
		# if next line is an element, and prev is not
		elsif ($line_n =~ /^\d+\s+/)
		{
		    my @data_n = split(/\s+/, $line_n);

		    my $x2n = $data_n[3];
		    my $y2n = $data_n[4];

		    $data[3] = $x2n;
		    $data[4] = $y2n;

		    $li++; # add to counter to skip the next line
		    $line = join(" ", @data)."\n";
		    $add = 0;
		    
		}

	    }
	

	    my @data_new = split(/\s+/, $line);
	    $x1 = sprintf("%.5f", $data_new[1]);
	    $y1 = sprintf("%.5f", $data_new[2]);
	    $x2 = sprintf("%.5f", $data_new[3]);
	    $y2 = sprintf("%.5f", $data_new[4]);

	    # check if line equals coordinate of another element
	    if (grep(/$x1 $y1 $x2 $y2/, @newlines))
	    {
		$line = '';
		#print "found repeat \n";
		#die;
	    }

	    push(@newlines, "$x1 $y1 $x2 $y2");

	}

	$inlines = $inlines.$line;

	$li++;

    }

    # if any of the coordinates equal (to 5 digits) the other end, then do not
    # include in input file

    if ($add)
    {
	$inlines = $inlines.$lines[$li];
    }


    my $obs_new = "nblines = $b_num \n";
    # change number of boundary lines
    $inlines =~ s/$obs_fill/$obs_new/g;

    #print $inlines;

    #die;

    open FILE_HANDLER_NEW, ">", $file or die $!;
    print FILE_HANDLER_NEW $inlines;
    close FILE_HANDLER_NEW; 

}

#check_single('detKICONT4.in');

sub is_inter
{
    my ($is_b, $beg, $end, $ref1, $ref2, $ref3, $ref4) = @_;

    my $inter = 0;

    my @f1as = @$ref1;
    my @f2as = @$ref2;
    
    my @b1as = @$ref3;
    my @b2as = @$ref4;

    my @f1s = ();
    my @f2s = ();
    
    my @b1s = ();
    my @b2s = ();

    my $add_next = 1;
    my $f1_prev = 0;
    my $f2_prev = 0;
    # fault element is short, remove fault element
    if (!$is_b)
    {
	@b1s = @b1as;
	@b2s = @b2as;

	# remove the coordinates in each that correspond to this element
	my $i=0;
	foreach my $f1 (@f1as)
	{
	    my $f2 = $f2as[$i];

	    # if these coordinates do not equal, 
	    if (!grep(/$beg/, $f1) || !grep(/$end/, $f2) && $add_next)
	    {
		push(@f1s, $f1);
		push(@f2s, $f2);

		$add_next = 1;
	    }
	    elsif (!$add_next)
	    {
		$add_next = 1;
	    }
	    # if these coordinates equal then do not add this element, remove prev, and do not add next
	    else
	    {
		# remove last element if it was connected to current
		# if previous end is connected to current beg
		if (grep(/$beg/, $f2_prev))
		{
		    pop(@f1s);
		    pop(@f2s);
		}
		
		if ($i<$#f1as)
		{
		    # do not add next if it is connected to current
		    my $f1_n = $f1as[$i+1];
		    if (grep(/$end/, $f1_n))
		    {
			$add_next = 0;
		    }
		}
	    }

	    $f2_prev = $f2;
	    $f1_prev = $f1;

	    $i++;
	}

	if (grep(/$beg/, @f1s) || grep(/$beg/, @f2s) || grep(/$beg/, @b1s) || grep(/$beg/, @b2s))
	{
	    $inter = 1;
	}
	elsif (grep (/$end/, @f1s) || grep (/$end/, @f2s)  || grep(/$end/, @b1s) || grep(/$end/, @b2s))
	{
	    $inter = 2;
	}

    }
    # boundary element is short, remove boundary element
    # check intersection only with faults
    else
    {
	@f1s = @f1as;
	@f2s = @f2as;

	my $i=0;
	foreach my $b1 (@b1as)
	{
	    my $b2 = $b2as[$i];

	    if (!grep(/$beg/, $b1) || !grep(/$end/, $b2))
	    {
		push(@b1s, $b1);
		push(@b2s, $b2);
	    }

	    $i++;
	}

	if (grep(/$beg/, @f1s) || grep(/$beg/, @f2s))
	{
	    $inter = 1;
	}
	elsif (grep (/$end/, @f1s) || grep (/$end/, @f2s))
	{
	    $inter = 2;
	}
	
    }

    return $inter;
    
}

sub is_triangle;

#my $is_tri = is_triangle('tri_ang2.in');
#print "there is a triangle: $is_tri \n";

# return 1 if any triangle is found
# if three elements 
sub is_triangle
{
    my ($filename) = @_;

    # if three elements are connected
    # two of the elements are on different faults
    my $istri = 0;

    # get the end points of all the boundaries and elements
    my ($bound_ref, $fault_ref) = get_end_points($filename);
    my %faults = %$fault_ref;

    foreach my $name (keys %faults)
    {
	my @coors = split(/\n/, $faults{$name}); 

	# check if any of these coordinates are connected to another node
	foreach (@coors)
	{
	    my $seg = $_;
	    my @pts = split(/\s+/, $seg);

	    my $pta1 = "$pts[0] $pts[1]";
	    my $pta2 = "$pts[2] $pts[3]";

	    foreach my $name2 (keys %faults)
	    {
		if ($name2 ne $name)
		{
		    my @coors1 = split(/\n/, $faults{$name2});

		    foreach (@coors1)
		    {
			my $seg1 = $_;
			my @pt1s = split(/\s+/, $seg1);

			my $ptb1 = "$pt1s[0] $pt1s[1]";
			my $ptb2 = "$pt1s[2] $pt1s[3]";

			if ($pta1 eq $ptb1 || $pta2 eq $ptb1 || $pta1 eq $ptb2 || $pta2 eq $ptb2)
			{
			    #print "Found connected node in $filename of faults $name and $name2, \n   elements: $pta1 $pta2, and $ptb1, $ptb2 \n";
			    print "found connected node \n";

			    my $pend = $pta1; # where the coordinates intersect
			    my $pcon1 = $pta2; # the other points of the triangle
			    my $pcon2 = $ptb2;
			    if ($pta1 eq $ptb1)
			    {
			    }
			    elsif ($pta2 eq $ptb1)
			    {
				$pend = $pta2;
				$pcon1 = $pta1; 
				$pcon2 = $ptb2;
			    }
			    elsif ($pta1 eq $ptb2)
			    {
				$pend = $pta1;
				$pcon2 = $pta2; 
				$pcon1 = $ptb1;
			    }
			    elsif ($pta2 eq $ptb2)
			    {
				$pend = $pta2;
				$pcon1 = $pta1; 
				$pcon2 = $ptb1;
			    }

			    # loop through all the fault end points again
			    foreach my $name3 (keys %faults)
			    {
				my @coors2 = split(/\n/, $faults{$name3});

				foreach (@coors2)
				{
				    my $seg2 = $_;
				    my @pt2s = split(/\s+/, $seg2);
				    
				    my $ptc1 = "$pt2s[0] $pt2s[1]";
				    my $ptc2 = "$pt2s[2] $pt2s[3]";

				    # if the end points of the two connected elements equal the endpoints of one element
				    if (($ptc1 eq $pcon1 && $ptc2 eq $pcon2) || ($ptc2 eq $pcon1 && $ptc1 eq $pcon2))
				    {
					print "Found triangle. Removing file.\n";
					print "$filename $name $pta1 $pta2; $name2 $ptb1 $ptb2; $name3 $ptc1 $ptc2 \n";
					return 1;
				    }

				}

			    }

			   

			}
		    }
		}
	    }
	}
    }

    return $istri;

}

sub is_acute;

#my $is_acute = is_acute('tri_cross.in');
#my $is_acute = is_acute('tri_shallow.in');
#my $is_acute = is_acute('tri_ang.in');
#print "is acute: $is_acute \n";

sub is_acute
{
    my ($filename) = @_;

    # if two connected elements have an acute angle between them
    my $isacute = 0;

    # get the end points of all the boundaries and elements
    my ($bound_ref, $fault_ref) = get_end_points($filename);
    my %faults = %$fault_ref;

    foreach my $name (keys %faults)
    {
	my @coors = split(/\n/, $faults{$name}); 

	# check if any of these coordinates are connected to another node
	foreach (@coors)
	{
	    my $seg = $_;
	    my @pts = split(/\s+/, $seg);

	    my $pta1 = "$pts[0] $pts[1]";
	    my $pta2 = "$pts[2] $pts[3]";

	    foreach my $name2 (keys %faults)
	    {
		if ($name2 ne $name)
		{
		    my @coors1 = split(/\n/, $faults{$name2});

		    foreach (@coors1)
		    {
			my $seg1 = $_;
			my @pt1s = split(/\s+/, $seg1);

			my $ptb1 = "$pt1s[0] $pt1s[1]";
			my $ptb2 = "$pt1s[2] $pt1s[3]";

		        
			if ($pta1 eq $ptb1 || $pta2 eq $ptb1 || $pta1 eq $ptb2 || $pta2 eq $ptb2)
			{
			    #print "Found connected node in $filename of faults $name and $name2, \n   elements: $pta1 $pta2, and $ptb1, $ptb2 \n";

			    
			    my $pend = $pta1; # where the coordinates intersect
			    my $pcon1 = $pta2; # the other points of the triangle
			    my $pcon2 = $ptb2;
			    if ($pta1 eq $ptb1)
			    {
			    }
			    elsif ($pta2 eq $ptb1)
			    {
				$pend = $pta2;
				$pcon1 = $pta1; 
				$pcon2 = $ptb2;
			    }
			    elsif ($pta1 eq $ptb2)
			    {
				$pend = $pta1;
				$pcon2 = $pta2; 
				$pcon1 = $ptb1;
			    }
			    elsif ($pta2 eq $ptb2)
			    {
				$pend = $pta2;
				$pcon1 = $pta1; 
				$pcon2 = $ptb1;
			    }

			    # get the angle between the two connected points
			    my ($p1x, $p1y) = split(/\s+/, $pcon1);
			    my ($p2x, $p2y) = split(/\s+/, $pcon2);
			    my ($pex, $pey) = split(/\s+/, $pend);

			    # use the law of cosines to get the inner angle
			    my $a = sqrt(($p1x-$pex)**2 + ($p1y-$pey)**2);
			    my $b = sqrt(($p2x-$pex)**2 + ($p2y-$pey)**2);
			    my $c = sqrt(($p1x-$p2x)**2 + ($p1y-$p2y)**2);

			    my $deg = (180/3.14)*(acos(($a**2 + $b**2 - $c**2)/(2*$a*$b)));

			    print "$filename $name $pta1 $pta2; $name2 $ptb1 $ptb2; Angle: $deg \n";

			    # the angle between the lines is less than a threshold
			    if ($deg<20)
			    {
				print "Found angle < 20 deg. Removing file.\n";
				return 1;
			    }
			   

			}
		    }
		}
	    }
	}
    }

    return $isacute;

}

#my $is = is_overlap('ap3t180.in');

# check if 2 elements are overlapping
sub is_overlap
{
    my ($filename) = @_;

    # is any element overlapping another element exactly
    my $isover = 0;

    # get the end points of all the boundaries and elements
    my ($bound_ref, $fault_ref) = get_end_points($filename);
    my %faults = %$fault_ref;

    foreach my $name (keys %faults)
    {
	my @coors = split(/\n/, $faults{$name}); 
	#print "$name\n";
       
	# check if any of these coordinates match any other coordinates
	foreach (@coors)
	{
	    my $seg = $_;
	    my @pts = split(/\s+/, $seg);
	    my $ptc = "$pts[0] $pts[1] $pts[2] $pts[3]";
	    
	    # check if any of the elements of this fault match elements of the same fault
	    my @coors1 = @coors;
	    my $num = 0;
	    foreach (@coors1)
	    {
		my $seg1 = $_;
		my @pts1 = split(/\s+/, $seg1);
		my $ptc1 = "$pts1[0] $pts1[1] $pts1[2] $pts1[3]";
		if ($ptc1 eq $ptc)
		{
		    #print "Found one same element \n";
		    $num=$num+1;
		}
		# if we see the element more than twice, then it is repeated
		if ($num>1)
		{
		    print "Found overlapping element of fault: $name \n  coordinates: $ptc1. Removing file: $filename \n";
		    return 1;
		}
	    }
	    
	    foreach my $name2 (keys %faults)
	    {
		if ($name2 ne $name)
		{
		    my @coors2 = split(/\n/, $faults{$name2}); 
		    
		    # check if any of these coordinates match any other coordinates
		    foreach (@coors2)
		    {
			my $seg2 = $_;
			my @pts2 = split(/\s+/, $seg2);
			my $ptc2 = "$pts2[0] $pts2[1] $pts2[2] $pts2[3]";
		    
			if ($ptc eq $ptc2)
			{
			    print "Found overlapping element of faults: $name and $name2, coordinates: $ptc. Removing file: $filename \n";
			    return 1;
			
			}
		    }
		}
	    }
	}
    }

    return $isover;

}

#my $testing_filename = 'eblt.in';
#my $pair_ref = {"lil3 1" => 180};
#my $res = correct_intersections($testing_filename, $pair_ref, 0, 6);
#print "$res\n";

# function only corrects one intersection at a tip
# called: $fault_intersect = correct_intersections($testing_filename, $pair_ref, 0, $structure_num);
# input: name of FRIC2D input file that should be modified, 
#        reference to single scenario of hash table 
#            (formatted: "fault1 end1" => angle, "fault2 end2" => angle
# output: = -1 if reach counter or intersects self, =0 if no intersection, >0 if corrected something
sub correct_intersections
{
    my ($testing_filename, $scen_ref, $counter, $limit) = @_;

    # if we have tried to correct more than the number
    # of possible faults and boundaries to intersect with
    if ($counter > $limit)
    {
	return -1;
    }

    # if an element of one fault exactly equals the other fault
    # then say that it is not possible to correct it
    my $is_same = is_overlap($testing_filename);
    if ($is_same)
    {
	return -1;
    }

    # if the angle between two connected elements is < 10
    # then say it is not possible to correct it
    my $is_acute = is_acute($testing_filename);
    if ($is_acute)
    {
	return -1;
    }


    # output: if no intersection: hash{$name} = ()
    #         if intersection: hash containing info 
    #            to be used to link intersecting elements
    my %intersect_info = test_intersect_scenario($scen_ref, $testing_filename); 

    my @name_ends = @{$intersect_info{"names"}}; 
    my @names;
    my $i = 0;

    # get the list of names of faults from the list of
    # fault end pairs
    foreach(@name_ends)
    {
	my @fault_end = split(/\s/,$_);
	
	$names[$i] = $fault_end[0]; 
	$i++;
    }

    # if no intersection was found
    if ($names[0] eq "<none>")
    {
	return $counter;
    }
    # if the fault intersects itself
    elsif ($names[0] eq $names[1])
    {
	my $n1 = $names[0];
	my $n2 = $names[1];
	print "\nWARNING: Fracture $n1 intersects itself in $testing_filename \n";
	return -1; 
    }
    # if the fault intersects a boundary
    elsif ($names[0] eq "<bound>" || $names[1] eq "<bound>")
    {
	print "\nWARNING: Fault and boundary intersect in $testing_filename \n";
	correct_bound($testing_filename, \%intersect_info);
	$counter++;	
    }
    # if one fault intersects another fault : correct the intersections
    else
    {
	print "\nWARNING: Fault $names[0] intersects $names[1] in $testing_filename \n";

	correct_faults($testing_filename, \%intersect_info);

	# after correcting the faults, check that the corrected elements do not make a triangle
	my $is_tri = is_triangle($testing_filename);
	if ($is_tri)
	{
	    return -1;
	}

	$counter++;
    }

    # after correcting boundary or correcting an intersection with one fault
    # signal that we corrected the intersection, and let larger loop check for more intersections
    return correct_intersections($testing_filename, $scen_ref, $counter, $limit);
}


sub adjust_fault;

# called: correct_bound($testing_filename, \%intersect_info);
# input: testing filename, information related to how the element of a fault
#        intersects a boundary
# result: input file is changed so that the element of the fault 
#         connects to a node of the boundary
sub correct_bound
{
    my ($testing_filename, $inter_ref) = @_;

    my %intersect = %$inter_ref;
    # get the name of the fault, and <bound>
    my @name_ends = @{$intersect{"names"}};

    # find the x,y coordinate of the intersection
    my @coors = @{$intersect{"coors"}};

    # change the input file using the name of the fault, 
    # the coordinates of the fault, and the coors of intersection
    # change the flag in the input file
    adjust_fault($testing_filename, $name_ends[0], $intersect{$name_ends[0]} , \@coors, 1);

}

sub get_fault_roles;

# input: testing filename, info describing how one fault intersects another
# result: the growing end of the element is shortened to meet the elements of the fault
#         the fault that is intersected by the growing end is adjusted like a boundary
#         so that the intersection meets at a node
sub correct_faults
{
    my ($testing_filename, $inter_ref) = @_;

    my %intersect = %$inter_ref;

    # get the names of the faults that are intersection
    my @name_ends = @{$intersect{"names"}};

    # find the x,y coordinate of the intersection
    my @coors = @{$intersect{"coors"}};

    # get the name and end of the fault that was growing, and the other throughgoing fault
    my ($grow_fault, $through_fault) = get_fault_roles($inter_ref);

    # change the input file using the name of the fault, 
    # the coordinates of the fault, and the coors of intersection
    # change the flag in the input file
    adjust_fault($testing_filename, $grow_fault, $intersect{$grow_fault}, \@coors, 0);

}

# called:  my $structure_num = get_intersect_structs($testing_filename);
# input: input filename
# output: number of faults*2 #+ boundary segments
sub get_intersect_structs
{
    my ($file) = @_;

    open FILE_HANDLER, $file or die $!;
    my $num = 0;
    my $bound = 0;
    while (<FILE_HANDLER>)
    {
	my $line = $_;
	
	if ($line =~ /^fault\s+/)
	{
	    $num = $num+2;
	}
	#elsif ($line =~ /^\*Boundary\s+Lines\s+/)
	#{
	#    $bound = 1;
	#}
	#elsif ($bound && $line =~ /^\d+\s+/)
	#{
	#    $num = $num+1;
	#}
	#elsif ($bound && $line =~ /^\n/ || $line =~ /^\s+/)
	#{
	#    $bound = 0;
	#}
	

    }    
    close FILE_HANDLER;

    if ($num == 0)
    {
	print "WARNING WHEN CORRECTING INTERSECTIONS: Could not find number of faults and boundary segments in input file.";
	return 10;
    }
    
    return $num;

}

sub turn_off;

#check_flags('AG_aptest3_tune_2_bend1b1_1_215.in');
sub check_flags
{
    my ($file) = @_;

    # get the name and end of all the growing faults
    my @fault_grow = get_fault_names($file);

    foreach (@fault_grow)
    {
	my @grow = split(/\s/, $_);
	my $fault_name = $grow[0];
	my $fault_end = $grow[1];

	#print "$fault_name $fault_end\n";

	# get the end points of all the boundaries and elements
	my ($bound_ref, $fault_ref) = get_end_points($file);

	my @bounds = @$bound_ref; 
	my %faults = %$fault_ref;

	# get the coordinates of the growing tip of this fault
	my @coors = split(/\n/, $faults{$fault_name}); ## error here
	my $gs = '';

	if ($fault_end eq '1')
	{
	    my $seg = $coors[0];
	    my @pts = split(/\s+/, $seg);
	    $gs = "$pts[0] $pts[1]";
	}
	else
	{
	    my $seg = $coors[-1];
	    my @pts = split(/\s+/, $seg);
	    $gs = "$pts[2] $pts[3]";
	}


	# search for the end points 
	my $numpt = 0;
	foreach my $name (keys %faults)
	{
	    # if this is not the fault that is growing at this iteration
	    if ($name ne $fault_name)
	    {
		my @coors = split(/\n/, $faults{$name}); 

		# check if any of these coordinates match the growing one
		foreach (@coors)
		{
		    my $seg = $_;
		    my @pts = split(/\s+/, $seg);
		    my $pt1 = "$pts[0] $pts[1]";
		    my $pt2 = "$pts[2] $pts[3]";

		    #print "$pt1 \n $pt2 \n";
		    if ($pt1 eq $gs || $pt2 eq $gs)
		    {
			$numpt=$numpt+1;
			print "Found matching nodes of faults: $fault_name and $name \n";
		    }
		}
	    }
	}

	# if the number of matching nodes are >1, then set the flag to not growing
	if ($numpt>1)
	{
	    # get the contents of the input file
	    turn_off($file, $fault_name, $fault_end, $file);

	    print "Found $numpt intersections at growing tip. Turning off growth of $fault_name from end $fault_end.\n";
	}
    }
}

#my $file = 'bone6p4.in';
#my $fault_name = 'first30b1b1b1';
#my $fault_end = 2; 
#turn_off($file, $fault_name, $fault_end, 'test.eff');

# set the flag of this end of this fault to no in the input file
# turn_off($file, $fault_name, $fault_end, $new_name);
sub turn_off
{
    my ($file, $gname, $gend, $newfile) = @_;

    # remember the name of the faults and the direction of growing
    my @faults; 
    
    # open file, or send error message 
    open FILE_HANDLER, "$file" or die $!;

    # each new line is stored in variable $_
    # regular expressions act on $_ as a default
    my $newls = '';
    while (<FILE_HANDLER>)
    {

    	my $line = $_; 
	
        # if the line starts with the word "fault", 
	# remember how the fault is growing
	if ($line =~ /^fault\s/)
	{     
	    
	    my ($f, $name, $grow_tail, $from_end1, $from_end2) = 
		split(/\s+/, $line);

	    if ($name eq $gname)
	    {
		if ($gend==1)
		{
		    $from_end1 = 'no';
		}
		else
		{
		    $from_end2 = 'no';
		}
		
		$line = "$f $name $grow_tail $from_end1 $from_end2\n";
	    }
	}

	$newls = $newls."$line";
    }

    # close the file
    close FILE_HANDLER;

    # write to the new file
    # write the new efficient input file to the same file
    open FILE_HANDLER_NEW, ">", $newfile or die $!;
    print FILE_HANDLER_NEW $newls;
    close FILE_HANDLER_NEW; 
}


#check_final_intersections('gflagt.in');

# called: check_final_intersections($efficient_filename);
# input: name of most efficient file identified thus far
# result: if tips of faults intersect any other tips of faults
#         those tips are set to not growing
#         must check this after initial intersection algorithm
#          because if the tips of two faults exactly intersect, then intersection algorithm will not detect
sub check_final_intersections
{
    my ($file) = @_;

    # get all the lines, to index forward one if need be
    # open file, or send error message 
    open FILE_HANDLER, $file or die $!;
    my @line_list;
    while (<FILE_HANDLER>)
    {
	my $line = $_;
	push(@line_list, $line);
    }    
    close FILE_HANDLER;

    # make hash table with first/last fault line of each "fault end"
    # hash table with fault name end => fault line
    my %fault_line;  
    # hash table: fault => line number in file with fault header
    my %fault_index;

    my $found = 0;
    my $read_this_fault = 0;

    my $i = 0;
    my @file_lines = @line_list;
    my $fault_name = "";
    foreach (@line_list)
    {
	my $line = $_;
	
	if ($line =~ /^fault\s+/)
	{
	    $found = 1;
	    my @data = split(/\s+/, $line);
	    $fault_name = $data[1];
	    
	    $fault_index{$fault_name} = $i;
	    $read_this_fault = 0;
	}
	elsif ($found && $line =~ /^\d+\s+/ )
	{
	    if (!$read_this_fault)
	    {
		$fault_line{$fault_name.' 1'} = $line;
		$read_this_fault = 1;
	    }
	    if ($read_this_fault)
	    {
		$fault_line{$fault_name.' 2'} = $line;
	    }
	}

	$i++;
    }


    # for each key in hash table
    # get end and beginning coordinates
    foreach my $name_end (keys %fault_line)
    {
	my $line1 = $fault_line{$name_end};

	my @curr_line = split(/\s+/, $line1 );
	my $e1 = $curr_line[0];
	
	# only if this fault end is one element long
	# (i.e., GROW added it to the fault, rather than the user)
	# though this assumes user will not make a fault
	# where the not growing tip has a segment 1 element long
	if (abs($e1 - 1) < 1e-10)
	{
	    my $xb = $curr_line[1];
	    my $yb = $curr_line[2];
	    my $xe = $curr_line[3];
	    my $ye = $curr_line[4];

	    my %fault_line_test = %fault_line;
	    my $fault_name = substr($name_end, 0, -2);

	    # remove the fault segments included in this fault
	    # so we do not test against the same faules
	    delete $fault_line_test{$fault_name.' 1'};
	    delete $fault_line_test{$fault_name.' 2'};

	    # for both sets of coordinates, check if they intersect with coordinates of all other keys 
	    # (that are not the same fault)
	    foreach my $name_end2 (keys %fault_line_test)
	    {
		my $line2 = $fault_line{$name_end2};
		my $fault_name2 = substr($name_end2, 0, -2);
		my @curr_line2 = split(/\s+/, $line2 );
		my $xb2 = $curr_line2[1];
		my $yb2 = $curr_line2[2];
		my $xe2 = $curr_line2[3];
		my $ye2 = $curr_line2[4];

		my $fault1_header_i = $fault_index{$fault_name};
		my $fault2_header_i = $fault_index{$fault_name2};
		my $fault1_header = $file_lines[$fault1_header_i];
		my $fault2_header = $file_lines[$fault2_header_i];
		my @data1 = split(/\s+/, $fault1_header);
		my @data2 = split(/\s+/, $fault2_header);

		# if testing end 1, only consider beg
		my $end1 = substr($name_end, -1, length($name_end));
		my $end2 = substr($name_end2, -1, length($name_end2));

		my $x1 = $xe;
		my $y1 = $ye;
		my $flgi1 = 4; 
		if ($end1 =~ '1')
		{
		    $x1 = $xb;
		    $y1 = $yb;
		    $flgi1 = 3; 
		}
		my $x2 = $xe2;
		my $y2 = $ye2;
		my $flgi2 = 4; 
		if ($end2 =~ '1')
		{
		    $x2 = $xb2;
		    $y2 = $yb2;
		    $flgi2 = 3; 
		}

		my $dist = sqrt(($x1-$x2)**2 + ($y1-$y2)**2);
		my $elem = sqrt(($xb2-$xe2)**2 + ($yb2-$ye2)**2);
		# if testing end 2, only consider end

		# if it's close to another fault, 
		# set the flag of associated end of each fault as "no"
		# intersect beg of 1, with beg of 2
		if ($dist < 0.5*$elem)
		{
		    $data1[$flgi1] = "no";
		    $data2[$flgi2] = "no";
		    
		}

		$file_lines[$fault1_header_i] = join('  ', @data1)."\n";
		$file_lines[$fault2_header_i] = join('  ', @data2)."\n";
	    }	    
	}
    }

    # write new file lines to file
    my $file_contents = join('', @file_lines);    

    # write the new efficient input file to the same file
    open FILE_HANDLER_NEW, ">", $file or die $!;
    print FILE_HANDLER_NEW $file_contents;
    close FILE_HANDLER_NEW; 

}

# called: my ($grow_fault, $through_fault) = get_fault_roles($inter_ref);
# input: reference to intersect hash containing fault name" "end pairs
#        and fault pairs "M"
# output: name and fault pair of the "growing fault" and the through going fault
sub get_fault_roles
{
    my ($ref) = @_;
    my %intersect = %$ref;

    my $growing = "";
    my $through = "";
    foreach my $name_end (keys %intersect)
    {
	# if the name contains a space and a digit
	# this fault was growing
	if ($name_end =~ /\s\d/)
	{
	    $growing = $name_end;
	}
	# if the key contains a space and M, this is 
	# through-going fault
	elsif ($name_end =~ /\sM/)
	{
	    $through = $name_end;
	}
    }

    return ($growing, $through);
}

# called: my @new_lines = remove_same(\@new_line_1, \@new_line_2, \@new_line_3, \@new_line_4)
# input: list of references to newlines xh, yh, xt, yt of faults
# result if the x,y coordinate of the head == xy coordinate of tail, then stop execution
# otherwise continue with function
sub remove_same
{
    my @refs = @_;
    my @different = ();

    foreach (@refs)
    {
	my $ref = $_;
	my @fault = @$ref;

	# if the x coordinate and y coordinate do not equal each other
	if (abs($fault[1] - $fault[3]) > 1e-5 || abs($fault[2] - $fault[4]) > 1e-5)
	{
	    push(@different, $ref);
	}
    }
    return @different; 
}

# determine if coordinates fall within the segment
sub on_element;

# adjusts tip of growing fault if intersects
# called:  adjust_fault($testing_filename, $names[0], $intersect{$names[0]} , \@coors);
# input: name of file to modify, name of fault to change, old coordinates
#        that intersect, reference to list of coordinates of intersection
# result: coordinates of element of fault that do not connect to 
#         the rest of the fault now equal to intersection coordinates
#         flag of fault growing set to "no"
sub adjust_fault
{
    my ($testing_filename, $fault_name_end, $old_coors, $inter_ref, $isb) = @_;

    my ($fault_name, $end) = split(/\s+/, $fault_name_end); 

    my @inter_coors = @$inter_ref;
    my @old_coors = split(/\s+/, $old_coors);

     my $file_contents = "";
    # open file, or send error message 
    open FILE_HANDLER, "$testing_filename" or die $!;

    my $found = 0;
    while (<FILE_HANDLER>)
    {
	my $line = $_;
       
	if ($line =~ /^fault\s+$fault_name\s+/)
	{
	    $found++; 

	    my @line_info = split(/\s+/, $line);
	    # change the growing flags so that
	    # these ends are no longer growing
	    if ($end =~/\d/ && $isb)
	    {
		# FLAGS TO CONTROL WHETHER INTERSECTING FRACTURES ARE SHUT OFF
		# UNCOMMENT IF YOU WANT THEM TO BE SHUT OFF
		# allow this if the fault intersects a boundary
		if ($end == 1)
		{
		    $line_info[3] = "no";
		}
		elsif ($end == 2)
		{
		    $line_info[4] = "no";
		}
	    }
	    
	    $line = join("\t", @line_info)."\n"; 	    

	}
	elsif (($found > 0) && $line eq "\n")
	{
	    $found = 0;
	}
	elsif (($found > 0) && $line =~ /^\d+/ )
	{
	    # test to see if the current line corresponds
	    # to the correct boundary
	    my @fault = split(/\s+/, $line); 

	    if ($old_coors[0] == $fault[1] &&
		$old_coors[1] == $fault[2] &&
		$old_coors[2] == $fault[3] &&
		$old_coors[3] == $fault[4])
	    {		
		my @new_line = @fault;

		# if the element that intersects this boundary 
		# is the first element listed: i.e. if the fault
		# is growing from end1 
		if ($end == 1)
		{
		    # the new coordinates are at the beginning of the
		    # fault
		    @new_line[1..2] = @inter_coors;
		}
		# if the fault is growing from end2
		else
		{
		    # the new coordinates are at the end
		    # of the fault 
		    @new_line[3..4] = @inter_coors;
		}


		# if the intersection coordinates falls on the fault element 
		# that is propagating, then shorten the given element
		### this is unlikely to happen because intersections are detected
		# one 1/2 length away
		my @old_fault_coors = @fault[1..4];
	
		if ($end == 1)
		{
		    #@new_line[3..4] = @fault[1..2];
		    @new_line[3..4] = @fault[3..4];
		    $line = join("\t", @new_line)."\n";
		}
		else
		{
		    #@new_line[1..2] = @fault[3..4];
		    @new_line[1..2] = @fault[1..2];
		    $line = join("\t", @new_line)."\n";
		}	
		
		
		$found = 0; 
		
	    }
	    # if this is not the element of the fault we are adjusting
	    # then increment the counter so we add to the correct end
	    else
	    {
		$found++;
	    }

	}

	$file_contents = $file_contents.$line; 

    }

    close FILE_HANDLER;
    
    # write the new working input to this file
    open FILE_HANDLER_NEW, ">", $testing_filename or die $!;
    print FILE_HANDLER_NEW $file_contents;
    close FILE_HANDLER_NEW;    
}


# input: ref to list of coordinates, 
#        and list of beg and end points of segment
# output: true if coordinates fall on line
#         false otherwise
sub on_element
{
    my ($ref1, $ref2) = @_;

    my ($x, $y) = @$ref1;
    # if no coordinates given
    # then the coordinates do not fall on segment 2
    if (!@$ref1)
    {
	return 0;
    }

    my ($xb, $yb, $xe, $ye) = @$ref2;

    # if first set of coordinates fall on segment 2 end or beg
    # then consider to fall on element
    if (abs($xb - $x) < 1e-10 && abs($yb - $y) < 1e-10 || 
	abs($xe - $x) < 1e-10 && abs($ye - $y) < 1e-10)
    {
	return 1;
    }


    my ($m, $b) = get_line(@$ref2);;

    if ($m eq 'x-in')
    {
	if ((abs($x - $b) < 1e-10) && $y >= min_list($yb, $ye) && $y <= max_list($yb, $ye))
	{
	    return 1;
	}
	else
	{
	    return 0;
	}
    }
    else
    {
	if ((abs($y - ($m*$x + $b)) < 1e-10) && $x >= min_list($xe, $xb) && $x <= max_list($xe, $xb))
	{
	    return 1;
	}
	else
	{
	    return 0;
	}
    }


}

##################################################################
# FUNCTIONS TO MAKE INPUT FILES
##################################################################

# insert element into array after a certain index
sub insert;  
# get the beg and end of the element oriented horiztonally from the input values
# given by the user
sub get_init_geometry;

# called:make_input_file_scenario($prev_filename, $testing_filename, 
#				 \%this_scenario, $is_sand);
# input: previous file name to build into, name of file to create, 
#        hash table describing the geometry, bool, T/F if creating file of growing from a point
# result: input file is written to testing filename
sub make_input_file_scenario
{
    my ($prev_file, $testing_file, $scen_ref, $is_sand) = @_;

    my %scenario = %$scen_ref;

    # for each fault in the scenario
    # make a new input file with a crack added to the fault at the 
    # specified angle
    foreach my $fault_name_end (keys %scenario)
    {
	my $angle = $scenario{$fault_name_end}; 
	
	my ($fault_name, $end) = split(/\s+/, $fault_name_end); 
	my @old_geo; 

	# variable only used if creating a flaw
	my @fault; 

	# get the direction that the fault is growing by reading the input file
	if ($is_sand)
	{
	    # find the info of the flaw that will start growing 
	    # name, x, y, length, and if growing from both tips
	    my ($flaw_x, $flaw_y, $length, $grow_both) = get_flaw_info($prev_file, $fault_name); ####   ## change to look for values of the fault named    

	    # find the coordinates of an element oriented horiztonally
	    # from the input coordinates to the negative x-direction
	    # coordinates = x - length, y, x, y
	    # and the length
	    @old_geo = get_init_geometry($flaw_x, $flaw_y, $length); 

	    # variable has no meaning in algorithm that makes input file
	    # for points being tested
	    $end = 0;
	}
	else
	{
	    @old_geo  =  get_geometry($prev_file, $fault_name, $end);
	    
	}

	my @old_coors = @old_geo[0..3]; 
	my @new_coors = get_coors_pup($angle, @old_coors);	 

	# make sure the new coordinates exist
	if (scalar(@new_coors) == 0)
	{
	    die "Could not find new coordinates of pupative element for \n\tFault and end: $fault_name_end\n\tOld Coordinates:@old_coors \n";
	}

	# make the fric2d input file with the associated values
	make_input_file($prev_file, $testing_file, 
			@new_coors, $fault_name, 
			$end, $is_sand);

	# set the name of the previous file used to make the next testing file
	# to the testing file just created
	$prev_file = $testing_file; 
    }

}

# input: previous filename, name of propagating fault
# result: if fault is a propagated flaw, then properties of
#         fault are changed to *Flaw-Fault properties
#         otherwise no changes made to file
sub reset_flaw_one
{
   my ($file, $fault) = @_; 
    
   my $found_fault = 0;
   my $fault_props = "";
   
   # open file, or send error message 
   open FILE_HANDLE, "$file" or die $!;

   my $new_file = "";
   while (<FILE_HANDLE>)
    {
	my $this_Line = $_;
	my @line = split(/\s+/, $this_Line); 

	  # find line with fault name
   	if ($this_Line =~ /^fault\s+$fault\s+/ )  
	{      
	    $found_fault = 1;
	}
	# find line with *Flaw-Fault properties, keep updating with new values for each 
	elsif ($this_Line =~ /^\*Flaw-Fault\s+/ ) 
	{
	   my @props = @line[1..$#line]; 
	   $fault_props = join("\t", @props);
	}
	# find line with fault properties
	# found the fault properties, this specific fault, and this line starts with 1
	elsif ($fault_props ne "" && $found_fault && $this_Line =~ /^1\s+/)
	{
	    my $fault_line_start = join("\t", @line[0..4]);
	    my $new_line = $fault_line_start."\t".$fault_props."\n";
	    $this_Line = $new_line;
	    
	    # make sure we don't get incorrect values overprinting
	    $found_fault = 0;
	    $fault_props = "";
	}
	# if see a newline, then signal we have not seen the
	# fault properties or fault, otherwise can detect *Flaw-Fault 
	# not associated with named fault
	elsif (scalar(@line) < 2)
	{
	    $found_fault = 0; 
	    $fault_props = "";
	}
	
	# add all the old stuff to the new input file
	$new_file = $new_file.$this_Line;
	
    }   
   
   close FILE_HANDLE;

   # rewrite the efficient file found
   open FILE_HANDLE_NEW, ">", $file or die $!;
   # remove \M from end of lines
   $new_file =~ s/\r//g; 
   print FILE_HANDLE_NEW $new_file."\n";
   close FILE_HANDLE_NEW; 
}

# change values in previous filename, because this file will be used to create new files, also overwrite efficient file?
# input: name of previous filename, list of fault names propagating
# result: fault properties in fault line replaced with *Flaw-Fault properties
sub reset_flaw_all
{
    my ($file, $ref) = @_;
    my @faults = @$ref;

    for (@faults)
    {
	my $info = $_;
	my $name = substr($info, 0, -2);
	reset_flaw_one($file, $name);	
    }
}


sub format_title;
sub format_char;
sub set_fault_properties;
sub make_aniso_crack;

# called:make_input_file($prev_file, $testing_file, 
#			@new_coors, $fault_name, 
#			$end, $is_sand);
# input: name of the old input file, name of the current input file,
#        coordinates of the head of the new pup crack, 
#        what end we are prop from
# result:  new input file is generated
sub make_input_file
{
    # get the arguments
    my $prev_filename = $_[0];
    my $testing_filename = $_[1];
    my @unrounded_new_X_Y = @_[2,3];
    my $fault_name = $_[4];
    my $curr_end = $_[5];    
    my $is_sand = $_[6];

    # round coordinates to 5 decimal places
    my @new_X_Y;
    $new_X_Y[0] =  sprintf("%.5f", $unrounded_new_X_Y[0]) ;
    $new_X_Y[1] =  sprintf("%.5f", $unrounded_new_X_Y[1]) ;

    # init variable to store contents of old file
    my @file_contents; 
    # init variable to signify when a new fault geo was found
    my $found_fault = 0;
    # declare variable that will contain the new line of input values
    my $formatted_Input; 

    # open file, or send error message 
    open FILE_HANDLER_OLD, "$prev_filename" or die $!;

    # search through the input file line by line
    # and find all the data related to the faults
    my $line_num = 0; 
    # remember the index in the array containing the
    # file contents that specifies the line number
    # before which to add the new data line
    my $index = 0; 
    # remember the data line
    my $data_line = "";

    # remember the main fault line
    my $fault_line = "";

    # parameters to read in new crack characteristics
    # different characteristics added to existing fault
    my $found_crack = 0;
    # flaw specified by point in input file
    my $flaw_title = ""; 
    my $flaw_char = ""; 
    my $flaw_fault_props = "";
    my @characteristics;
    # keep track of last line read in
    my $last_line = "";

    # list of strings of fault lines read in thus far
    my @current_fault_lines = ();
    my $found_fault_props = 0;

    # how complete fault is growing
    my $end_grow = 0;

    while (<FILE_HANDLER_OLD>)
    {
	my $this_Line = $_;
	my @line = split(/\s+/, $this_Line); 

	# if the line starts with the word "fault"
	# then remember that input cooresponding to a fault has been found
	if (!$is_sand && $this_Line =~ /^fault\s+$fault_name\s+/ )  
	{      
	    # signify that the fault we are growing was found
	    $found_fault = 1;
	    $found_fault_props = 1;
	    $end_grow = 1;
	    if ($line[3] =~ /yes/ && $line[4] =~ /yes/)
	    {
		$end_grow = 3;
	    }
	    elsif ($line[4] =~ /yes/)
	    {
		$end_grow = 2;
	    }
	}	
	# if line starts with fault, but not this fault
	# then signal we have not found the fault 
	elsif (!$is_sand && $this_Line =~ /^fault\s+/ )
	{      
	    $found_fault = 0;
	    $found_fault_props = 0;
	}
	# if we find the line "*Crack "
	# remember the  new parameters
	elsif (!$is_sand && $this_Line =~ /^\*Crack\s+/ && $found_fault)
	{
	    $found_crack = 1;	    
	    @characteristics  = split(/\s+/, $this_Line);
	}
	# if propagating from end 1, found fault header, see digits
	# record this info for the pupative element
	elsif (!$is_sand && $curr_end == 1 && $found_fault && 
	       $this_Line =~ /^\d+\s.+\s.+\s.+\s.+/ )
	{ 
	    $data_line = $this_Line; 
	    $index = $line_num-1;  
	    # signal to stop looking for more lines of input
	    # otherwise first index line found will not be maintained
	    $found_fault = 0;
	}
	# if prop from end 1, and not both tips
	# this is a new line, get the previous line as the main fault properties 
        ### this does not work when propagating from both tips??
	elsif (!$is_sand && $curr_end == 1 &&  scalar(@line) < 2 && ($fault_line eq "") && $data_line ne "") 
	{
	    # uses the properties of end 2 as the main fault properties
	    $fault_line = $file_contents[$line_num-1]; 
	    $found_fault_props = 0;
	    $found_fault = 0;
	}
	# if found fault, propagating from end 2, 
	# and line contains one element (i.e., is a newline)
	elsif (!$is_sand && $curr_end != 1 && $found_fault &&  scalar(@line) < 2)
	{
	    $data_line = $file_contents[$line_num-1]; 
	    $index = $line_num-1; 

	    # signal that we have found an input line and formatted
	    # the new fault data
	    $found_fault = 0; 
	    $found_fault_props = 0;
	}
	# use the index number after the *Flaw-Intact line
	# if see the flaw header, and we have a reference to sand charateristics
	# only reformat the lines for the flaw name given
	elsif ($is_sand && $this_Line =~ /^\*Flaw-Intact\s+$fault_name\s+/)
	{
	    $flaw_title = format_title ($this_Line); 
	    $flaw_char = format_char ($this_Line, \@new_X_Y); 
	    
	    # set these properties as the *Crack properties
	    my @props = @line[6..$#line]; 
	    $flaw_fault_props = "*Crack\t".join("\t", @props);
	}

	# if see any fault properties, add to running list
	# must operate independently from if statements above
	if ($found_fault_props && $this_Line =~ /^\d+\s+/ )
	{
	    push(@current_fault_lines, $this_Line);
	}

	# add this line to new file contents regarless of its contents
	# (bc we want to preserve the entire contents of the file)
	$file_contents[$line_num] = $this_Line;
	$line_num = $line_num + 1;
	$last_line = $this_Line; 

	# if we created the flaw title, then add to end of 
	# current file with the fault characteristics
	if ($flaw_title ne "")
	{
	    $file_contents[$line_num] = $flaw_title."\n";
	    $line_num = $line_num + 1;

	    # if found crack properties of flaw, then 
	    # add after *Crack line after fault title, but before flaw properties
	    if ($flaw_fault_props ne "")
	    {
		 $file_contents[$line_num] = $flaw_fault_props."\n";
		 $line_num = $line_num + 1;		
	    }

	    # fault line describing intact crack flaw properties
	    $file_contents[$line_num] = $flaw_char."\n";
	    $line_num = $line_num + 1;

	    $flaw_title = ""; 
	}
    }

    # close the file
    close FILE_HANDLER_OLD;

    # first assume not propagating from both tips
    # if prop from end 1
    if (!$is_sand  && $curr_end == 1)
    {
	$fault_line = $current_fault_lines[$#current_fault_lines];
	# if number of fault lines > 3, then use second from end
	# in case fault was propagating from both tips at one point
	if ($#current_fault_lines > 2)
	{
	    $fault_line = $current_fault_lines[$#current_fault_lines-1];
	}
	if ($#current_fault_lines > 3)
	{
	    $fault_line = $current_fault_lines[$#current_fault_lines-2];
	}
    }
    elsif (!$is_sand && $curr_end == 2)
    {
	$fault_line = $current_fault_lines[0];
	# if number of fault lines > 3, then use second element listed
	# in case fault was propagating from both tips at one point
	if ($#current_fault_lines > 2)
	{
	    $fault_line = $current_fault_lines[1];
	}
	if ($#current_fault_lines > 3)
	{
	    $fault_line = $current_fault_lines[2];
	}
    }    
    # if propagating from both tips and more than 2 fault lines listed
    # use this line as property to set
    if (!$is_sand && $end_grow == 3 && $#current_fault_lines+1 > 2)
    {
	# if element just added to element 1, and propagating
	# from both tips
	$fault_line = $current_fault_lines[floor($#current_fault_lines/2)];
    }

    # if the fault header was read, but
    # the data line was not found, 
    # because the file does not end with a cr
    # use the last line of the input file
    if (!$is_sand && $found_fault == 1)
    {
	$index = $line_num-1;
	$data_line =  $file_contents[$line_num-1];
    }
       
    # split the data into different lines
    my @fault = split(/\s+/, $data_line);
    # set the number of elements of the new fault to 1
    $fault[0] = 1; 

    # if did not find a fault and not growing from a point
    if (scalar(@fault) == 0 && !$is_sand)
    {
	die "Could not find the properties of \n\tFAULT: $fault_name\n\tFILE: $prev_filename\n";
    }

    # if the user specifies different fault characteristics
    # add different characteristics (not including the first
    # characteristics, because this will be "*Crack"
    if ($found_crack)
    {
	my $char_size = $#characteristics;
	my $fault_size = $char_size+4; 
	@fault[5..$fault_size] = @characteristics[1..$char_size];
    }

    # if we are propagating from the beginning of the fault
    # use the xbeg, ybeg of old crack to the end of the new crack
    if ($curr_end == 1 && !$is_sand)
    { 
	# set the end of the new crack to the beg of the old crack
	@fault[3,4] = @fault[1,2];
	# set the beg of the crack to the new coordinates
	@fault[1,2] = @new_X_Y;	
    }
    
    # if propagating from end2
    # set the beg of the new element to the end of the old element
    # set the end of new element to the new coordinates
    elsif ($curr_end == 2 && !$is_sand) 
    {
	# set the beginning of the new crack to the end of old crack
	@fault[1,2] = @fault[3,4];
	# set the end of the new crack to the new coordinates
	@fault[3,4] = @new_X_Y; 

    }

    # if there is a file in the directory
    # representing anisotropic distribution, then change properties
    my $root_filename = $prev_filename;
    $root_filename =~ s/_cont\d+//g;
    my $itune  = index($root_filename, '_tune');
    if ($itune > -1)
    {
	$root_filename = substr($root_filename, 0, $itune);
    }

    my @aniso_file_list  =split(/\./, $root_filename);
    my $aniso_file = $aniso_file_list[0].".aniso_prop";
    #print "aniso crack file to look for: $aniso_file \n";
    if (-e $aniso_file)
    {
	@fault = make_aniso_crack($fault_name, \@fault, $aniso_file);
	#print "checked aniso crack props for fault: $fault_name in file: $prev_filename \n";
    }


    # format the new input line, if not sandbox 
    my $formatted_line = "";
    my @new_file_contents;
    my $new_file; 
    if (!$is_sand)
    {
	$formatted_line = join ("\t", @fault);
	$formatted_line = $formatted_line."\n";

	# add the formatted line to the array before the given index
	# and shift all the following lines appropriately
	@new_file_contents = insert($formatted_line, $index, @file_contents); 

	# convert the array to a string separated by \n
	$new_file = join('', @new_file_contents); 

	# change any previously added pupative elements with *Crack properties 
	# to fault properties in input file
	if ($found_crack)
	{
	    $new_file = set_fault_properties($prev_filename, $fault_name, $fault_line, $formatted_line, $new_file, $end_grow, $#current_fault_lines+1);
	}
    }
    # if growing from a point then
    # just set the new file contents to the existing file contents,
    # which will updated with the new fault in the previous if statements
    else
    {
	# add the formatted line to the array before the given index
	# and shift all the following lines appropriately
	@new_file_contents =  @file_contents; 

	# convert the array to a string separated by \n
	$new_file = join('', @new_file_contents);
    }


    # write the new working input to this file
    open FILE_HANDLER_NEW, ">", $testing_filename or die $!;
    # remove \M from end of lines
    $new_file =~ s/\r//g; 
    print FILE_HANDLER_NEW $new_file; 
    close FILE_HANDLER_NEW; 

}

# called:  @fault = make_aniso_crack($fault_name, \@fault, $aniso_file);
# input: refrence to list of line that contains new fault into, name of aniso file
# output: list of new fault line with anisotropic properties changed
sub make_aniso_crack
{
    my ($fault, $ref, $file) = (@_);
    my @old_fault_line = @$ref;
    my @new_fault_line = @old_fault_line;

    my @coors = @old_fault_line[1..4];
    my $dx = ($coors[2]-$coors[0]);
    my $dy = ($coors[3]-$coors[1]);
    my $global_angle = 0;
    if (abs($dx) < 1e-10)
    {
	$global_angle = 90;
    }
    elsif (abs($dy) < 1e-10)
    {
	$global_angle = 180;
    }
    else
    {
	$global_angle = atan(($coors[3]-$coors[1])/$dx)*(180/3.14159);

	if ($global_angle < 0)
	{
	    $global_angle = abs($global_angle);
	}
	else
	{
	    $global_angle = 180-$global_angle;
	}
    }

    my @props_aniso = ();
    my $found_exact = 0;
    my $min_diff = 360;
    open FILE_HANDLER, $file or die $!;
    while (<FILE_HANDLER>)
    {
	my $line = $_;

	if ($line =~ /^FAULT_NAME\s+/)
	{
	    my @line = split(/\s+/, $line); 
	    my @aniso_faults = @line[2..$#line];
	    my $found_aniso = 0;
	    foreach (@aniso_faults)
	    {
		my $aniso_fault = $_;
		# if current fault growing is one of the anisotropic faults
		if ($fault =~ /$aniso_fault/)
		{
		    $found_aniso = 1;
		}
	    }
	    if (!$found_aniso)
	    {
		return @old_fault_line;
	    }
	}
	elsif ($line =~ /^\s+\d+/)
	{
	    my @line = split(/\s+/, $line); 
	    my $ang = $line[1];
	    if ((abs($ang-$global_angle) < $min_diff))
	    {
		@props_aniso = @line[2..$#line];
		$min_diff = abs($ang-$global_angle);
	    }
	}
	elsif ($line =~ /^PROPS_I\s+/)
	{
	    my @line = split(/\s+/, $line); 

	    my @props_i = @line[2..$#line];
	    my $p_ai = 0;
	    foreach (@props_i)
	    {
		my $pi = $_;
		$new_fault_line[$pi+5] = $props_aniso[$p_ai];

		$p_ai++;
	    }
	    close FILE_HANDLER;
	    return @new_fault_line;
	}
    }

    print "WARNING: Anisotropic file found, but no properties set\n\n";
    return @old_fault_line;

}

# input: old fault coordinates and characteristics, new line just added, string of file contents, how fault is growing (end 1, 2, both(3)), 
#                 number of fault lines for this fault listed 
# output: any previously added elements have the same properties of the main fault
#         ensures that properties of newly added flaws are also consistent/updated
sub set_fault_properties
{
    my ($file, $fault_name, $old_fault, $new_element_line, $file_contents, $end_grow, $tot_lines) = @_;

    $old_fault =~ s/\n//g;
    $new_element_line =~ s/\n//g;

    my $tab_element = $new_element_line;
    my $tab_fault = $old_fault;
    $tab_element =~ s/\s+/\t/g;
    $tab_fault =~ s/\s+/\t/g;

    # make sure that old fault, and new element found in input file
    if ($tab_fault eq "")
    {
	die "Properties of fault: $fault_name, cannot be found in input file $file\n";
    }

    if ($tab_element eq "")
    {
	die "Properties of newly added element of fault: $fault_name, cannot be found in input file $file\n";
    }

    my @old_info = split(/\s+/, $old_fault);
    my $end = scalar(@old_info); 
    my @properties = @old_info[5..$end];

    my $new_contents = "";

    my @lines= split(/\n/,$file_contents);
    # determine if reading line of previously added pupative element
    # if reading prev pup element, replace old pup characteristics with fault chars
    # add updated line to new string of input file
    my $found_fault = 0;
    # list of strings of fault lines read in thus far
    my @fault_lines = ();
    my $fault_line_i = 0;

    my $replaced = 0;
    foreach my $line (@lines)
    {
	my $tab_line = $line;
	$tab_line =~ s/\s+/\t/g;

	# if see a line starting with a digit after reading in the fault
	# add to the fault lines
	if ($found_fault && $line =~ /^\d+/)
	{
	    push(@fault_lines, $line);
	    $fault_line_i++;
	}
	# signal reading faults
	if ($line =~ /^fault\s+$fault_name\s+/)
	{
	    $found_fault = 1;
	}
	# if reading header of different fault
	elsif ($found_fault && $line =~ /^fault\s+/)
	{
	    $found_fault = 0;
	}
	elsif ($found_fault && $line =~ /^\n/)
	{
	    $found_fault = 0;
	}
	# if this line is the previously added pupative element line 
	# if seen the fault properties, line starts with digit, did not just add this line
	# and line is not the old fault
	elsif ($found_fault && $end_grow != 3 && $line =~ /^\d+/ && 
	       ($tab_line ne $tab_element) && ($tab_line ne $tab_fault)) 
	{
	    my @coors =  split(/\s+/, $line);

	    # make the number of elements equal to the previous number of elements
	    my @new = ($coors[0]); 
	    @new[1..4] = @coors[1..4];
	    @new[5..$end-1] = @properties; 
	    $line = join("\t", @new);   

	}
	# if growing from both ends, this is the second line of the fault characteristics or the 2nd to last
	# and there are more than 2 fault lines
	# only update values of lines when total number of fault lines is greater than 2
	 # when lines <= 2, only two elements added, and no properties need updating 
	elsif ($end_grow == 3 && ($tot_lines > 2 && ($fault_line_i == 2 || $fault_line_i == $tot_lines)))
	{	  
	    my @coors =  split(/\s+/, $line);
	
	    # make the number of elements equal to the previous number of elements
	    my @new = ($coors[0]); 
	    @new[1..4] = @coors[1..4];
	    @new[5..$end-1] = @properties; # replace existing intact rock properties with fault properties
	    $line = join("\t", @new);   
	    
	}

	$new_contents = $new_contents.$line."\n";
    }	
        
    return $new_contents;

}

# change the flags in the previous input file so correct fault is not growing
# and so the next iteration uses this input file
# called: stop_grow($prev_filename, $fault);
# input: name of fric2d input file, string with "fault_name end"
# result: the end of fault_name is set to not grow in prev_filename
sub stop_grow
{
    my ($file, $info) = @_;

    my @fault = split(/\s+/, $info);

    # open file, or send error message 
    my $new_lines = "";
    open HANDLE, "$file" or die $!;
    while (<HANDLE>)
    {
	my $line = $_;
	# find the fault we are looking for
	if ($line =~ /^fault\s+$fault[0]\s+/)
	{
	    my @line_lst = split(/\s+/, $line);
	    # if end 1 is not growing anymore
	    if ($fault[1] == 1)
	    {
		$line_lst[3] = "no";
	    }
	    # if end 2 is not growing 
	    if ($fault[1] == 2)
	    {
		$line_lst[4] = "no";
	    }

	    $line = join("\t", @line_lst)."\n";
	    #print "new header line: $line \n";

	}
	$new_lines = $new_lines.$line;
    }
    close HANDLE;

    open HANDLE_NEW, ">", $file or die $!;
    # remove \M from end of lines
    $new_lines =~ s/\r//g; 
    print HANDLE_NEW $new_lines."\n";
    close HANDLE_NEW; 
}


# called: $flaw_title = format_title ($this_Line); 
# input: list of fault characteristics, name, x, y, length, grow dir...
# output: fault heading for fric2d input file ## ONLY GROW FROM END2
sub format_title
{
    my ($line) = @_;

    my @info = split(/\s+/, $line);

    # assume point only growing in one direction
    my $end1 = "no";
    my $end2 = "yes";
    # if the point is growing from both ends then
    # signal growing from both tips of added element
    if ($info[5] =~ /yes/)
    {
	$end1 = "yes";
    }

    return join("\t",("fault", $info[1], "no", $end1, $end2));
}

# called: $flaw_char = format_char ($this_Line, \@new_X_Y); 
# input: line starting with *Flaw header, the new coordinates calculated from geometry
# output: fault characteristics of flaw for fric2d output file
sub format_char
{
    my ($line, $ref) = @_;
    my ($x, $y) = @$ref;

    my @info = split(/\s+/, $line);

    # get the characteristics from the elements of 
    # the info line from 5 to the end
    my @char;
    foreach (@info[6..$#info])
    {
	push(@char, $_); 
    }

    return join("\t", (1, $info[2], $info[3], $x, $y, @char));

    
}

# called: my @new_file_contents = insert($formatted_line, $index, @file_contents); 
# input: element to be inserted, index to insert at, array 
# output: array with element inserted at proper index
sub insert
{
    my ($element, $index, @array) = @_;

    my @new_array = @array[0..$index];
    $index++;
    $new_array[$index] = $element; 

    my $last_index = scalar(@array) - 1; 
    push(@new_array, @array[$index..$last_index]);

    return @new_array;

}

#####################################################################
#  FUNCTIONS TO CALCULATE WORK
####################################################################
# called:my ($prev_work, $crit_work, $new_work_out, $new_raw_out) = 
#	get_initial_work($input_filename, $fric_output_filename, $fault,
#			 $run_mode, $prev_run_work, 
#			 $input_criterion, 
#			 $topo_filename);
# output: initial work of the system, input criterion given by user, print statements
sub get_initial_work
{
    my ($input_filename, $fric_output_filename, $fault_name, $run_mode, $prev_work,
	$input_criterion,  $topo_filename) = @_;
 
    my @geometry;
    my $crit_work;
			
    my $work_output = "";
    # if using critical work value, and faults were found in input file
    if ($input_criterion != 0 && $fault_name ne "")
    {
	# get the element size 
	@geometry = get_geometry($input_filename, $fault_name, 1);

	# calculate the work criterion per unit area of element 
	# (elements extend 1 m out of plane)
	$crit_work = $geometry[4]*$input_criterion;
	
	$work_output = "\tCritical del Work: $crit_work \n\n";
	print $work_output;
    } 	

    # set the initial work as the previous run's work, if previously calculated
    my $curr_work = $prev_work;
    # if previous work not calculated or passed, then use fric2d
    if (!$prev_work)
    {
	# get the work
	$curr_work = calc_work($run_mode, $input_filename, $fric_output_filename, $topo_filename);
    }

    my $raw_output = "\nInitial Work: $curr_work J\n\n";
    print $raw_output;

    return ($curr_work, $crit_work, $work_output, $raw_output);
}

# called: $curr_work = calc_work($run_mode, $input_filename, $fric_output_filename, $topo_filename);
# input: run mode, fric2d input filename, fric2d output filename
#        topography filename
# output: work of this system
sub calc_work
{		
    my ($run_mode, $testing_filename, $fric_output_filename, $topo_filename) = @_; 
	
    my $work = 0; 

    if (length($testing_filename) > 50)
    {
	die "FILENAME ERROR: LENGTH OF FILENAME ($testing_filename) > 50 characters.\n\tCannot be read by FRIC2D.\n";
    }

    # if run mode contains the word debug
    # sandbox debugging or fric2d debugging
    if ($run_mode =~ /debug/)
    {
	return get_work($run_mode, '_');
    }
    # if user includes a topo file, run sandbox
    elsif ($topo_filename)
    {
	if ($topo_filename =~ /\.topo$/) 
	{
	    run_sandbox($testing_filename, $fric_output_filename, 
			$topo_filename);
	    $work = get_work($run_mode, $fric_output_filename);
	    return $work;
	}
    }
    
    # if user does not include topo file
    # and run mode is not debugging
    run_FRIC2D($testing_filename, $fric_output_filename); 
    $work = get_work($run_mode, $fric_output_filename);
    
    return $work;
}


sub run_code
{
    my ($run_mode, $testing_filename, $fric_output_filename, $topo_filename) = @_; 
    if (length($testing_filename) > 50)
    {
	die "FILENAME ERROR: LENGTH OF FILENAME ($testing_filename) > 50 characters.\n\tCannot be read by FRIC2D.\n";
    }

    # if run mode contains the word debug
    # sandbox debugging or fric2d debugging
    if ($run_mode =~ /debug/)
    {
	# don't running anything if bebugging
	return;
    }
    # if user includes a topo file, run sandbox
    elsif ($topo_filename)
    {
	if ($topo_filename =~ /\.topo$/) 
	{
	    run_sandbox($testing_filename, $fric_output_filename, 
			$topo_filename);
	    return;
	}
    }
    
    # if user does not include topo file
    # and run mode is not debugging
    run_FRIC2D($testing_filename, $fric_output_filename); 
}



# called: run_FRIC2D($testing_filename, $fric_output_filename); 
# input: name of filename to run, name of output file
# result: fric2d is run for the given input file, producing the output file
sub run_FRIC2D
{
    my $input_file = $_[0];
    my $output_file = $_[1];

    # run FRIC2D on this given input file, and write to this output file
    system("./fric2d", "-i", $input_file, "-o", $output_file, "-v");

    # test if any errors occured
    if ($? == -1)
    {
	die $!;
    }
    
}

# called: run_sandbox($testing_filename, $fric_output_filename, $topo_filename);
# input: name of input file, output file and topography file
# result: sandbox is run on the input file, with the topography file
#        producing the given output filename
sub run_sandbox
{
    my ($input_file, $output_file, $topo_file) = @_;

    # run FRIC2D on this given input file, and write to this output file
    system("./sandbox", "-i", $input_file, "-o", $output_file, "-t", $topo_file, "-v");

    # test if any errors occured
    if ($? == -1)
    {
	die $!;
    }
    
}


# use terminal commands to shell out this work
# called: $work = get_work($fric_output_filename);
# input: name of FRIC2D output file
# output: the work required by this arrangement
sub get_work
{
    # get the name of the FRIC2D output file
    my ($run_mode, $filename) = @_; 

    # if debugging, return random number
    if ($run_mode =~ /debug/)
    {
	return 10000000*rand(100);
    }

    # run the program via the shell
    # terminal must be in the same directory as the script being executed
    system("perl", "Wext.pl", $filename);

    # test if errors occurred
    if ($? == -1)
    {
	die $!;
    }

    # open the output file and return the value
    my $output_filename = $filename."-extWork"; 
    my $work;

    open FILE_HANDLER, "<", $output_filename or die $!;
    while (<FILE_HANDLER>)
    {
	$work = $_;
    }

    # close and delete the output file
    close FILE_HANDLER;
    unlink "$output_filename" or warn "Could not delete file: $!\n"; 

    return $work;
}

####################################################
## FUNCTIONS TO TEST WHETHER TO CONTINUE PROPAGATION
####################################################

# called: $continue_propagate = test_prop_many($prev_work, $min_work, 
#					     $crit_work, 
#					     $if_sequence); 
# input: the previous work of the system, the current work (the minimum work),
#        the critical work of this system, 
#        the number of scenarios being tested during the next iteration
# output: 1, if there are faults still growing, 0 to stop propagating
sub test_prop_many
{
    my ($work_prev, $work_curr, $work_crit, $scen_num) = @_; 

    # if the minimum was not found for this scenario
    # if all the angles tested intersect the fault from which the
    # cracks originate
    if ($work_curr == 0)
    {	
	print "\nFault intersects itself: terminating propagation.\n";
	return 0; 
    }
    elsif ($work_curr == -1)
    {
	print "\nNo pupative element(s) slipping for all faults: terminating propagation. \n";
	return 0;
    }
    else
    {	
	if ($work_crit != 0)
	{
	    print "Critical del work: $work_crit \n\n"; 
	}

    } 

    # if there are no more faults propagating
    if ($scen_num == 0)
    {
	print "No faults are propagating: terminating propagation. \n";
	return 0;
    }

    # otherwise continue propagating
    return 1; 
}

###############################################
## FUNCTIONS TO CONTROL OUTPUT/PRINT STATEMENTS
###############################################
sub get_output_elements;
sub get_element;

# called:  my $print_screen_summary = format_std_out($fric_output_filename, $prop_num, 
#                                                    $curr_work, $fault, $angle);
# input: fric2d output name (may not exist while DBing), 
#        propagation number
#        work calculated at this iteration
#        fault name, angle
# output: string formatted to print to screen
sub format_std_out
{
    my ($file, $prop, $result, $fault, $angle) = @_;
    my $output;

	my @works = split(/\t/, $result);
	if ($#works == 1)
	{
		my $wext = $works[0];
		my $wext_A = $works[1];
		
		$output = sprintf("%-10s %-10s %-10s %-18s %-18s\n", "Prop", "Fault End", "Angle", "Wext (J)", "delWext/delA (J/m^2)");
		$output = $output.sprintf("%-10s %-10s %-10s %-18s %-18s\n", $prop, $fault, $angle, $wext, $wext_A);
	}
	else	
	{
		$output = sprintf("%-10s %-10s %-10s %-15s\n", "Prop", "Fault End", "Angle", "Result");
		$output = $output.sprintf("%-10s %-10s %-10s %-15s\n", $prop, $fault, $angle, $result);
	}
	
    print $output; 

    # if not debugging, then get info from the output file
    if (-e $file)
    {
	printf ("\t%-10s %-10s %-10s %-10s %-15s %-15s %-15s %-15s %-15s\n", "Fault", "End", "Angle", "Element", "DS", "DN", "Sigma-S", "Sigma-N", "Condition Number");
	my $output_2 = get_output_elements($file, {$fault => $angle});    
	print $output_2;
	
	$output = $output.$output_2;
    }

    return $output; 
}


# called:print_work_summary(1, "SUMMARY FOR FAULT: $fault\n", \%this_fault, \%this_fault_unnorm);  (angle => work)
#     print_work_summary(0, "EFFICIENT GEOMETRY FOR PROPAGATION $prop\n", 
#                        \%eff_fault_angle); (fault name => angle )
# input: bool, true if summarizing fault work values
#        title to print before hash table data
#        reference to hash table
# result: relative info printed to terminal
# output: print statements to be written to screen
sub print_work_summary
{
    my ($is_fault, $title, $hash_ref, $hash_unnorm_ref) = @_;
    
    my $output = "\n$title";

    my %hash = %$hash_ref;
	
    # if a fault summary, sort keys numerically
    if ($is_fault)
    {
	
	my %hash_unnorm = %$hash_unnorm_ref;
	$output = $output.sprintf("\t%-15s %-18s %-18s\n", "Angle", "Wext (J)", "delWext/delA (J/m^2)");
	for my $angle (sort {$a <=> $b} keys %hash)    
	{
	    $output = $output.sprintf("\t%-15s %-18s %-18s\n", $angle, $hash{$angle}, $hash_unnorm{$angle});
	}
    }
    # if propagation summary, sort keys alphabetically
    else
    {
	$output = $output.sprintf "\t%-15s %-15s\n", "Fault End", "Angle";
	for my $fault (sort keys %hash)
	{
	    $output = $output.sprintf("\t%-15s %-15s\n", $fault, $hash{$fault});
	}
    }

    print $output;
    return $output; 
}


# called: my ($element_ref, $angle_ref) = get_output_elements($output_filename, $i, $scen_ref);
# called: 	my $output_2 = get_output_elements($file, {$fault => $angle});  
# input: output filename, scenario index number, reference to scenario hash table
# output: list of element numbers that represent element that was just added to fault
sub get_output_elements
{
    my ($filename, $ref) = @_;

    # if this file exists
    if (-e $filename)
    {
	my %this_scenario = %$ref; 
	my $output_lines = "";
	
	# for all the faults in the index hash table at the given index
	foreach my $fault_name_end (sort keys %this_scenario)
	{
	    my ($fault, $end) = split(/\s+/, $fault_name_end);
	    my $angle = $this_scenario{$fault_name_end}; 
	    
	    # look up the element number, SS, NS, DS, DN, condition number 
	    my $line = get_element($filename, $fault, $end);
	    
	    if ($line eq "")
	    {
		print "WARNING: Element added to end $end of fault $fault cannot be found in $filename. \n"; 
		return "";
	    }
	    
	    my $start_line = sprintf("%-10s %-10s %-10s", $fault, $end, $angle);
	    $output_lines = $output_lines."\t".$start_line.$line; 
	}
  
	return $output_lines."\n";
    }
    
    # if there is no output file because we are debugging
    return ""; 
}

# return condition number
# get_cond_num($run_mode, $output)
sub get_cond_num
{
    my ($run_mode, $filename) = @_;

    if ($run_mode =~ /debug/)
    {
    	return 100;
    }

     # open file, or send error message 
    open HANDLER, "$filename" or die $!;

    my $cond_num = 0;

    while (<HANDLER>)
    {
	my $line = $_;

	# if the line starts with the word "fault"
	# then remember that input cooresponding to a fault has been found
	if ($line =~ /^CONDITION NUMBER/)
	{
	    my @data_l = split(/\s+/, $line);
	    $cond_num = $data_l[3];
	    return $cond_num;
	}
    }

    return $cond_num;
}

# called: my $this_element = get_element($filename, $fault, $end);
# input: name of output file, name of fault, end of fault growing from (1 or 2)
# output: string formatted: "element number DS DN SS NN" if element found, "" otherwise
sub get_element
{
    my ($filename, $fault, $end) = @_;

     # open file, or send error message 
    open HANDLER, "$filename" or die $!;

    my $found_status = 0;
    my $element_number = 0;
    my @data;

    my $end_load = 0;
    my $cond_num = 0;

    while (<HANDLER>)
    {
	my $line = $_;
	my @info = split(/\s+/, $line);

	# if the line starts with the word "fault"
	# then remember that input cooresponding to a fault has been found
	if ($line =~ /^CONDITION NUMBER/)
	{
	    my @data_l = split(/\s+/, $line);
	    $cond_num = $data_l[3];
	}
	elsif ($line =~ /^DATA FROM LOADING STEP #/)
	{
	    my @data_l = split(/\s+/, $line);
	    my $curr_l = $data_l[4];
	    $curr_l =~ s/#//g;
	    my $fin_l = $data_l[6];

	    if ($curr_l==$fin_l)
	    {
		$end_load = 1;
	    }
	}
	elsif ($end_load && $line =~ /^FAULT:\s+$fault\s/ )
	{
	    $found_status = 1;
	}
	elsif ($end_load && $line =~ /^FAULT:\s+/ )
	{
	    $found_status = 0;
	}
	elsif ($line =~ /BE    Tangential   maxPrinc(top)  angle(top)  Tangential  maxPrinc(bot)  angle(bot)/)
	{
	    $found_status = 0;
	}
	# if we have seen the elt header twice after seeing the fault name
	# and the line starts with a digit
	# record the element number
	elsif ($end_load && $line =~ /^\s+\d+\s+/ && $found_status && $#info<13)
	{

	    # if the fault is growing from end 1, return the first number in the line
	    if ($end == 1)
	    {
		close HANDLER;
		return sprintf("%-10s %-15s %-15s %-15s %-15s %-5s\n", $info[-9], $info[-8], $info[-5], $info[-2], $info[-1], $cond_num);
	    }

	    # if the fault is growing from end 2, continue looking
	    # and remember this number
	    @data = @info;
	}
	# if we found the element, this line is a new line,
	# and we are growing from end 2
	# return the last element number we found
	elsif ($end_load && $found_status && $#data>-1 && $line =~ /^\n/ && $#info<13)
	{
	    close HANDLER;
	    return sprintf("%-10s %-15s %-15s %-15s %-15s %-5s\n", $data[-9], $data[-8], $data[-5], $data[-2], $data[-1], $cond_num);
	}
	
    }

    # if the element number was not found, return ""
    return "";
}


# input: root of the filenames, reference to all the scenarios generated
# result: an index of all the scenarios tested at each iteration
#   is written to the file root_prop_num.index
#   thus there will be multiple index files generated
sub write_index
{
    my ($root, $prop_num, $scen_ref) = @_;

   # my $index_filename = $root."_".$prop_num.".index";
    my $index_filename = $root.".index"; 
    my %scenarios = %$scen_ref; 

    my $file_name = $root.".in"; 
    if ($prop_num != 1)
    {
	$file_name = $root.".eff"; ; 
    }

    my $formatted = "Scenario Index of File $file_name for Propagation $prop_num \n\n".
	"Scenario \tFault \tEnd \tAngle".
	"\n-------------------------------------\n";

    foreach my $scenario_index (sort {$a <=> $b} keys %scenarios)
    {
	
	$formatted = $formatted.$scenario_index;
	foreach my $fault_name_end (sort keys %{$scenarios{$scenario_index}})
	{
	    my ($fault, $end) = split(/\s+/, $fault_name_end);
	    
	    $formatted = $formatted.
		"\t\t$fault \t$end \t$scenarios{$scenario_index}{$fault_name_end} \n"; 

	}
	$formatted = $formatted."\n"; 
    }
    $formatted = $formatted."\n";
   
    # get the old contents of the index file, and write both strings to this file
    # open file, or send error message 
    if ($prop_num > 1)
    {
	open FILE_HANDLER, "$index_filename" or die $!;

	my $file_contents = ""; 
	while (<FILE_HANDLER>)
	{
	    $file_contents = $file_contents.$_;
	}
	
	close FILE_HANDLER;
	$formatted = $file_contents.$formatted;

    }
    write_output($index_filename, $formatted);
}

# called: write_output($index_filename, $formatted);
# input: name of file to write the output to 
#        string representing work at each iteration of program
# result: string is written to $output_filename
sub write_output
{
    my @input = @_;
    my $output_filename = $input[0];

    # get the string that will be the contents of the input file
    # by removing the name of the name of input file
    shift(@input);

   # for the wrapper version of this, write the work to an output file
    open FILE_HANDLER, ">", $output_filename or die $!;
    print FILE_HANDLER "@input";
    close FILE_HANDLER;
}

###########################################################

# FUNCTIONS TO TEST WHETHER A FAULT INTERSECTS ANY ELEMENTS
###########################################################

# input: number
# output: 0 if the number is really small, 
#         or the original number rounded to 8 decimal places
sub check_number
{
    if (abs($_[0]) < 1e-15)
    {
	return 0;
    }
    return (sprintf("%.8f", $_[0]));
}

sub get_end_points;
sub one_intersect;
sub is_equal; 
sub get_line;  

#my $scen = {"lil1 1" => 180};
#my $test_filename = 'ebl.in';
#my %result = test_intersect_scenario($scen, $test_filename);


# test if any of the faults growing in this scenario
#       intersect any other elements or boundaries
# called: test_intersect_scenario(\%this_scenario, $testing_filename); 
# input: reference to scenario hash "fault end" => angle, testing filename
# output: hash table containing intersection info, 
#         if an intersection exists, otherwise hash{"names"} = () 
sub test_intersect_scenario
{
    my ($scen_ref, $test_filename) = @_;

    my %scenario = %$scen_ref;
    my %result; 
    $result{"names"} = ("<none>"); 

    # for each fault and name listed in the scenario,
    # check if there is an intersection
    # if there is an intersection for one fault+end then function returns
    foreach my $fault_name_end (keys %scenario)
    {
        #print "testing: $fault_name_end \n";
	%result = test_intersect($fault_name_end, $test_filename);
	my @name_ends = @{$result{"names"}};

	# if an intersection was found
	# stop testing other scenarios
	if ($name_ends[0] ne "<none>")
	{
	    return %result;
	}
	
    }
    
    # no intersection between any faults or boundaries
    return %result; 
}

#called: my $dist = get_distance($fault1, $fault_end, \@coors);
# input: string with "xbeg ybeg xend yend", fault_end 1 or 2, reference to list of intersection coordinates
# output: distance from propagating tip of fault and intersection coordinates
sub get_distance
{
    my ($fault, $end, $ref) = @_;
    
    my @seg = split(/\s+/, $fault);
    my $fault_x = $seg[2];
    my $fault_y = $seg[3];
    if ($end == 1)
    {
	$fault_x = $seg[0];
	$fault_y = $seg[1];
    }

    my @coor = @$ref;
    return sqrt(($fault_x-$coor[0])**2 + ($fault_y-$coor[1])**2);
    
}

#my $fault_name_end = 'lil3 2';
#my $test_filename = 'els.in';
#my %result = test_intersect($fault_name_end, $test_filename);

# note: this algorithm does not find faults that
#       exactly equivallent to other existing faults in the program
# called: %result = test_intersect($fault_name_end, $test_filename);
# input: name of fault to which an element was added,  name of fric2d input file,
# output: hash table containing information to use to format new input files
#         "names" => @names, "coors" => @coors, "<bound>" => coordinates?, "fault_name" => coordinates?
sub test_intersect
{
    my ($fault_name_end, $input_file) = @_;

    # get the name and end of the fault
    my @data = split(/\s/, $fault_name_end);
    my $fault_name = $data[0];
    my $fault_end = $data[-1]; 

    # get the end points of all the boundaries and elements
    my ($bound_ref, $fault_ref) = get_end_points($input_file);

    my @bounds = @$bound_ref; 
    my %faults = %$fault_ref;

    my %initial_faults;  
    my %intersect_info; 

    # get all the elements associated with the fault that is growing
    # and the faults that are not propagating
    my @fault_elements; 
    foreach my $name (keys %faults)
    {
	# if this is the fault that is growing at this iteration
	if ($name eq $fault_name)
	{
	    my @data = split(/\n/, $faults{$name}); 

	    # add to the list that maintains the elements
	    # of the growing fault
	    foreach(@data)
	    {
		my $el = $_;
		if ($el =~ /\d+/)
		{
		    push(@fault_elements, $_); 
		}
	    }

	}
	else
	{
	    # add to the hash table of faults that are not currently growing
	    $initial_faults{$name} = $faults{$name} ;
	}
	
    }

    if (scalar(@fault_elements) == 0)
    {
	die "COULD NOT FIND FAULT ELEMENTS OF GROWING FAULT $fault_name IN INPUT FILE $input_file \n";
    }


    # only test the first or last element of the fault,
    # depending on the end we are growing from
    my $fault1 = $fault_elements[-1]; 
    my $i = scalar(@fault_elements)-1;
    if ($fault_end == 1)
    {
	$i = 0; 
	$fault1 = $fault_elements[0];
    }

    # test for intersections of these elements with the rest of the fault
    my $j = -1; 
    foreach(@fault_elements)
    {
	$j++;
	my $fault2 = $_;

	# if we are not referring to the same element
	#if ($i != $j)
	if (abs($i - $j)>4) # if more than 3 elements away ??
	{
	    # array of coordinates of intersection, 
	    # and coordinates of elements that intersect
	    # fault1 = growing fault, fault2 = other fault seg
	    my @coors = one_intersect($fault1, $fault2, $fault_end); 

	    # if we found intersection, and the coordinates do not
	    # meet at one node
	    if (scalar(@coors) != 0 && $coors[0] != 1e50) 
	    {	
		my @names = ($fault_name_end, $fault_name_end); 
		@{$intersect_info{"names"}} = @names;
		@{$intersect_info{"coors"}} = @coors;		
		
		# do not add any other information to this hash
		# because if a fault intersects itself then
		# no correction to the input file is attempted
		return %intersect_info;
	    }
	}	
    }

    # test if the element intersects any of the other faults
    # minimum distance from propagating tip to any intersection
    my $min_dist = 1e10;
    my $node_connects = 0;

    foreach my $fault_name2 (keys %initial_faults)
    {
	my @segments2 = split(/\n/, $initial_faults{$fault_name2}); 

	# find all of the possible intersections
	# return information about the intersection that is closest to propagating tip of fault1
	foreach (@segments2)
	{
	    my $fault2 = $_;

	    #print "testing intersections with other faults or boundaries \n";

	    my @coors = one_intersect($fault1, $fault2, $fault_end);	   

	    #print "growing fault: $fault1 \n";
	    #print "potential intersecting: $fault2 \n";

	    # remember if propagating tip connects to a segment of this fault
	    if (scalar(@coors) != 0 && $coors[0] == 1e50)
	    {
		$node_connects = 1;
	    }
	    # if we found an intersection, and propagting tip of fault
	    # does not connect to any other nodes of fault
	    elsif (scalar(@coors) != 0 && !$node_connects)
	    {	
		#print "intersection detected \n";
		#print "intersection coors: @coors \n";
		#die;

		# get distance between intersection coordinates and tip of propagating fault
		# remember the 'intersection' that is the smallest distance between
		# the propagating fault tip
		my $dist = get_distance($fault1, $fault_end, \@coors);
		my @fault1_data = split(/\s+/,$fault1);
		
		# if coordinate of intersection with fault falls on propagating fault
		# consider that = 0 distance away
		if (on_element(\@coors, \@fault1_data))
		{
		    $dist = 0;
		}

		if ($dist < $min_dist)
		{
		    $min_dist = $dist;  
		    #### HERE THE END OF THE SECOND FAULT IS "M", because 
		    # WE HAVE INTERSECTED A FAULT SOMEWHERE IN THE MIDDLE
		    my @names = ($fault_name_end, $fault_name2." M"); 
		    # remember the names of the intersection and the coordinates
		    @{$intersect_info{"names"}} = @names;
		    @{$intersect_info{"coors"}} = @coors;
		    
		    # remember the coordinates of the segments that are intersecting
		    $intersect_info{$fault_name_end} = $fault1;
		    $intersect_info{$fault_name2." M"} = $fault2;
		
		}  
	    }
	}


	# if we found an intersection, 
	# and no part of this fault already intersects the propagating tip
	# return information about the closest info only
	if ($min_dist != 1e10 && !$node_connects)
	{
	    return %intersect_info;
	}
    }

    $node_connects = 0;
    $min_dist = 1e10;
    # test if the element intersects any of the boundaries
    foreach(@bounds)
    {
	my $fault2 = $_;

	my @coors = one_intersect($fault1, $fault2, $fault_end);
       	
	# remember if propagating tip connects to a segment of a boundary
	if (scalar(@coors) != 0 && $coors[0] == 1e50)
	{
	    $node_connects = 1;
	    @{$intersect_info{"names"}} = ("<none>");
	    return %intersect_info;
	}
	elsif (scalar(@coors) != 0 && !$node_connects)
	{	    
	    my $dist = get_distance($fault1, $fault_end, \@coors);
	    my @fault1_data = split(/\s+/,$fault1);

	    # if coordinate of intersection with boundary falls on propagating element tip
	    # consider that = 0 distance away
	    if (on_element(\@coors, \@fault1_data))
	    {
		$dist = 0;
	    }

	    if ($dist <= $min_dist)
	    {
		$min_dist = $dist;  

		my @names = ($fault_name_end, "<bound>"); 
		# remember the names of the intersection and the coordinates
		@{$intersect_info{"names"}} = @names;
		@{$intersect_info{"coors"}} = @coors;
		
		# remember the coordinates of the segments that are intersecting
		$intersect_info{$fault_name_end} = $fault1;
		$intersect_info{"<bound>"} = $fault2;
	    }
	}
    

	# if we found an intersection with a boundary, 
	# return information about the closest info only, and only correct the closest intersection
	# before this was outside the loop
	if ($min_dist != 1e10 && !$node_connects)
	{
	    return %intersect_info;
	}
	
    }


    # signal that this fault does not intersect any other faults
    # or boundaries
    @{$intersect_info{"names"}} = ("<none>");
    return %intersect_info;

}

# test to see if two segments are connected end to beg, or beg to end
sub connected;

sub closest_point;
sub get_line_intersection;

#my $faultgr = "0.00085	0.00339	0.00078	0.00334 1";
##my $fault = "0.00086 0.00330 0.00083 0.00338 1"; # should intersct
#my $fault = "0.00083 0.00338 0.00079 0.00345"; # no intersection
#my $res = one_intersect($faultgr, $fault, 1);

# called: my $is_intersect = one_intersect($fault1, $fault2, $fault_end);
# input: end points of two line segments, fault1 is growing fault
# output: coordinates of intersection point on segment2
#         that is the projection of seg1 onto seg2
sub one_intersect
{
    my ($seg1_s_all, $seg2_s_all, $fault_end) = @_;

    # convert string to arrays
    my @seg1_all = split(/\s+/, $seg1_s_all);
    my @seg2_all = split(/\s+/, $seg2_s_all);
    
    my @seg1 = @seg1_all[0..3];
    my @seg2 = @seg2_all[0..3];

    my $seg1_s = join(" ", @seg1);
    my $seg2_s = join(" ", @seg2);

    if (scalar(@seg1) == 0)
    {
	die "Error in intersection function: Could not find coordinates of segment.\n";
    }
    if (scalar(@seg2) == 0)
    {
	die "Error in intersection function: Could not find coordinates of segment.\n";
    }
    
    # if the segments exactly equal, then we are recounting the element twice
    if ($seg1_s eq $seg2_s)
    {
	# return the x,y of the beginning of segment 1
	return @seg1[0..1];
    }

    # if the segments are connected then they do NOT intersect 
    # the algorithm to calculate the coordinates ensures this
    if (connected($seg1_s, $seg2_s, $fault_end))
    {
	return (1e50, 1e50);
    }

    # if distance between one set of coordinates <= 2 length
    # then find infinite intersection point
    my ($x1b, $y1b, $x1e, $y1e, $num1) = @seg1_all;
    my ($x2b, $y2b, $x2e, $y2e, $num2) = @seg2_all;

    my $dlen = 0.5*sqrt(($x1b-$x1e)**2 + ($y1b-$y1e)**2)/($num1);

    # find equations of lines
    my ($m1, $b1) = get_line(@seg1);
    my ($m2, $b2) = get_line(@seg2);

    # if growing from end 1, only consider the beginning
    my $x1 = $x1b;
    my $y1 = $y1b;
    if ($fault_end == 2)
    {
        $x1 = $x1e;
        $y1 = $y1e;
    }

    # check that the elements are not crossing
    # if they are, then no intersection
    my @inter_coors = get_line_intersection(\@seg1, \@seg2);
    # if the intersection of the lines within the x and y 
    # coordinates of both of the segments
    if (scalar(@inter_coors))
    {
	my $xint = $inter_coors[0];
	my $yint = $inter_coors[1];
	if ($xint <= max_list($x1b, $x1e) && $xint>= min_list($x1b, $x1e) && $yint <= max_list($y1b, $y1e) && $yint>= min_list($y1b, $y1e))
	{
	    if ($xint <= max_list($x2b, $x2e) && $xint>= min_list($x2b, $x2e) && $yint <= max_list($y2b, $y2e) && $yint>= min_list($y2b, $y2e))
	    {
		print "Found intersection of growing elements: $seg1_s $seg2_s \n";
		return ();
	    }
	}
    }

    # find point on seg2 that is closest to beginning of seg1, and end of seg1
    my ($xn, $yn, $d_near) = 
	closest_point($x1, $y1, \@seg2);

    # if the closest distance from either endpoint and mid point 
    # is greater than a half length of element,
    # then no intersection
    if ($d_near > $dlen)
    {
	return ();
    }

    #print "found nearby element \n";
    #print "testing coors: $x1 $y1 \n";
    #print "distance= $d_near, double element len=$dlen \n";

    # now the elements are within 2 element lengths of each other

    # if the number of elements > 1
    # find which endpoints of seg2 the x1, y1 are closest to

    my $de = sqrt(($xn-$x2e)**2 + ($yn-$y2e)**2);
    my $db = sqrt(($xn-$x2b)**2 + ($yn-$y2b)**2);

    # otherwise return the coordinates of the closest point on seg2
    # found above
    if ($de < $db)
    {
    #return ($xb_near, $yb_near);
    # return the coordinates of the beginning of the segment 2
    #print "found intersection of fault1 near end of segment 2: $x2e, $y2e \n";
	return ($x2e, $y2e);

    }
    #print "found intersection of fault1 near beg of segment 2: $x2b, $y2b \n";
    return ($x2b, $y2b);
    

 #    # find the intersection of the projection of seg1
 #    # and seg2
 #    # if this intersection pt falls on seg2, return these coordinates
 #    my @inter_coors = get_line_intersection(\@seg1, \@seg2);

 #    my $is_connected = connected($seg1_s, $seg2_s, 0); # if either end of nodes connected, use closest points instead

 #    # if the infinite projection of these lines 
 #    # and the coordiantes fall within segment 2
 #    # then use the projection of seg1 onto seg2
 #    if (on_element(\@inter_coors, \@seg2) && !$is_connected)
 #    {
	# return @inter_coors;
 #    }

 #    # otherwise return the coordinates of the closest point on seg2
 #    # found above
 #    if ($closest_dist == $db_near)
 #    {
	# return ($xb_near, $yb_near);
 #    }
 #    #else #if ($closest_dist == $de_near)
 #    #{
 #    #print "$xe_near, $ye_near";
 #    #die;
 #    return ($xe_near, $ye_near);
 #    #}

    
}

# called:  my @inter_coors = get_line_intersection(\@seg1, \@seg2);
# input: reference to lists of end points of propagating segment
#        and segment it intersects
# output: coordinates of the intersection of the 
#        projection of these two lines
sub get_line_intersection
{
    my ($r1, $r2) = @_;
    my @seg1 = @$r1;
    my @seg2 = @$r2;

    my ($m1, $b1) = get_line(@seg1);
    my ($m2, $b2) = get_line(@seg2);

    my $x_inter;
    my $y_inter;

    # if both vertical, and same x intercept
    if ($m1 eq 'x-in' && $m2 eq 'x-in' && $b1 == $b2)
    {
	# return end point on seg1 that
	# falls within segment 2
	my @coors = @seg1[0..1];
	if (on_element(\@coors, \@seg2))
	{
	    return @seg1[0..1];
	}
	# if beg of seg1 does not fall within seg 2
	# return end of seg1
	else
	{
	    return @seg1[2..3];
	}
    }
    # if both vertical and different x intercept
    # they do not intersect
    elsif ($m1 eq 'x-in' && $m2 eq 'x-in' && $b1 != $b2)
    {
	return ();
    }
    # if one vertical, x = x-intercept
    elsif ($m1 eq 'x-in')
    {
	$x_inter = $b1;
	$y_inter = $m2*$x_inter + $b2;
    }

    #  if one vertical, x = x-intercept
    elsif ($m2 eq 'x-in')
    {
	$x_inter = $b2;
	$y_inter = $m1*$x_inter + $b1;
    }
    # if parallel with different y intercept
    # they do not intersect
    elsif($m1 == $m2 && $b1 != $b2)
    {
	return ();
    }
    # if parallel with same y intercept
    elsif ($m1 == $m2 && $b1 == $b2)
    {
	my @coors = @seg1[0..1];
	if (on_element(\@coors, \@seg2))
	{
	    return @seg1[0..1];
	}
	# if beg of seg1 does not fall within seg 2
	# return end of seg1
	else
	{
	    return @seg1[2..3];
	}
    }
    # if neither vertical
    # and not parallel
    else
    {
	$x_inter = ($b2 - $b1)/($m1 - $m2); 
	$y_inter = $x_inter*$m2 + $b2; 
    }

    return ($x_inter, $y_inter);

}

sub connected_one;

# called:  my ($xm_near, $ym_near, $dm_near) = closest_point($x1m, $y1m, \@seg2);
# input: x , y coordinate of point, beginning and end coordinates of segment
# output: x, y coordinate on seg2 closest to point given, 
#         distance from closest point on seg2 to input point
sub closest_point
{
    my ($x1, $y1, $ref) = @_;
    my @seg2 = @$ref;

    # check that x2 and y2 fall within the bounds of 
    # segment 2, if they do not, then use the endpoints
    # of segment 2 that are closest to x2 and y2
    my ($xb, $yb, $xe, $ye) = @seg2;

    if (connected_one($x1, $y1, $xb, $yb, $xe, $ye))
    {
	# if coordinates connected to segment, then return very large distance between points
	return (0, 0, 1e24);
    }

    my ($m, $b) = get_line(@seg2);

    my $m_inv;
    # get inverse of slope
    if ($m eq 'x-in')
    {
	$m_inv = 0;
    }
    # if the slope close to zero
    elsif (abs($m) < 1e-15)
    {
	$m_inv = 1e18;
    }
    else
    {
	$m_inv = -1/$m;
    }

    my $b_inv;
    my $x2;
    my $y2;

    # if the line perpendicular to seg2 is vertical
    # x coordinate of perpen line is coordinate of point
    # y coordinate is y value along seg2 
    if ($m_inv == 1e18)
    {
	$x2 = $x1; 
	$y2 = $b;
    }
    # if perpendicular line is horizontal
    # y value = y value of pt given
    # x value = x value along seg2
    elsif (abs($m_inv) < 1e-15)
    {
	$y2 = $y1;
	$x2 = $b;
    }
    else
    {
	$b_inv = $y1 - ($m_inv*$x1);

	$x2 = ($b - $b_inv)/($m_inv - $m);
	$y2 = $m_inv*$x2 + $b_inv; 
    }

    
    # if the x and y coordinate are greater than max value
    # or smaller than min value
    # then set x2, y2 to closest end point
    if ($x2 > max_list($xb, $xe) || $x2 < min_list($xb, $xe) || 
	$y2 > max_list($yb, $ye) || $y2 < min_list($yb, $ye))
    {
	#print "x and y coordinate outside  max or min-------- \n";
	
	my $db =  sqrt(($xb-$x2)**2 + ($yb-$y2)**2);
	my $de =  sqrt(($xe-$x2)**2 + ($ye-$y2)**2);
	# if the closest point to seg1 is closest to 
	# beginning of segment2
	if ($db < $de)
	{
	    $x2 = $xb;
	    $y2 = $yb;
	}
	else
	{
	    $x2 = $xe;
	    $y2 = $ye;
	}
    }

    my $dist_x1_x2 = sqrt(($x1-$x2)**2 + ($y1-$y2)**2);
    return (sprintf("%.12f", $x2), sprintf("%.12f", $y2), $dist_x1_x2);
}

# input: two segments formatted: xbeg, ybeg, xend, yend
# output: true if the segments are connected 
#         beg to end, or end to beg, end to end or beg to beg
sub connected_one
{
    my ($x, $y, $xb, $yb, $xe, $ye) = @_;

    if (((abs($x-$xb)<1e-6 && abs($y-$yb)<1e-6)) || ((abs($x-$xe)<1e-6 && abs($y-$ye)<1e-6)))
    {
	return 1;
    }
   

    return 0; 
}



# input: two segments formatted: xbeg, ybeg, xend, yend
# output: true if the segments are connected 
#         beg to end, or end to beg, end to end or beg to beg
sub connected
{
    my ($seg1_s, $seg2_s, $end_grow) = @_;

    # convert string to arrays
    my @seg1 = split(/\s+/, $seg1_s);
    my @seg2 = split(/\s+/, $seg2_s);

    my $beg1 = join( "/", @seg1[0..1]); 
    my $end1 = join( "/", @seg1[2..3]); 
    my $beg2 = join( "/", @seg2[0..1]); 
    my $end2 = join( "/", @seg2[2..3]); 

    #if ($beg1 eq $beg2 || $end1 eq $end2 || $end1 eq $beg2 || $beg1 eq $end2)
    #{
#	return 1;
#    }
    
 #    # if growing from end 1, only check if beg of 1st fault equals the other nodes
 #    if ($end_grow == 1 && ($beg1 eq $beg2 || $beg1 eq $end2)) 
 #    {
 #    	print "growing from end1, and beg of growing equals beg or end of static fault\n";
	# return 1;
 #    }
 #    # if growing from 2, only check if end of 1st fault equals the other nodes
 #    	print "growing from end1, and beg of growing equals beg or end of static fault\n";
 #    elsif ($end_grow == 2 && ($end1 eq $beg2 || $end1 eq $beg2))
 #    {
	# return 1;
 #    }
    # if considering same fault, check both end
    if ($beg1 eq $beg2 || $end1 eq $end2 || $end1 eq $beg2 || $beg1 eq $end2)
    {
	return 1;
    }

    return 0; 
}


# input: input filename
# output: list of boundary data, hash table of fault table
#    list 1: xbeg ybeg xend yend of each boundary ,
#    list 2: xbeg ybeg xend yend of each fault,
sub get_end_points
{
    my ($input_filename) = @_;

     # open file, or send error message 
    open FILE_HANDLER, $input_filename or die $!;

    # booleans to indicate if we have found the start of the
    # information related to the boundaries and the elements
    my $found_Bounds = 0;

    my @bounds;
    my %faults; 
    # remember if we have read in a line of data for this fault
    my $name = "<null>";
    my $found_data = 0; 

    while (<FILE_HANDLER>)
    {
	my $this_Line = $_;
	my @input = split (/\s+/, $this_Line);

	# find the start of the boundary lines
	if ( $this_Line =~ /^\*Boundary\s+Lines/ )
	{
	    $found_Bounds = 1;
	}
	
	# add the data to the bound variable
	# if the start of this line is a digit and we have found the founds
	elsif ( ($this_Line =~ /^\d/ ) && scalar(@input) < 11 && $found_Bounds)
	{
	    @input = split (/\s+/, $this_Line);
	    my $formatted_Input = join (" ", @input[1,2,3,4], $input[0]);

	    push (@bounds, $formatted_Input); 
	}

	# if the line starts with the word "fault", 
	# get the name of the fault we are currently reading in
	elsif ( $this_Line =~ /^fault\s/ ) 
	{     
	    my @data =  split(/\s+/, $this_Line);
	    # get the name of the fault we are finding the end points of
	    $name = $data[1]; 

	    $found_data = 0; 
	    $found_Bounds = 0;

	}

	elsif ( $this_Line =~ /^\n/ && $name ne "<null>" ) 
	{     
	    $name = "<null>";
	    $found_data = 0;
	}

	# add the data to the element variable
	# if the start of this line is a digit and we have found a fault
	# and the line does not contain "Crack", 
	#     and contains more than 10 elements (cannot be 11 or sandbox won't work)
	elsif ( ($this_Line =~ /^\d/ ) && $name ne "<null>" && 
		!($this_Line =~ /Crack/) && (scalar(@input) > 10 )) ####
	{
	    my $formatted_Input = join (" ", @input[1,2,3,4], $input[0]); 

	    # get the current amount of input 
	    my $last_input = $faults{$name};

	    if ($found_data)
	    {
		$formatted_Input = $last_input."\n".$formatted_Input;
	    }

	    $faults{$name} = $formatted_Input;
	    $found_data = 1;

	}
    }

    close FILE_HANDLER;

    return (\@bounds, \%faults); 

}

# called: my ($m1, $b1) = get_line(@seg1);
# input: xbeg, ybeg, xend, yend
# output: slope and y-intersection of this line
sub get_line
{
    my ($x1, $y1, $x2, $y2) = @_;;

    if (abs($x1 - $x2) < 1e-10)
    {
	return ("x-in", $x1); 
    }

    my $m = ($y2 - $y1)/($x2 - $x1);
    my $b = $y2 - ($m*$x2); 

    # if m realllly small, set to zero
    if (abs($m) < 1e-10)
    {
	$m = 0; 
    }

    return ($m, $b); 
}


##########################################################
# GENERATE THE LIST OF ALL POSSIBLE COMBINATION OF ANGLES
# TO TEST FOR EACH FAULT EVERY TIME AN ELEMENT IS ADDED
#    these functions operated with slower version of GROW
#    that tested all the linear combinations of geometries
##########################################################

sub get_next_list;
sub get_next_angle;
sub get_scenarios; 
sub is_equal; 

sub get_sequence;

# called: my $fault_ranges_ref = get_ranges($geo_hash_ref, $angle_range, $angle_inc);
# input: reference to hash table with most efficient geometry found in sequential growth fault1 => 90, fault2 => 135
#        range of angles to search away from efficient geometry
#        angle increment to search
# output: reference to hash table fault => list of angles to search 
sub get_ranges
{
    my ($hash_ref, $range, $inc) = @_;
    my %geo_eff = %$hash_ref; 
    my %fault_ranges;

    foreach my $fault (keys %geo_eff)
    {
	my $eff_angle = $geo_eff{$fault};
	my $curr = $eff_angle - $range; 
	while ($curr <= $eff_angle + $range)
	{
	    # if this angle is greater than 0, less than 360,
	    if ($curr > 0 && $curr < 360)
	    {
		push(@{$fault_ranges{$fault}}, $curr);
	    }

	    $curr = $curr + $inc;
	}

    }

    return \%fault_ranges;
}

# called:@next_list = get_next_list_sequential(\@next_list, \%fault_ranges, \@faults, -1);  
# this function builds from the end of the list up, 
#        so start at the end of list of faults initially, and increment 
# input: current list of angles paired to faults element 1 goes to fault 1, 
#        fault that we are currently looking for the angle of
#        hash table of fault 1=> possible angles, fault 2 => possible angles
#        list of all fault names
#        index of current fault finding angle for
# output: next list of angles to assign to faults
sub get_next_list_sequential
{
    my ($curr_list_ref, $hash_ref, $fault_ref, $index) = @_;
    my @curr_list = @$curr_list_ref;
    my %fault_angles = %$hash_ref;
    my @faults = @$fault_ref;

    # if the list is empty
    if (scalar(@curr_list) == 0)
    {
	return ();
    }

    # get the next element based on the fault angle that we are searching for
    my $next_angle = get_next_angle($curr_list[-1], @{$fault_angles{$faults[$index]}});

    # if the list is one element long
    if (scalar(@curr_list) == 1)
    {
	# if the only element of the list
	# is the last angle, there is no next list
	if ($next_angle == 0)
	{
	    return ();
	}

	# if the element is not the last
	# of the list, return the next angle in the sequence
	return ($next_angle);

    }
  
    # if the list is longer than 1 element

    # get the list without the last element
    pop(@curr_list);

    # if the last element of the list is the 
    # last angle in the sequence
    if ($next_angle == 0)
    {

	# return the list that is the result of calling this function on
	# the list[0..-2], with the angles of the fault alphabetically before this fault
	# and the first element of the list of possible angles for the current fault
	return (get_next_list_sequential(\@curr_list, $hash_ref, $fault_ref, $index-1), @{$fault_angles{$faults[$index]}}[0]); 
    }

    # if the last element of list is not the last
    # element in the sequence,
    # return the first part of the list appended
    # to the next angle in the sequence
    return (@curr_list, $next_angle); 
}


# input: current list, list of angles
# output: the next list in the list of possible
#         combinations of this list
sub get_next_list
{
    my ($curr_list_ref, $angles_ref) = @_;
    my @curr_list = @$curr_list_ref;
    my @angles = @$angles_ref;

    # if the list is empty
    if (scalar(@curr_list) == 0)
    {
	return ();
    }

    # get the next element based on the list of
    # angle measures
    my $next_angle = get_next_angle($curr_list[-1], @angles);


    # if the list is one element long
    if (scalar(@curr_list) == 1)
    {
	# if the only element of the list
	# is the last angle, there is no next list
	if ($next_angle == 0)
	{
	    return ();
	}

	# if the element is not the last
	# of the list, return the next angle in the sequence

	return ($next_angle);

    }
  
    # if the list is longer than 1 element

    # get the list without the last element
    pop(@curr_list);

    # if the last element of the list is the 
    # last angle in the sequence
    if ($next_angle == 0)
    {

	# return the list that is the result of calling this function on
	# the list[0..-2], the same angles appended to the first angle
	return (get_next_list(\@curr_list, \@angles), $angles[0]); 
    }

    # if the last element of list is not the last
    # element in the sequence,
    # return the first part of the list appended
    # to the next angle in the sequence
    return (@curr_list, $next_angle); 

}

# input: the last element in the list we are finding the next list of,
#        the sequential list of angles
# output: the angle that follows this element in the sequence
sub get_next_angle
{
    my ($element, @angles) = @_;

    my $i = 0;
    while($i < (scalar(@angles) - 1))
    {
	my $angle = $angles[$i];
	# if this angle is the element we are considering
	# return the next angle
	if ($angle == $element)
	{
	    return $angles[$i + 1];
	}

	$i++;
    }

    return 0; 
}


# get hash of scenarios to test for each iteration of crack growth
#    # assumes that all the fault names are fully listed faults in fric2d input file
#    # Key: fault name, values: list of angles to check
# input: reference to list of fault names, reference to list of angles to search
# output: hash table: key, value pairs: faultname -> list of angles to search
# called:    my $sequence_ref = get_sequence(\@fault_names, \@angle_range);
sub get_sequence
{
    my ($fault_ref, $angle_ref) = @_;
    my @faults = @$fault_ref;
    my @angles = @$angle_ref;

    my %hash;
    foreach (@faults) 
    {
	@{$hash{$_}} = @angles;
    }

    return \%hash;
}  

sub remove_last;

# called: my $tested_scenarios_ref = get_tested_scenarios($angles_ref, $geo_hash_ref);
# input: references to list of angles that all cracks searched in the last sequential search
#        reference to hash table containing most efficient geometry found during the last iteration
# output: reference to hash table 1 => fault 1 => 45, fault 2 => 90, containing
#        all the previously tested scenarios
sub get_tested_scenarios
{
    my ($ref1, $ref2) = @_;
    my @angles = @$ref1;
    my %geo_hash = %$ref2;

    # get hash without last key=> value pair, and key
    my ($fault, $removed_ref) = remove_last($ref2);
    my %removed = %$removed_ref;

    my %tested;
    my $index = 1;
    # for all of the angles, add the angle at the fault key in a scenario
    foreach my $angle (@angles)
    {
	# add all the keys of the removed hash table
	foreach my $f (sort keys %removed)
	{
	    $tested{$index}{$f} = $removed{$f}; 
	}

	# add the additional angle at the ending fault
	$tested{$index}{$fault} = $angle;
	$index = $index + 1;
    }

    return \%tested;

}

# called:     my ($fault, $removed_ref) = remove_last($ref2);
# input: reference to hash table
# output: name of last key
#         reference to hash table with last
#         alphanumeric key removed
sub remove_last
{
    my ($ref) = @_;
    my %hash = %$ref;

    # sort the faults in opposite order
    # delete the fault, return the updated hash and name of fault
    foreach my $fault (sort {$b cmp $a} keys %hash)
    {
	delete $hash{$fault};
	return ($fault, \%hash);
    }
    
}

# make all possible scenarios for these combinations: will require specific range for each fault
# called: my ($scenarios_ref, $scen_num) = get_scenarios_sequential($fault_ranges_ref);
# input: reference to hash table fault end => range of angles to search
# output: reference to scenario hash 1 => (fault1 => 90, faults2 => 135)
sub get_scenarios_sequential
{
    my ($ref) = @_;
    my %fault_ranges = %$ref;
    my %scenarios; 

    my $scen_index = 0;

    # get list of faults alphabetically
    my @faults;
    foreach (sort keys %fault_ranges)
    {
	push(@faults, $_); 
    }

     # make starting list that is the same length
    # as the list of angles, where each element is the 
    # first element of each list of angles
    my @start_list = ();
    foreach (sort keys %fault_ranges)
    {
	push(@start_list, @{$fault_ranges{$_}}[0]);
    }

    # make ending list
    # same length of angles list, each element is last element 
    # of angles array
    my @end_list = ();
    foreach (sort keys %fault_ranges)
    {
	push(@end_list, @{$fault_ranges{$_}}[-1]);
    }

    $scen_index = $scen_index + 1; 

    # add the starting list to the hash table
    my $index = 1; 
    my $i = 0;
    foreach (sort keys %fault_ranges)
    {
	$scenarios{$index}{$_} = $start_list[$i]; 
	$i++;
    }
    $index++;

    # while the next list is not the ending list
    my $continue = 1;
    my @next_list = @start_list; 
    
    while ($continue)
    {
	@next_list = get_next_list_sequential(\@next_list, \%fault_ranges, \@faults, -1);  

	# add to the hash
	$i = 0;
	foreach (sort keys %fault_ranges)
	{
	    $scenarios{$index}{$_} = $next_list[$i]; 
	    $i++;
	}

	$continue = !(is_equal(\@next_list, \@end_list));
	$index++; 
	$scen_index++;
    }

    return (\%scenarios, $scen_index);
}

# input: list of faults, list of range of angles
# output: hash of hash tables
#        each hash table contains a scenario faultname1 => angle1
#        number of scenarios in hash table 
sub get_scenarios
{
    my ($fault_ref, $angle_ref) = @_;
    my @faults = @$fault_ref;
    my @angles = @$angle_ref;

    # if no more faults are growing
    if (scalar(@faults) == 0)
    {
	# signal that the number of scenarios to test is 0
	return (" ", 0); 
    }

    # get all combinations of this list of angles
    my %scenarios; 
    # remember the number of scenarios that we make
    my $scenario_index = 0;

    # make starting list that is the same length
    # as the list of angles, where each element is the 
    # first element of the list of angles
    my @start_list = ();
    my $i = 0;
    while ($i < scalar(@faults))
    {
	push(@start_list, $angles[0]);
	$i++;
    }

    # make ending list
    # same length of angles list, each element is last element 
    # of angles array
    my @end_list = ();
    $i = 0;
    while ($i < scalar(@faults))
    {
	push(@end_list, $angles[-1]);
	$i++;
    }

    $scenario_index = $scenario_index + 2; 

    # add the starting list to the hash table
    my $index = 1; 
    $i = 0;
    foreach(@faults)
    {
	$scenarios{$index}{$_} = $start_list[$i]; 
	$i++;
    }
    $index++;

    # while the next list is not the ending list
    my $continue = 1;
    my @next_list = @start_list; 
    
    while ($continue)
    {
	@next_list = get_next_list(\@next_list, \@angles);  

	# add to the hash
	$i = 0;
	foreach(@faults)
	{
	    $scenarios{$index}{$_} = $next_list[$i]; 
	    $i++;
	}

	$continue = !(is_equal(\@next_list, \@end_list));
	$index++; 
	$scenario_index++;
    }

    return (\%scenarios, $scenario_index);

}

# input: list of angles, list of fault names
# output: hash table formatted faultname => angle
sub make_scenario_hash
{
    my ($angle_ref, $name_ref) = @_;

    my @angles = @$angle_ref;
    my @names = @$name_ref;

    my %hash;
    my $i = 0;
    foreach(@names)
    {
	my $this_name = $_;
	$hash{$this_name} = $angles[$i];

	$i++;
    }

    return %hash; 
}

#########################################################
#MISCELLANEOUS FUNCTIONS
########################################################


# input: 2 lists,
# output: true if lists are equal, false otherwise
sub is_equal
{
    my ($list1_ref, $list2_ref) = @_;

    my @list1 = @$list1_ref;
    my @list2 = @$list2_ref;

    if (scalar(@list1) != scalar(@list2))
    {
	return 0;
    }

    my $i = 0;
    foreach(@list1)
    {
	if ($_ != $list2[$i])
	{
	    return 0;
	}
	
	$i++;
    }
    
    return 1;

}

# input: decimal
# output: integer, rounded accordingly
sub round
{
    my ($dec) = @_;

    my @ints = split(/\./, $dec);
    # if this is an integer
    if (scalar(@ints) == 1)
    {
	return $ints[0]; 
    }

    my @dec = split(//, $ints[1]);
 
    # if the tens place is a five, return the number + 1
    if ($dec[0] >= 5)
    {
	return $ints[0] + 1;
    }
    return $ints[0];
}

# called:  my @angle_range = get_angles($start_angle, $end_angle, $inc_angle);
# input: starting angle, ending angle, increment angle
# output: list of angles to search
sub get_angles
{
    my ($start, $end, $inc) = @_;

    my @range;

    while ($start < $end)
    {
	push(@range, $start); 
	$start = $start + $inc;
    }
    
    return @range;
}

# called:     my ($prev_filename, $efficient_filename, $testing_filename,
#	$fric_output_filename, $output_filename, $out_raw_filename, $restart_filename) = 
#	    make_names($root);
# input: input filename
# output: list of filenames used later in the program
sub make_names
{
    my $root = join("", @_);  
    my $restart_filename = $root;
    my $continue_num = 0; 

     # continuation number could be more than 1 digit
    if ($root =~ /_cont\d+$/)
    {
	# get and increment continuation number based on filename
	my @name = split(/_cont/, $root);
	$continue_num = $name[1];
	# if the filename contatins _cont, then remove it
	$restart_filename =~ s/_cont\d+//g ; 
    }
    # if program has not automatically restarted itself yet
    # the filename should not contain "_cont\d"
    # continuation number, and continuation number = 1
    $continue_num = $continue_num+1;
    $restart_filename = $restart_filename."_cont$continue_num.in";

    return ($root.".prev", $root.".eff", $root.".test",
	    $root.".out", $root.".work", $root.".raw", $restart_filename); 

}

# copy the contents of one file to another file
# input: name of the original input file,
#        name of the file to be copied
# output: name of the previous (last) most efficient geometry found
sub transfer_file 
{
    my $old_name = $_[0];
    my $new_name = $_[1];

	# find operating system
	my $op_system = $^O; 
	
	# for windows
	if ($op_system =~ /Win/)
	{
		system("copy", $old_name, $new_name);
	}
	else 
	{
		# works for linux operating systems
		system("cp", $old_name, $new_name);
	}
		
    if ($? == -1)
    {
	die $!;
    }
}

# return max value in list
sub max_list
{
    my @vals = @_;

    my $max = $vals[0];
    foreach(@vals)
    {
	my $val = $_;
	if ($val > $max)
	{
	    $max = $val;
	}

    }

    return $max;
}

# return min value in list
sub min_list
{
    my @vals = @_;

    my $min = $vals[0];
    foreach(@vals)
    {
	my $val = $_;
	if ($val < $min)
	{
	    $min = $val;
	}

    }

    return $min;
}

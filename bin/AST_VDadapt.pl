#!/usr/bin/perl
#
# AST_VDadapt.pl version 2.12
#
# DESCRIPTION:
# adjusts the auto_dial_level for vicidial adaptive-predictive campaigns. 
# gather call stats for campaigns and in-groups
#
# Copyright (C) 2016  Matt Florell <vicidial@gmail.com>    LICENSE: AGPLv2
#
# CHANGELOG
# 60823-1302 - First build from AST_VDhopper.pl
# 60825-1734 - Functional alpha version, no loop
# 60826-0857 - Added loop and CLI flag options
# 60827-0035 - Separate Drop calculation and target dial level calculation into different subroutines
#            - Alter code so that DROP percentages would calculate only about once a minute no matter he loop delay
# 60828-1149 - Add field for target dial_level difference, -1 would target one agent waiting, +1 would target 1 customer waiting
# 60919-1243 - Changed variables to use arrays for all campaign-specific values
# 61215-1110 - Added answered calls stats and use drops as percentage of answered for today
# 70111-1600 - Added ability to use BLEND/INBND/*_C/*_B/*_I as closer campaigns
# 70205-1429 - Added code for campaign_changedate and campaign_stats_refresh updates
# 70213-1221 - Added code for QueueMetrics queue_log QUEUESTART record
# 70219-1249 - Removed unused references to dial_status_x fields
# 70409-1219 - Removed CLOSER-type campaign restriction
# 70521-1038 - Fixed bug when no live campaigns are running, define $vicidial_log
# 70619-1339 - Added Status Category tally calculations
# 71029-1906 - Changed CLOSER-type campaign_id restriction
# 81021-2201 - Deactivated queue_log QUEUESTART event
# 81022-0713 - Added gathering of vicidial_inbound_groups stats(day only)
# 81108-0808 - Added more inbound stats with some debug output and added campaign agent non-pause time
# 90415-0925 - Fixed rare division by zero bug
# 90512-1549 - Formatting fixes and calculation bugs in blended
# 90628-2001 - Added drop rate group functions
# 91115-0929 - Added auto-kill of script at timeclock reset time of day to facilitate cleaner clearing of daily stats
# 91206-2203 - Added campaign_calldate within last 5 minute as an override to recalculate stats
# 100206-1453 - Fixed calculation of hold_sec stats (service level) for in-groups
# 110513-0721 - Added debug DB table, dial level and available only tally threshold options
# 111103-0626 - Added MAXCAL as a drop status
# 111219-1420 - Added daily stats updates to new table for total, in-group and campaign
# 111223-0924 - Added check for logged-in agents
# 131122-1314 - Added several missing sthA->finish
# 141109-1957 - Fixed issue #793
# 141113-1616 - Added concurrency check
# 151124-1235 - Added function to cache carrier log stats
# 160515-2016 - Added code for new UK OFCOM drop calculations
# 161102-1029 - Fixed QM partition problem
#

# constants
$DB=0;  # Debug flag, set to 0 for no debug messages, On an active system this will generate lots of lines of output per minute
$US='__';
$MT[0]='';
$run_check=1; # concurrency check

##### table definitions(used to force index usage for better performance):
	$vicidial_log = 'vicidial_log FORCE INDEX (call_date) ';
#	$vicidial_log = 'vicidial_log';
	$vicidial_closer_log = 'vicidial_closer_log FORCE INDEX (call_date) ';
#	$vicidial_closer_log = 'vicidial_closer_log';

$generate_carrier_stats=1;
$SSofcom_uk_drop_calc=0;

$i=0;
$daily_stats=1;
$drop_count_updater=0;
$stat_it=15;
$diff_ratio_updater=0;
$stat_count=1;
$ofcom_uk_drop_calc_ANY=0;
$VCScalls_today[$i]=0;
$VCSdrops_today[$i]=0;
$VCSdrops_today_pct[$i]=0;
$VCScalls_hour[$i]=0;
$VCSdrops_hour[$i]=0;
$VCSdrops_hour_pct[$i]=0;
$VCScalls_halfhour[$i]=0;
$VCSdrops_halfhour[$i]=0;
$VCSdrops_halfhour_pct[$i]=0;
$VCScalls_five[$i]=0;
$VCSdrops_five[$i]=0;
$VCSdrops_five_pct[$i]=0;
$VCScalls_one[$i]=0;
$VCSdrops_one[$i]=0;
$VCSdrops_one_pct[$i]=0;
$total_agents[$i]=0;
$ready_agents[$i]=0;
$waiting_calls[$i]=0;
$ready_diff_total[$i]=0;
$waiting_diff_total[$i]=0;
$total_agents_total[$i]=0;
$ready_diff_avg[$i]=0;
$waiting_diff_avg[$i]=0;
$total_agents_avg[$i]=0;
$stat_differential[$i]=0;
$VCSINCALL[$i]=0;
$VCSREADY[$i]=0;
$VCSCLOSER[$i]=0;
$VCSPAUSED[$i]=0;
$VCSagents[$i]=0;
$VCSagents_calc[$i]=0;
$VCSagents_active[$i]=0;

# set to 61 initially so that a baseline drop count is pulled
$drop_count_updater=61;

$secT = time();

### begin parsing run-time options ###
if (length($ARGV[0])>1)
	{
	$i=0;
	while ($#ARGV >= $i)
		{
		$args = "$args $ARGV[$i]";
		$i++;
		}

	if ($args =~ /--help/i)
		{
		print "allowed run time options(must stay in this order):\n";
		print "  [--loops=XXX] = force a number of loops of XXX\n";
		print "  [--delay=XXX] = force a loop delay of XXX seconds\n";
		print "  [--campaign=XXX] = run for campaign XXX only\n";
		print "  [--no-daily-stats] = will not calculate daily stats for total, ingroup, campaign\n";
		print "  [--force] = force calculation of suggested predictive dial_level\n";
		print "  [--test] = test only, do not alter dial_level\n";
		print "  [--debug] = debug\n";
		print "  [--debugX] = super debug\n";
		print "  [--debugXXX] = extra super debug\n";
		print "\n";
		exit;
		}
	else
		{
		if ($args =~ /--campaign=/i) # CLI defined campaign
			{
			@CLIvarARY = split(/--campaign=/,$args);
			@CLIvarARX = split(/ /,$CLIvarARY[1]);
			if (length($CLIvarARX[0])>2)
				{
				$CLIcampaign = $CLIvarARX[0];
				$CLIcampaign =~ s/\/$| |\r|\n|\t//gi;
				}
			else
				{$CLIcampaign = '';}
			@CLIvarARY=@MT;   @CLIvarARY=@MT;
			}
		else
			{$CLIcampaign = '';}
		if ($args =~ /--level=/i) # CLI defined level
			{
			@CLIvarARY = split(/--level=/,$args);
			@CLIvarARX = split(/ /,$CLIvarARY[1]);
			if (length($CLIvarARX[0])>2)
				{
				$CLIlevel = $CLIvarARX[0];
				$CLIlevel =~ s/\/$| |\r|\n|\t//gi;
				$CLIlevel =~ s/\D//gi;
				}
			else
				{$CLIlevel = '';}
			@CLIvarARY=@MT;   @CLIvarARY=@MT;
			}
		else
			{$CLIlevel = '';}
		if ($args =~ /--loops=/i) # CLI defined loops
			{
			@CLIvarARY = split(/--loops=/,$args);
			@CLIvarARX = split(/ /,$CLIvarARY[1]);
			if (length($CLIvarARX[0])>2)
				{
				$CLIloops = $CLIvarARX[0];
				$CLIloops =~ s/\/$| |\r|\n|\t//gi;
				$CLIloops =~ s/\D//gi;
				}
			else
				{$CLIloops = '1000000';}
			@CLIvarARY=@MT;   @CLIvarARY=@MT;
			}
		else
			{$CLIloops = '1000000';}
		if ($args =~ /--delay=/i) # CLI defined delay
			{
			@CLIvarARY = split(/--delay=/,$args);
			@CLIvarARX = split(/ /,$CLIvarARY[1]);
			if (length($CLIvarARX[0])>2)
				{
				$CLIdelay = $CLIvarARX[0];
				$CLIdelay =~ s/\/$| |\r|\n|\t//gi;
				$CLIdelay =~ s/\D//gi;
				}
			else
				{$CLIdelay = '1';}
			@CLIvarARY=@MT;   @CLIvarARY=@MT;
			}
		else
			{$CLIdelay = '1';}
		if ($args =~ /--debug/i)
			{
			$DB=1;
			print "\n----- DEBUG -----\n\n";
			}
		if ($args =~ /--debugX/i)
			{
			$DBX=1;
			print "\n";
			print "----- SUPER DEBUG -----\n";
			print "VARS-\n";
			print "CLIcampaign- $CLIcampaign\n";
			print "CLIlevel-    $CLIlevel\n";
			print "CLIloops-    $CLIloops\n";
			print "CLIdelay-    $CLIdelay\n";
			print "\n";
			}
		if ($args =~ /--debugXXX/i)
			{
			$DBXXX=1;
			print "\n----- EXTRA SUPER DEBUG -----\n\n";
			}
		if ($args =~ /--force/i)
			{
			$force_test=1;
			print "\n----- FORCE TESTING -----\n\n";
			}
		if ($args =~ /--test/i)
			{
			$T=1;   $TEST=1;
			print "\n----- TESTING -----\n\n";
			}
		if ($args =~ /--no-daily-stats/i)
			{
			$daily_stats=0;
			print "\n----- NO DAILY STATS -----\n\n";
			}
		}
	}
else
	{
	$CLIcampaign = '';
	$CLIlevel = '';
	$CLIloops = '1000000';
	$CLIdelay = '1';
	}

# default path to astguiclient configuration file:
$PATHconf =		'/etc/astguiclient.conf';

open(conf, "$PATHconf") || die "can't open $PATHconf: $!\n";
@conf = <conf>;
close(conf);
$i=0;
foreach(@conf)
	{
	$line = $conf[$i];
	$line =~ s/ |>|\n|\r|\t|\#.*|;.*//gi;
	if ( ($line =~ /^PATHhome/) && ($CLIhome < 1) )
		{$PATHhome = $line;   $PATHhome =~ s/.*=//gi;}
	if ( ($line =~ /^PATHlogs/) && ($CLIlogs < 1) )
		{$PATHlogs = $line;   $PATHlogs =~ s/.*=//gi;}
	if ( ($line =~ /^PATHagi/) && ($CLIagi < 1) )
		{$PATHagi = $line;   $PATHagi =~ s/.*=//gi;}
	if ( ($line =~ /^PATHweb/) && ($CLIweb < 1) )
		{$PATHweb = $line;   $PATHweb =~ s/.*=//gi;}
	if ( ($line =~ /^PATHsounds/) && ($CLIsounds < 1) )
		{$PATHsounds = $line;   $PATHsounds =~ s/.*=//gi;}
	if ( ($line =~ /^PATHmonitor/) && ($CLImonitor < 1) )
		{$PATHmonitor = $line;   $PATHmonitor =~ s/.*=//gi;}
	if ( ($line =~ /^VARserver_ip/) && ($CLIserver_ip < 1) )
		{$VARserver_ip = $line;   $VARserver_ip =~ s/.*=//gi;}
	if ( ($line =~ /^VARDB_server/) && ($CLIDB_server < 1) )
		{$VARDB_server = $line;   $VARDB_server =~ s/.*=//gi;}
	if ( ($line =~ /^VARDB_database/) && ($CLIDB_database < 1) )
		{$VARDB_database = $line;   $VARDB_database =~ s/.*=//gi;}
	if ( ($line =~ /^VARDB_user/) && ($CLIDB_user < 1) )
		{$VARDB_user = $line;   $VARDB_user =~ s/.*=//gi;}
	if ( ($line =~ /^VARDB_pass/) && ($CLIDB_pass < 1) )
		{$VARDB_pass = $line;   $VARDB_pass =~ s/.*=//gi;}
	if ( ($line =~ /^VARDB_port/) && ($CLIDB_port < 1) )
		{$VARDB_port = $line;   $VARDB_port =~ s/.*=//gi;}
	$i++;
	}

if (!$VARDB_port) {$VARDB_port='3306';}

use Time::HiRes ('gettimeofday','usleep','sleep');  # necessary to have perl sleep command of less than one second
use DBI;	  

$dbhA = DBI->connect("DBI:mysql:$VARDB_database:$VARDB_server:$VARDB_port", "$VARDB_user", "$VARDB_pass")
 or die "Couldn't connect to database: " . DBI->errstr;

if ($DBX) {print "CONNECTED TO DATABASE:  $VARDB_server|$VARDB_database\n";}

# make sure the vicidial_campaign_stats table has all of the campaigns.  
# They should exist, but sometimes they get accidently removed during db moves and the like.
$stmtA = "INSERT IGNORE into vicidial_campaign_stats (campaign_id) select campaign_id from vicidial_campaigns;";
$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
$sthA->finish();

$stmtA = "INSERT IGNORE into vicidial_campaign_stats_debug (campaign_id,server_ip) select campaign_id,'ADAPT' from vicidial_campaigns;";
$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
$sthA->finish();

##### gather relevent system settings
$stmtA = "SELECT cache_carrier_stats_realtime,ofcom_uk_drop_calc from system_settings;";
$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
$sthArows=$sthA->rows;
if ($sthArows > 0)
	{
	@aryA = $sthA->fetchrow_array;
	$generate_carrier_stats =	$aryA[0];
	$SSofcom_uk_drop_calc =		$aryA[1];
	}
$sthA->finish();


&get_time_now;

#############################################
##### START QUEUEMETRICS LOGGING LOOKUP #####
# Disabled per Lorenzo at QueueMetrics because this Asterisk event is apparently useless
#$stmtA = "SELECT enable_queuemetrics_logging,queuemetrics_server_ip,queuemetrics_dbname,queuemetrics_login,queuemetrics_pass,queuemetrics_log_id FROM system_settings;";
#$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
#$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
#$sthArows=$sthA->rows;
#$rec_count=0;
#while ($sthArows > $rec_count)
#	{
#	 @aryA = $sthA->fetchrow_array;
#		$enable_queuemetrics_logging =	"$aryA[0]";
#		$queuemetrics_server_ip	=		"$aryA[1]";
#		$queuemetrics_dbname	=		"$aryA[2]";
#		$queuemetrics_login	=			"$aryA[3]";
#		$queuemetrics_pass	=			"$aryA[4]";
#		$queuemetrics_log_id =			"$aryA[5]";
#	 $rec_count++;
#	}
#$sthA->finish();
#
#if ($enable_queuemetrics_logging > 0)
#	{
#	$dbhB = DBI->connect("DBI:mysql:$queuemetrics_dbname:$queuemetrics_server_ip:3306", "$queuemetrics_login", "$queuemetrics_pass")
#	 or die "Couldn't connect to database: " . DBI->errstr;
#
#	if ($DBX) {print "CONNECTED TO DATABASE:  $queuemetrics_server_ip|$queuemetrics_dbname\n";}
#
#	$stmtB = "INSERT INTO queue_log SET `partition`='P01',time_id='$secT',call_id='NONE',queue='NONE',agent='NONE',verb='QUEUESTART',serverid='$queuemetrics_log_id';";
#	$Baffected_rows = $dbhB->do($stmtB);
#
#	$dbhB->disconnect();
#	}
##### END QUEUEMETRICS LOGGING LOOKUP #####
###########################################

### concurrency check (SCREEN uses script path, so check for more than 2 entries)
if ($run_check > 0)
	{
	my $grepout = `/bin/ps ax | grep $0 | grep -v grep | grep -v '/bin/sh'`;
	my $grepnum=0;
	$grepnum++ while ($grepout =~ m/\n/g);
	if ($grepnum > 2) 
		{
		if ($DB) {print "I am not alone! Another $0 is running! Exiting...\n";}
		$event_string = "I am not alone! Another $0 is running! Exiting...";
		&event_logger;
		exit;
		}
	}

$master_loop=0;

### Start master loop ###
while ($master_loop < $CLIloops) 
	{
	&get_time_now;

	### Grab Server values from the database
	$stmtA = "SELECT vd_server_logs,local_gmt FROM servers where server_ip='$VARserver_ip';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$DBvd_server_logs =		$aryA[0];
		$DBSERVER_GMT =			$aryA[1];
		if ($DBvd_server_logs =~ /Y/)	{$SYSLOG = '1';}
		else {$SYSLOG = '0';}
		if (length($DBSERVER_GMT)>0)	{$SERVER_GMT = $DBSERVER_GMT;}
		$rec_count++;
		}
	$sthA->finish();

	$secX = time();
	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($secX);
	$LOCAL_GMT_OFF = $SERVER_GMT;
	$LOCAL_GMT_OFF_STD = $SERVER_GMT;
	if ($isdst) {$LOCAL_GMT_OFF++;} 

	$GMT_now = ($secX - ($LOCAL_GMT_OFF * 3600));
	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($GMT_now);
	$mon++;
	$year = ($year + 1900);
	if ($mon < 10) {$mon = "0$mon";}
	if ($mday < 10) {$mday = "0$mday";}
	if ($hour < 10) {$hour = "0$hour";}
	if ($min < 10) {$min = "0$min";}
	if ($sec < 10) {$sec = "0$sec";}

	if ($DBXXX) {print "TIME DEBUG: $master_loop   $LOCAL_GMT_OFF_STD|$LOCAL_GMT_OFF|$isdst|   GMT: $hour:$min\n";}

	@campaign_id=@MT; 
	@lead_order=@MT;
	@hopper_level=@MT;
	@auto_dial_level=@MT;
	@local_call_time=@MT;
	@lead_filter_id=@MT;
	@use_internal_dnc=@MT;
	@dial_method=@MT;
	@available_only_ratio_tally=@MT;
	@adaptive_dropped_percentage=@MT;
	@adaptive_maximum_level=@MT;
	@adaptive_latest_server_time=@MT;
	@adaptive_intensity=@MT;
	@adaptive_dl_diff_target=@MT;
	@campaign_changedate=@MT;
	@campaign_stats_refresh=@MT;
	@campaign_allow_inbound=@MT;
	@drop_rate_group=@MT;
	@available_only_tally_threshold=@MT;
	@available_only_tally_threshold_agents=@MT;
	@dial_level_threshold=@MT;
	@dial_level_threshold_agents=@MT;

	if ($CLIcampaign)
		{
		$stmtA = "SELECT campaign_id,lead_order,hopper_level,auto_dial_level,local_call_time,lead_filter_id,use_internal_dnc,dial_method,available_only_ratio_tally,adaptive_dropped_percentage,adaptive_maximum_level,adaptive_latest_server_time,adaptive_intensity,adaptive_dl_diff_target,UNIX_TIMESTAMP(campaign_changedate),campaign_stats_refresh,campaign_allow_inbound,drop_rate_group,UNIX_TIMESTAMP(campaign_calldate),realtime_agent_time_stats,available_only_tally_threshold,available_only_tally_threshold_agents,dial_level_threshold,dial_level_threshold_agents,ofcom_uk_drop_calc from vicidial_campaigns where campaign_id='$CLIcampaign'";
		}
	else
		{
		$stmtA = "SELECT campaign_id,lead_order,hopper_level,auto_dial_level,local_call_time,lead_filter_id,use_internal_dnc,dial_method,available_only_ratio_tally,adaptive_dropped_percentage,adaptive_maximum_level,adaptive_latest_server_time,adaptive_intensity,adaptive_dl_diff_target,UNIX_TIMESTAMP(campaign_changedate),campaign_stats_refresh,campaign_allow_inbound,drop_rate_group,UNIX_TIMESTAMP(campaign_calldate),realtime_agent_time_stats,available_only_tally_threshold,available_only_tally_threshold_agents,dial_level_threshold,dial_level_threshold_agents,ofcom_uk_drop_calc from vicidial_campaigns where ( (active='Y') or (campaign_stats_refresh='Y') )";
		}
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$campaign_id[$rec_count] =					$aryA[0];
		$lead_order[$rec_count] =					$aryA[1];
		if (!$CLIlevel) 
			{$hopper_level[$rec_count] =			$aryA[2];}
		else
			{$hopper_level[$rec_count] =			$CLIlevel;}
		$auto_dial_level[$rec_count] =				$aryA[3];
		$local_call_time[$rec_count] =				$aryA[4];
		$lead_filter_id[$rec_count] =				$aryA[5];
		$use_internal_dnc[$rec_count] =				$aryA[6];
		$dial_method[$rec_count] =					$aryA[7];
		$available_only_ratio_tally[$rec_count] =	$aryA[8];
		$adaptive_dropped_percentage[$rec_count] =	$aryA[9];
		$adaptive_maximum_level[$rec_count] =		$aryA[10];
		$adaptive_latest_server_time[$rec_count] =	$aryA[11];
		$adaptive_intensity[$rec_count] =			$aryA[12];
		$adaptive_dl_diff_target[$rec_count] =		$aryA[13];
		$campaign_changedate[$rec_count] =			$aryA[14];
		$campaign_stats_refresh[$rec_count] =		$aryA[15];
		$campaign_allow_inbound[$rec_count] =		$aryA[16];
		$drop_rate_group[$rec_count] =				$aryA[17];
		$campaign_calldate_epoch[$rec_count] =		$aryA[18];
		$realtime_agent_time_stats[$rec_count] =	$aryA[19];
		$available_only_tally_threshold[$rec_count] =	$aryA[20];
		$available_only_tally_threshold_agents[$rec_count] =	$aryA[21];
		$dial_level_threshold[$rec_count] =			$aryA[22];
		$dial_level_threshold_agents[$rec_count] =	$aryA[23];
		$ofcom_uk_drop_calc[$rec_count] =			$aryA[24];

		$rec_count++;
		}
	$sthA->finish();
	if ($DB) {print "$now_date CAMPAIGNS TO PROCESSES ADAPT FOR:  $rec_count|$#campaign_id       IT: $master_loop\n";}

	$five_min_ago = time();
	$five_min_ago = ($five_min_ago - 300);

	##### LOOP THROUGH EACH CAMPAIGN AND PROCESS THE DATA #####
	$i=0;
	foreach(@campaign_id)
		{
		$debug_camp_output='';
		$hopper_ready_count=0;
		$agents_loggedin_count=0;
		### Find out how many leads are in the hopper from a specific campaign
		$stmtA = "SELECT count(*) from vicidial_hopper where campaign_id='$campaign_id[$i]' and status='READY';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$hopper_ready_count = $aryA[0];
			if ($DB) {print "     $campaign_id[$i] hopper READY count:   $hopper_ready_count";}
			$debug_camp_output .= "     $campaign_id[$i] hopper READY count:   $hopper_ready_count\n";
			if ($DBXXX) {print "     |$stmtA|\n";}
			}
		$sthA->finish();

		### Find out how many agents are logged in to a specific campaign
		$stmtA = "SELECT count(*) from vicidial_live_agents where campaign_id='$campaign_id[$i]' and last_update_time > '$VDL_one';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$agents_loggedin_count = $aryA[0];
			if ($DB) {print "     $campaign_id[$i] agents LOGGED-IN count:   $agents_loggedin_count";}
			$debug_camp_output .= "     $campaign_id[$i] agents LOGGED-IN count:   $agents_loggedin_count\n";
			if ($DBXXX) {print "     |$stmtA|\n";}
			}
		$sthA->finish();

		$event_string = "|$campaign_id[$i]|$hopper_level[$i]|$hopper_ready_count|$local_call_time[$i]|$diff_ratio_updater|$drop_count_updater|";
		if ($DBX) {print "$i     $event_string\n";}
		$debug_camp_output .= "$i     $event_string\n";
		&event_logger;	

		if ($DBX) {print "     TIME CALL CHECK: $five_min_ago/$campaign_calldate_epoch[$i]\n";}
		$debug_camp_output .= "     TIME CALL CHECK: $five_min_ago/$campaign_calldate_epoch[$i]\n";

		##### IF THERE ARE NO LEADS IN THE HOPPER OR AGENTS LOGGED-IN FOR THE CAMPAIGN WE DO NOT WANT TO ADJUST THE DIAL_LEVEL
		if ( ($hopper_ready_count > 0) || ($agents_loggedin_count > 0) )
			{
			### BEGIN - GATHER STATS FOR THE vicidial_campaign_stats TABLE ###
			$differential_onemin[$i]=0;
			$agents_average_onemin[$i]=0;

			&count_agents_lines;

			if ($total_agents_avg[$i] > 0)
				{
				### Update Drop counter every 60 seconds
				if ($drop_count_updater >= 60)
					{
					&calculate_drops;
					}

				### Calculate and update Dial level every 15 seconds
				if ($diff_ratio_updater >= 15)
					{
					&calculate_dial_level;
					}
				}
			else
				{
				if ( ($campaign_stats_refresh[$i] =~ /Y/) || ($five_min_ago < $campaign_calldate_epoch[$i]) )
					{
					if ($drop_count_updater >= 60)
						{
						if ($DB) {print "     REFRESH OVERRIDE: $campaign_id[$i]\n";}
						$debug_camp_output .= "     REFRESH OVERRIDE: $campaign_id[$i]\n";

						&calculate_drops;

						$RESETdrop_count_updater++;

						$stmtA = "UPDATE vicidial_campaigns SET campaign_stats_refresh='N' where campaign_id='$campaign_id[$i]';";
						$affected_rows = $dbhA->do($stmtA);
						}
					}
				else
					{
					if ($campaign_changedate[$i] >= $VDL_ninty)
						{
						if ($drop_count_updater >= 60)
							{
							if ($DB) {print "     CHANGEDATE OVERRIDE: $campaign_id[$i]\n";}
							$debug_camp_output .= "     CHANGEDATE OVERRIDE: $campaign_id[$i]\n";

							&calculate_drops;

							$RESETdrop_count_updater++;
							}
						}
					}
				}
			}
		else
			{
			if ( ($campaign_stats_refresh[$i] =~ /Y/) || ($five_min_ago < $campaign_calldate_epoch[$i]) )
				{
				if ($drop_count_updater >= 60)
					{
					if ($DB) {print "     REFRESH OVERRIDE: $campaign_id[$i]\n";}
					$debug_camp_output .= "     REFRESH OVERRIDE: $campaign_id[$i]\n";

					&calculate_drops;

					$RESETdrop_count_updater++;

					$stmtA = "UPDATE vicidial_campaigns SET campaign_stats_refresh='N' where campaign_id='$campaign_id[$i]';";
					$affected_rows = $dbhA->do($stmtA);
					}
				}
			else
				{
				if ($campaign_changedate[$i] >= $VDL_ninty)
					{
					if ($drop_count_updater >= 60)
						{
						if ($DB) {print "     CHANGEDATE OVERRIDE: $campaign_id[$i]\n";}
						$debug_camp_output .= "     CHANGEDATE OVERRIDE: $campaign_id[$i]\n";

						&calculate_drops;

						$RESETdrop_count_updater++;
						}
					}
				}
			}
		$i++;
		}

	if ($stat_count =~ /1$/)
		{
		&drop_rate_group_gather;
		}

	if ( ($stat_count =~ /00$|50$/) || ($stat_count==1) )
		{
		&launch_inbound_gather;
		}

	if ( ($daily_stats > 0) && (($stat_count =~ /0$|5$/) || ($stat_count==1)) )
		{
		&launch_max_calls_gather;
		}

	if ( (($stat_count =~ /00$|50$/) || ($stat_count==1)) )
		{
		$stmtA = "SELECT cache_carrier_stats_realtime,ofcom_uk_drop_calc from system_settings;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$generate_carrier_stats =	$aryA[0];
			$SSofcom_uk_drop_calc =		$aryA[1];
			}
		$sthA->finish();
		if ($generate_carrier_stats > 0)
			{
			&launch_carrier_stats_gather;
			}
		}

	if ($RESETdiff_ratio_updater > 0) {$RESETdiff_ratio_updater=0;   $diff_ratio_updater=0;}
	if ($RESETdrop_count_updater > 0) {$RESETdrop_count_updater=0;   $drop_count_updater=0;}
	$diff_ratio_updater = ($diff_ratio_updater + $CLIdelay);
	$drop_count_updater = ($drop_count_updater + $CLIdelay);

	usleep($CLIdelay*1000*1000);

	$stat_count++;
	$master_loop++;
	}

$dbhA->disconnect();

if($DB)
	{
	### calculate time to run script ###
	$secY = time();
	$secZ = ($secY - $secT);

	if (!$q) {print "DONE. Script execution time in seconds: $secZ\n";}
	}

exit;





### SUBROUTINES ###############################################################

sub event_logger
	{
	if ($SYSLOG)
		{
		if (!$VDHLOGfile) {$VDHLOGfile = "$PATHlogs/adapt.$year-$mon-$mday";}

		### open the log file for writing ###
		open(Lout, ">>$VDHLOGfile")
				|| die "Can't open $VDHLOGfile: $!\n";
		print Lout "$now_date|$event_string|\n";
		close(Lout);
		}
	$event_string='';
	}


sub adaptive_logger
	{
	if ($SYSLOG)
		{
		$VDHCLOGfile = "$PATHlogs/VDadaptive-$campaign_id[$i].$file_date";

		### open the log file for writing ###
		open(Aout, ">>$VDHCLOGfile")
				|| die "Can't open $VDHCLOGfile: $!\n";
		print Aout "$now_date$adaptive_string\n";
		close(Aout);
		}

	$stmtA = "UPDATE vicidial_campaign_stats_debug SET entry_time='$now_date',adapt_output='$adaptive_string' where campaign_id='$campaign_id[$i]' and server_ip='ADAPT';";
	$affected_rows = $dbhA->do($stmtA);

	$adaptive_string='';
	}

sub get_time_now
	{
	$secX = time();
	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	$year = ($year + 1900);
	$mon++;
	if ($mon < 10) {$mon = "0$mon";}
	if ($mday < 10) {$mday = "0$mday";}
	if ($hour < 10) {$hour = "0$hour";}
	if ($min < 10) {$min = "0$min";}
	if ($sec < 10) {$sec = "0$sec";}
	$file_date = "$year-$mon-$mday";
	$now_date = "$year-$mon-$mday $hour:$min:$sec";
	$VDL_date = "$year-$mon-$mday 00:00:01";
	$current_hourmin = "$hour$min";

	### get date-time of one hour ago ###
	$VDL_hour = ($secX - (60 * 60));
	($Vsec,$Vmin,$Vhour,$Vmday,$Vmon,$Vyear,$Vwday,$Vyday,$Visdst) = localtime($VDL_hour);
	$Vyear = ($Vyear + 1900);
	$Vmon++;
	if ($Vmon < 10) {$Vmon = "0$Vmon";}
	if ($Vmday < 10) {$Vmday = "0$Vmday";}
	$VDL_hour = "$Vyear-$Vmon-$Vmday $Vhour:$Vmin:$Vsec";

	### get date-time of half hour ago ###
	$VDL_halfhour = ($secX - (30 * 60));
	($Vsec,$Vmin,$Vhour,$Vmday,$Vmon,$Vyear,$Vwday,$Vyday,$Visdst) = localtime($VDL_halfhour);
	$Vyear = ($Vyear + 1900);
	$Vmon++;
	if ($Vmon < 10) {$Vmon = "0$Vmon";}
	if ($Vmday < 10) {$Vmday = "0$Vmday";}
	$VDL_halfhour = "$Vyear-$Vmon-$Vmday $Vhour:$Vmin:$Vsec";

	### get date-time of five minutes ago ###
	$VDL_five = ($secX - (5 * 60));
	($Vsec,$Vmin,$Vhour,$Vmday,$Vmon,$Vyear,$Vwday,$Vyday,$Visdst) = localtime($VDL_five);
	$Vyear = ($Vyear + 1900);
	$Vmon++;
	if ($Vmon < 10) {$Vmon = "0$Vmon";}
	if ($Vmday < 10) {$Vmday = "0$Vmday";}
	$VDL_five = "$Vyear-$Vmon-$Vmday $Vhour:$Vmin:$Vsec";

	### get epoch of ninty seconds ago ###
	$VDL_ninty = ($secX - (1 * 90));

	### get date-time of one minute ago ###
	$VDL_one = ($secX - (1 * 60));
	($Vsec,$Vmin,$Vhour,$Vmday,$Vmon,$Vyear,$Vwday,$Vyday,$Visdst) = localtime($VDL_one);
	$Vyear = ($Vyear + 1900);
	$Vmon++;
	if ($Vmon < 10) {$Vmon = "0$Vmon";}
	if ($Vmday < 10) {$Vmday = "0$Vmday";}
	$VDL_one = "$Vyear-$Vmon-$Vmday $Vhour:$Vmin:$Vsec";

	$timeclock_end_of_day_NOW=0;
	### Grab system_settings values from the database
	$stmtA = "SELECT count(*) from system_settings where timeclock_end_of_day LIKE \"%$current_hourmin%\";";
	if ($DBX) {print "|$stmtA|\n";}
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$timeclock_end_of_day_NOW =	$aryA[0];
		}
	$sthA->finish();

	if ($timeclock_end_of_day_NOW > 0)
		{
		$event_string = "End of Day, shutting down this script in 10 seconds, script will resume in 60 seconds...";
			if ($DB) {print "\n$event_string\n\n\n";}
		&event_logger;	

		usleep(10*1000*1000);

		exit;
		}
	}


sub count_agents_lines
	{
	### Calculate campaign-wide agent waiting and calls waiting differential
	$stat_it=15;
	$total_agents[$i]=0;
	$total_remote_agents[$i]=0;
	$ready_agents[$i]=0;
	$waiting_calls[$i]=0;
	$ready_diff_total[$i]=0;
	$waiting_diff_total[$i]=0;
	$total_agents_total[$i]=0;
	$ready_diff_avg[$i]=0;
	$waiting_diff_avg[$i]=0;
	$total_agents_avg[$i]=0;
	$stat_differential[$i]=0;

	$stmtA = "SELECT count(*),status from vicidial_live_agents where campaign_id='$campaign_id[$i]' and last_update_time > '$VDL_one' group by status;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$VCSagent_count[$i] =	$aryA[0];
		$VCSagent_status[$i] =	$aryA[1];
		$rec_count++;
		if ($VCSagent_status[$i] =~ /READY|DONE/) {$ready_agents[$i] = ($ready_agents[$i] + $VCSagent_count[$i]);}
		$total_agents[$i] = ($total_agents[$i] + $VCSagent_count[$i]);
		}
	$sthA->finish();

	$stmtA = "SELECT count(*) FROM vicidial_auto_calls where campaign_id='$campaign_id[$i]' and status IN('LIVE');";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$waiting_calls[$i] = $aryA[0];
		}
	$sthA->finish();

	$stat_ready_agents[$i][$stat_count] = $ready_agents[$i];
	$stat_waiting_calls[$i][$stat_count] = $waiting_calls[$i];
	$stat_total_agents[$i][$stat_count] = $total_agents[$i];

	if ($stat_count < 15) 
		{
		$stat_it = $stat_count;
		$stat_B = 1;
		}
	else
		{
		$stat_B = ($stat_count - 14);
		}

	$it=0;
	while($it < $stat_it)
		{
		$it_ary = ($it + $stat_B);
		$ready_diff_total[$i] = ($ready_diff_total[$i] + $stat_ready_agents[$i][$it_ary]);
		$waiting_diff_total[$i] = ($waiting_diff_total[$i] + $stat_waiting_calls[$i][$it_ary]);
		$total_agents_total[$i] = ($total_agents_total[$i] + $stat_total_agents[$i][$it_ary]);
	#		$event_string="$stat_count $it_ary   $stat_total_agents[$i][$it_ary]|$stat_ready_agents[$i][$it_ary]|$stat_waiting_calls[$i][$it_ary]";
	#		if ($DB) {print "     $event_string\n";}
	#		&event_logger;
		$it++;
		}

	# LIVE CAMPAIGN CALLS RIGHT NOW
	if ($daily_stats > 0)
		{
		$stmtA = "SELECT count(*) from vicidial_live_agents where campaign_id='$campaign_id[$i]' and last_update_time > '$VDL_one' and extension LIKE \"R/%\";";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$total_remote_agents[$i] = $aryA[0];
			}
		$sthA->finish();
		}

	if ($ready_diff_total[$i] > 0) 
		{$ready_diff_avg[$i] = ($ready_diff_total[$i] / $stat_it);}
	if ($waiting_diff_total[$i] > 0) 
		{$waiting_diff_avg[$i] = ($waiting_diff_total[$i] / $stat_it);}
	if ($total_agents_total[$i] > 0) 
		{$total_agents_avg[$i] = ($total_agents_total[$i] / $stat_it);}
	$stat_differential[$i] = ($ready_diff_avg[$i] - $waiting_diff_avg[$i]);

	$event_string="CAMPAIGN DIFFERENTIAL: $total_agents_avg[$i]   $stat_differential[$i]   ($ready_diff_avg[$i] - $waiting_diff_avg[$i])";
	if ($DBX) {print "$campaign_id[$i]|$event_string\n";}
	if ($DB) {print "     $event_string\n";}
	$debug_camp_output .= "$event_string\n";

	&event_logger;

	#	$stmtA = "UPDATE vicidial_campaign_stats SET differential_onemin[$i]='$stat_differential[$i]', agents_average_onemin[$i]='$total_agents_avg[$i]' where campaign_id='$DBIPcampaign[$i]';";
	#	$affected_rows = $dbhA->do($stmtA);
	}





sub calculate_drops
	{
	$ofcom_uk_drop_calc_ANY=0;
	$camp_ANS_STAT_SQL='';
	# GET LIST OF HUMAN-ANSWERED STATUSES
	$stmtA = "SELECT status from vicidial_statuses where human_answered='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_ANS_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();

	$stmtA = "SELECT status from vicidial_campaign_statuses where campaign_id='$campaign_id[$i]' and human_answered='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_ANS_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();

	chop($camp_ANS_STAT_SQL);
	if (length($camp_ANS_STAT_SQL)<2) 
		{$camp_ANS_STAT_SQL="'-NONE-'";}

	$debug_camp_output .= "     CAMPAIGN ANSWERED STATUSES: $campaign_id[$i]|$camp_ANS_STAT_SQL|\n";
	if ($DBX) {print "     CAMPAIGN ANSWERED STATUSES: $campaign_id[$i]|$camp_ANS_STAT_SQL|\n";}


	$camp_AM_STAT_SQL='';
	# GET LIST OF HUMAN-ANSWERED STATUSES
	$stmtA = "SELECT status from vicidial_statuses where answering_machine='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_AM_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();

	$stmtA = "SELECT status from vicidial_campaign_statuses where campaign_id='$campaign_id[$i]' and answering_machine='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_AM_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();

	chop($camp_AM_STAT_SQL);
	if (length($camp_AM_STAT_SQL)<2) 
		{$camp_AM_STAT_SQL="'-NONE-'";}

	$debug_camp_output .= "     CAMPAIGN ANSWERING MACHINE STATUSES: $campaign_id[$i]|$camp_AM_STAT_SQL|\n";
	if ($DBX) {print "     CAMPAIGN ANSWERING MACHINE STATUSES: $campaign_id[$i]|$camp_AM_STAT_SQL|\n";}

	$RESETdrop_count_updater++;
	$VCScalls_today[$i]=0;
	$VCSanswers_today[$i]=0;
	$VCSagenthandled_today[$i]=0;
	$VCSam_today[$i]=0;
	$VCSdrops_today[$i]=0;
	$VCSdrops_today_pct[$i]=0;
	$VCSdrops_answers_today_pct[$i]=0;
	$VCScalls_hour[$i]=0;
	$VCSanswers_hour[$i]=0;
	$VCSdrops_hour[$i]=0;
	$VCSdrops_hour_pct[$i]=0;
	$VCScalls_halfhour[$i]=0;
	$VCSanswers_halfhour[$i]=0;
	$VCSdrops_halfhour[$i]=0;
	$VCSdrops_halfhour_pct[$i]=0;
	$VCScalls_five[$i]=0;
	$VCSanswers_five[$i]=0;
	$VCSdrops_five[$i]=0;
	$VCSdrops_five_pct[$i]=0;
	$VCScalls_one[$i]=0;
	$VCSanswers_one[$i]=0;
	$VCSdrops_one[$i]=0;
	$VCSdrops_one_pct[$i]=0;
	$VCSagent_nonpause_time[$i]=0;
	$VCSagent_pause_today[$i]=0;
	$VCSagent_wait_today[$i]=0;
	$VCSagent_custtalk_today[$i]=0;
	$VCSagent_acw_today[$i]=0;
	$VCSagent_calls_today[$i]=0;
	$VCSlive_calls[$i]=0;

	# LAST ONE MINUTE CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_one';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$VCScalls_one[$i] =	$aryA[0];
		}
	$sthA->finish();

	if ($VCScalls_one[$i] > 0)
		{
		# LAST MINUTE ANSWERS
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_one' and status IN($camp_ANS_STAT_SQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSanswers_one[$i] =	$aryA[0];
			}
		$sthA->finish();

		# LAST MINUTE DROPS
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_one' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSdrops_one[$i] =	$aryA[0];
			if ($VCSdrops_one[$i] > 0)
				{
				$VCSdrops_one_pct[$i] = ( ($VCSdrops_one[$i] / $VCScalls_one[$i]) * 100 );
				$VCSdrops_one_pct[$i] = sprintf("%.2f", $VCSdrops_one_pct[$i]);	
				}
			}
		$sthA->finish();
		}

	# TODAY CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$VCScalls_today[$i] =	$aryA[0];
		}
	$sthA->finish();

	if ($VCScalls_today[$i] > 0)
		{
		# TODAY ANSWERS
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date' and status IN($camp_ANS_STAT_SQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSanswers_today[$i] =	$aryA[0];
			}
		$sthA->finish();

		# TODAY ANSWERING MACHINES CODED BY AGENTS FOR UK OFCOM CALCULATION
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date' and status IN($camp_AM_STAT_SQL) and user != 'VDAD';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSam_today[$i] =	$aryA[0];
			}
		$sthA->finish();

		# TODAY AGENT HANDLED ANSWERED CALLS FOR UK OFCOM CALCULATION
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date' and status IN($camp_ANS_STAT_SQL) and user != 'VDAD';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSagenthandled_today[$i] =	$aryA[0];
			}
		$sthA->finish();

		# TODAY DROPS
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		if ($DBX > 0) {print "$stmtA\n";}
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSdrops_today[$i] =	$aryA[0];
			$temp_raw_drop = $VCSdrops_today[$i];
			if ($VCSdrops_today[$i] > 0)
				{
				if ( ($SSofcom_uk_drop_calc > 0) && ($ofcom_uk_drop_calc[$i] =~ /Y/) ) 
					{
					$ofcom_uk_drop_calc_ANY++;

					$debug_camp_output .= "UK OFCOM DROP CALCULATION TRIGGERED FOR THIS CAMPAIGN: ($SSofcom_uk_drop_calc|$ofcom_uk_drop_calc[$i]|$ofcom_uk_drop_calc_ANY)\n";
					if ($DBX) {print "UK OFCOM DROP CALCULATION TRIGGERED FOR THIS CAMPAIGN: ($SSofcom_uk_drop_calc|$ofcom_uk_drop_calc[$i]|$ofcom_uk_drop_calc_ANY)\n";}

					# As of December 2015, OFCOM in the UK changed their method for calculating 
					# the drop(or abandon) percentage for an outbound dialing campaign. The new 
					# formula is to estimate the number of drops that were answering machines. 
					# They do this by using the agent-answered percentage of answering machines 
					# and subtracting that percentage from the number of drops. Then that new 
					# drop number is divided by the total agent-answered human-answered calls 
					# PLUS the number of drops. This differs in several ways from the way it had 
					# been done, as well as the way the drop percentage has been calculated in 
					# the USA and Canada. This new UK drop calculation method is activated as a
					# system setting AND a campaign option. Both must be enabled for the campaign
					# to use the new method. You will see code similar to the section below for 
					# each time period that the drop percentage is calculated. In order for agent-
					# statused answering machines to be calculated properly, we have added an 
					# answering machine status flag that is used to gather those statuses.

					if ($VCSam_today[$i] > 0)
						{
						$temp_am_pct = ($VCSam_today[$i] / ($VCSagenthandled_today[$i] + $VCSam_today[$i]) );
						$temp_am_drops = ($VCSdrops_today[$i] * $temp_am_pct);
						$VCSdrops_today[$i] = ($VCSdrops_today[$i] - $temp_am_drops);
						}
					$VCSdrops_today[$i] = sprintf("%.3f", $VCSdrops_today[$i]);
					$temp_answers_today = ($VCSagenthandled_today[$i] + $VCSdrops_today[$i]);
					if ($temp_answers_today < 1) {$temp_answers_today = 1;}
					$VCSdrops_answers_today_pct[$i] = ( ($VCSdrops_today[$i] / $temp_answers_today) * 100 );
					$VCSdrops_answers_today_pct[$i] = sprintf("%.2f", $VCSdrops_answers_today_pct[$i]);
					}
				else
					{
					if ($VCSanswers_today[$i] < 1) {$VCSanswers_today[$i] = 1;}
					$VCSdrops_answers_today_pct[$i] = ( ($VCSdrops_today[$i] / $VCSanswers_today[$i]) * 100 );
					$VCSdrops_answers_today_pct[$i] = sprintf("%.2f", $VCSdrops_answers_today_pct[$i]);
					}
				$VCSdrops_today_pct[$i] = ( ($VCSdrops_today[$i] / $VCScalls_today[$i]) * 100 );
				$VCSdrops_today_pct[$i] = sprintf("%.2f", $VCSdrops_today_pct[$i]);
				}
			}
		$sthA->finish();

		$debug_camp_output .= "     CALLS: $VCScalls_today[$i]   ANSWERs: $VCSanswers_today[$i]   AGENT-ANS: $VCSagenthandled_today[$i]   AGENT-AMs: $VCSam_today[$i]   DROPs: $VCSdrops_today[$i]($temp_raw_drop)   DROP-TOT PCT: $VCSdrops_today_pct[$i]   DROP-ANS PCT: $VCSdrops_answers_today_pct[$i]\n";
		if ($DBX) {print "     CALLS: $VCScalls_today[$i]   ANSWERs: $VCSanswers_today[$i]   AGENT-ANS: $VCSagenthandled_today[$i]   AGENT-AMs: $VCSam_today[$i]   DROPs: $VCSdrops_today[$i]($temp_raw_drop)   DROP-TOT PCT: $VCSdrops_today_pct[$i]   DROP-ANS PCT: $VCSdrops_answers_today_pct[$i]\n";}
		}

	# LAST HOUR CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_hour';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$VCScalls_hour[$i] =	$aryA[0];
		}
	$sthA->finish();

	if ($VCScalls_hour[$i] > 0)
		{
		# ANSWERS LAST HOUR
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_hour' and status IN($camp_ANS_STAT_SQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSanswers_hour[$i] =	$aryA[0];
			}
		$sthA->finish();

		# DROP LAST HOUR
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_hour' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSdrops_hour[$i] =	$aryA[0];
			if ($VCSdrops_hour[$i] > 0)
				{
				$VCSdrops_hour_pct[$i] = ( ($VCSdrops_hour[$i] / $VCScalls_hour[$i]) * 100 );
				$VCSdrops_hour_pct[$i] = sprintf("%.2f", $VCSdrops_hour_pct[$i]);	
				}
			$rec_count++;
			}
		$sthA->finish();
		}

	# LAST HALFHOUR CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_halfhour';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$VCScalls_halfhour[$i] =	$aryA[0];
		}
	$sthA->finish();

	if ($VCScalls_halfhour[$i] > 0)
		{
		# ANSWERS HALFHOUR
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_halfhour' and status IN($camp_ANS_STAT_SQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSanswers_halfhour[$i] =	$aryA[0];
			}
		$sthA->finish();

		# DROPS HALFHOUR
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_halfhour' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSdrops_halfhour[$i] =	$aryA[0];
			if ($VCSdrops_halfhour[$i] > 0)
				{
				$VCSdrops_halfhour_pct[$i] = ( ($VCSdrops_halfhour[$i] / $VCScalls_halfhour[$i]) * 100 );
				$VCSdrops_halfhour_pct[$i] = sprintf("%.2f", $VCSdrops_halfhour_pct[$i]);	
				}
			}
		$sthA->finish();
		}

	# LAST FIVE MINUTE CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_five';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$VCScalls_five[$i] =	$aryA[0];
		}
	$sthA->finish();

	if ($VCScalls_five[$i] > 0)
		{
		# ANSWERS FIVEMINUTE
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_five' and status IN($camp_ANS_STAT_SQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSanswers_five[$i] =	$aryA[0];
			}
		$sthA->finish();

		# DROPS FIVEMINUTE
		$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_five' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSdrops_five[$i] =	$aryA[0];
			if ($VCSdrops_five[$i] > 0)
				{
				$VCSdrops_five_pct[$i] = ( ($VCSdrops_five[$i] / $VCScalls_five[$i]) * 100 );
				$VCSdrops_five_pct[$i] = sprintf("%.2f", $VCSdrops_five_pct[$i]);	
				}
			}
		$sthA->finish();
		}
	$debug_camp_output .= "$campaign_id[$i]|$VCSdrops_five_pct[$i]|$VCSdrops_today_pct[$i]|     |$VCSdrops_today[$i] / $VCScalls_today[$i] / $VCSanswers_today[$i]|   $i\n";
	if ($DBX) {print "$campaign_id[$i]|$VCSdrops_five_pct[$i]|$VCSdrops_today_pct[$i]|     |$VCSdrops_today[$i] / $VCScalls_today[$i] / $VCSanswers_today[$i]|   $i\n";}

	# DETERMINE WHETHER TO GATHER STATUS CATEGORY STATISTICS
	$VSC_categories=0;
	$VSCupdateSQL='';
	$stmtA = "SELECT vsc_id from vicidial_status_categories where tovdad_display='Y' limit 4;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$VSC_categories[$rec_count] =	$aryA[0];
		$rec_count++;
		}
	$sthA->finish();

	$g=0;
	foreach (@VSC_categories)
		{
		$VSCcategory=$VSC_categories[$g];
		$VSCtally='';
		$CATstatusesSQL='';
		# FIND STATUSES IN STATUS CATEGORY
		$stmtA = "SELECT status from vicidial_statuses where category='$VSCcategory';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$rec_count=0;
		while ($sthArows > $rec_count)
			{
			@aryA = $sthA->fetchrow_array;
			$CATstatusesSQL .=		 "'$aryA[0]',";
			$rec_count++;
			}
		$sthA->finish();

		# FIND CAMPAIGN_STATUSES IN STATUS CATEGORY
		$stmtA = "SELECT status from vicidial_campaign_statuses where category='$VSCcategory' and campaign_id='$campaign_id[$i]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$rec_count=0;
		while ($sthArows > $rec_count)
			{
			@aryA = $sthA->fetchrow_array;
			$CATstatusesSQL .=		 "'$aryA[0]',";
			$rec_count++;
			}
		$sthA->finish();

		chop($CATstatusesSQL);
		if (length($CATstatusesSQL) > 2)
			{
			# FIND STATUSES IN STATUS CATEGORY
			$stmtA = "SELECT count(*) from $vicidial_log where campaign_id='$campaign_id[$i]' and call_date > '$VDL_date' and status IN($CATstatusesSQL);";
			#	if ($DBX) {print "|$stmtA|\n";}
			$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
			$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
			$sthArows=$sthA->rows;
			if ($sthArows > 0)
				{
				@aryA = $sthA->fetchrow_array;
				$VSCtally =		 $aryA[0];
				}
			$sthA->finish();
			}
		$g++;
		$debug_camp_output .= "     $campaign_id[$i]|$VSCcategory|$VSCtally|$CATstatusesSQL|\n";
		if ($DBX) {print "     $campaign_id[$i]|$VSCcategory|$VSCtally|$CATstatusesSQL|\n";}
		$VSCupdateSQL .= "status_category_$g='$VSCcategory',status_category_count_$g='$VSCtally',";
		}
	while ($g < 4)
		{
		$g++;
		$VSCupdateSQL .= "status_category_$g='',status_category_count_$g='0',";
		}
	chop($VSCupdateSQL);

	# AGENT NON-PAUSE TIME PULL
	$stmtA = "SELECT sum(wait_sec + talk_sec + dispo_sec) from vicidial_agent_log where campaign_id='$campaign_id[$i]' and event_time > '$VDL_date';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		if ($aryA[0] > 0)
			{$VCSagent_nonpause_time[$i] = $aryA[0];}
		}
	$sthA->finish();

	# LIVE CAMPAIGN CALLS RIGHT NOW
	if ($daily_stats > 0)
		{
		$stmtA = "SELECT count(*) from vicidial_auto_calls where campaign_id='$campaign_id[$i]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$VCSlive_calls[$i] = $aryA[0];
			$debug_camp_output .= "     LIVE CALLS: $aryA[0]|$stmtA\n";
			}
		$sthA->finish();
		}

	# If campaign is using a drop rate group, gather its stats
	if ($drop_rate_group[$i] !~ /DISABLED/)
		{
		$stmtA = "SELECT drops_answers_today_pct,calls_today,answers_today,drops_today,answering_machines_today,agenthandled_today from vicidial_drop_rate_groups where group_id='$drop_rate_group[$i]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$debug_camp_output .= "     DROP RATE GROUP USED: $drop_rate_group[$i]     $aryA[0]($VCSdrops_answers_today_pct[$i])   calls:$aryA[1]($VCScalls_today[$i])   ans:$aryA[2]($VCSanswers_today[$i])   drops:$aryA[3]($VCSdrops_today[$i])   agnt-am-ans:$aryA[4]($VCSam_today[$i])$aryA[5]($VCSagenthandled_today[$i])\n";
			if ($DBX) {print "     DROP RATE GROUP USED: $drop_rate_group[$i]     $aryA[0]($VCSdrops_answers_today_pct[$i])   calls:$aryA[1]($VCScalls_today[$i])   ans:$aryA[2]($VCSanswers_today[$i])   drops:$aryA[3]($VCSdrops_today[$i])   agnt-am-ans:$aryA[4]($VCSam_today[$i])$aryA[5]($VCSagenthandled_today[$i])\n";}
			$VCSdrops_answers_today_pct[$i] =	$aryA[0];
			}
		$sthA->finish();
		}
	
	# if campaign realtime agent time stats is enabled, gather those here
	if ($realtime_agent_time_stats[$i] =~ /WAIT_CUST_ACW/)
		{
		$stmtA = "SELECT sum(pause_sec),sum(wait_sec),sum(talk_sec) - sum(dead_sec) as custtalk,sum(dispo_sec) + sum(dead_sec) as acw from vicidial_agent_log where event_time > '$VDL_date' and campaign_id='$campaign_id[$i]' and pause_sec < 65000 and wait_sec < 65000 and talk_sec < 65000 and dispo_sec < 65000 and dead_sec < 65000;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$debug_camp_output .= "     AGENT TIME STATS: $aryA[0] $aryA[1] $aryA[2] $aryA[3]|$stmtA\n";
			if ($DBX) {print "     AGENT TIME STATS: $aryA[0] $aryA[1] $aryA[2] $aryA[3]|$stmtA\n";}
			$VCSagent_pause_today[$i] =		$aryA[0];
			$VCSagent_wait_today[$i] =		$aryA[1];
			$VCSagent_custtalk_today[$i] =	$aryA[2];
			$VCSagent_acw_today[$i] =		$aryA[3];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_agent_log where event_time > '$VDL_date' and campaign_id='$campaign_id[$i]' and lead_id > 0;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$debug_camp_output .= "     AGENT CALLS: $aryA[0]|$stmtA\n";
			if ($DBX) {print "     AGENT CALLS: $aryA[0]|$stmtA\n";}
			$VCSagent_calls_today[$i] =		$aryA[0];
			}
		$sthA->finish();
		}

	$stmtA = "UPDATE vicidial_campaign_stats SET calls_today='$VCScalls_today[$i]',answers_today='$VCSanswers_today[$i]',drops_today='$VCSdrops_today[$i]',drops_today_pct='$VCSdrops_today_pct[$i]',drops_answers_today_pct='$VCSdrops_answers_today_pct[$i]',calls_hour='$VCScalls_hour[$i]',answers_hour='$VCSanswers_hour[$i]',drops_hour='$VCSdrops_hour[$i]',drops_hour_pct='$VCSdrops_hour_pct[$i]',calls_halfhour='$VCScalls_halfhour[$i]',answers_halfhour='$VCSanswers_halfhour[$i]',drops_halfhour='$VCSdrops_halfhour[$i]',drops_halfhour_pct='$VCSdrops_halfhour_pct[$i]',calls_fivemin='$VCScalls_five[$i]',answers_fivemin='$VCSanswers_five[$i]',drops_fivemin='$VCSdrops_five[$i]',drops_fivemin_pct='$VCSdrops_five_pct[$i]',calls_onemin='$VCScalls_one[$i]',answers_onemin='$VCSanswers_one[$i]',drops_onemin='$VCSdrops_one[$i]',drops_onemin_pct='$VCSdrops_one_pct[$i]',agent_non_pause_sec='$VCSagent_nonpause_time[$i]',agent_calls_today='$VCSagent_calls_today[$i]',agent_pause_today='$VCSagent_pause_today[$i]',agent_wait_today='$VCSagent_wait_today[$i]',agent_custtalk_today='$VCSagent_custtalk_today[$i]',agent_acw_today='$VCSagent_acw_today[$i]',answering_machines_today='$VCSam_today[$i]',agenthandled_today='$VCSagenthandled_today[$i]',$VSCupdateSQL where campaign_id='$campaign_id[$i]';";
	$affected_rows = $dbhA->do($stmtA);
	if ($DBX) {print "OUTBOUND $campaign_id[$i]|$affected_rows|$stmtA|\n";}

	$debug_camp_output =~ s/;|\\\\|\/|\'//gi;
	$stmtA = "UPDATE vicidial_campaign_stats_debug SET entry_time='$now_date',debug_output='$debug_camp_output' where campaign_id='$campaign_id[$i]' and server_ip='ADAPT';";
	$affected_rows = $dbhA->do($stmtA);
	$debug_camp_output='';

	##### BEGIN - DAILY STATS UPDATE CAMPAIGN
	if ($daily_stats > 0)
		{
		$STATSmax_outbound=0;
		$STATSmax_agents=0;
		$STATSmax_remote_agents=0;
		$STATStotal_calls=0;
		$stmtA = "SELECT max_outbound,max_agents,max_remote_agents,total_calls from vicidial_daily_max_stats where campaign_id='$campaign_id[$i]' and stats_type='CAMPAIGN' and stats_flag='OPEN' order by update_time desc limit 1;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$STATSmax_outbound =		$aryA[0];
			$STATSmax_agents =			$aryA[1];
			$STATSmax_remote_agents =	$aryA[2];
			$STATStotal_calls =			$aryA[3];
			$sthA->finish();

			$update_SQL='';
			if ($STATSmax_outbound < $VCSlive_calls[$i])
				{$update_SQL .= ",max_outbound='$VCSlive_calls[$i]'";}
			if ($STATSmax_agents < $total_agents[$i]) 
				{$update_SQL .= ",max_agents='$total_agents[$i]'";}
			if ($STATSmax_remote_agents < $total_remote_agents[$i])
				{$update_SQL .= ",max_remote_agents='$total_remote_agents[$i]'";}
			if ($STATStotal_calls < $VCScalls_today[$i]) 
				{$update_SQL .= ",total_calls='$VCScalls_today[$i]'";}
			if (length($update_SQL) > 5) 
				{
				$stmtA = "UPDATE vicidial_daily_max_stats SET update_time=NOW()$update_SQL where campaign_id='$campaign_id[$i]' and stats_type='CAMPAIGN' and stats_flag='OPEN';";
				$affected_rows = $dbhA->do($stmtA);
				if ($DBX) {print "DAILY STATS UPDATE $campaign_id[$i]|$affected_rows|$stmtA|\n";}
				}
			}
		else
			{
			$sthA->finish();

			$stmtA = "INSERT INTO vicidial_daily_max_stats SET stats_date='$file_date',update_time=NOW(),max_outbound='$VCSlive_calls[$i]',max_agents='$total_agents[$i]',max_remote_agents='$total_remote_agents[$i]',total_calls='$VCScalls_today[$i]',campaign_id='$campaign_id[$i]',stats_type='CAMPAIGN',stats_flag='OPEN';";
			$affected_rows = $dbhA->do($stmtA);
			if ($DBX) {print "DAILY STATS INSERT $campaign_id[$i]|$affected_rows|$stmtA|\n";}
			}
		}
	##### END - DAILY STATS UPDATE CAMPAIGN
	}



sub drop_rate_group_gather
	{
	################################################################################
	#### BEGIN gather drop rate group stats
	################################################################################
	if ($DB) {print "\n     STARTING DROP RATE GROUP SECTION:\n";}

	# Gather drop rate groups
	@DRgroup=@MT;
	$stmtA = "SELECT group_id from vicidial_drop_rate_groups;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArowsDR=$sthA->rows;
	$dr=0;
	while ($sthArowsDR > $dr)
		{
		@aryA = $sthA->fetchrow_array;
		$DRgroup[$dr] =		 $aryA[0];
		$dr++;
		}
	$sthA->finish();

	$dr=0;
	while ($sthArowsDR > $dr)
		{
		$DRcalls_today=0;
		$DRanswers_today=0;
		$DRdrops_today=0;
		$DRdrops_today_pct=0;
		$DRdrops_answers_today_pct=0;
		$DRanswering_machines_today=0;
		$DRagenthandled_today=0;
		$stmtA = "SELECT count(*),sum(calls_today),sum(answers_today),sum(drops_today),sum(answering_machines_today),sum(agenthandled_today) from vicidial_campaign_stats vcs, vicidial_campaigns vc where vcs.campaign_id=vc.campaign_id and vc.drop_rate_group='$DRgroup[$dr]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			if ($aryA[0] > 0)
				{
				$DRcalls_today =				$aryA[1];
				$DRanswers_today =				$aryA[2];
				$DRdrops_today =				$aryA[3];
				$DRanswering_machines_today =	$aryA[4];
				$DRagenthandled_today =			$aryA[5];
				}
			}
		$sthA->finish();
		if ($DRdrops_today > 0)
			{
			if ($DRanswers_today < 1) {$DRanswers_today = 1;}

			##### UK OFCOM DROP PCT CALCULATION
			if ($DB) {print "     UK OFCOM DROP RATE CALCULATION CHECK: ($SSofcom_uk_drop_calc|$ofcom_uk_drop_calc_ANY)\n";}
			if ( ($SSofcom_uk_drop_calc > 0) && ($ofcom_uk_drop_calc_ANY > 0) )
				{
				# Keeping in mind that the campaign drop numbers are already adjusted to the OFCOM
				# number of drops, so we just have to add the drops to answers to generate the new
				# drop-group drop-answer percentage

				$temp_answers_today = ($DRagenthandled_today + $DRdrops_today);
				if ($temp_answers_today < 1) {$temp_answers_today = 1;}
				$DRdrops_answers_today_pct = ( ($DRdrops_today / $temp_answers_today) * 100 );
				$DRdrops_answers_today_pct = sprintf("%.2f", $DRdrops_answers_today_pct);
				}
			else
				{
				$DRdrops_answers_today_pct = ( ($DRdrops_today / $DRanswers_today) * 100 );
				$DRdrops_answers_today_pct = sprintf("%.2f", $DRdrops_answers_today_pct);
				}
			$DRdrops_today_pct = ( ($DRdrops_today / $DRcalls_today) * 100 );
			$DRdrops_today_pct = sprintf("%.2f", $DRdrops_today_pct);
			}

		$stmtA = "UPDATE vicidial_drop_rate_groups SET calls_today='$DRcalls_today',answers_today='$DRanswers_today',drops_today='$DRdrops_today',drops_today_pct='$DRdrops_today_pct',drops_answers_today_pct='$DRdrops_answers_today_pct',answering_machines_today='$DRanswering_machines_today',agenthandled_today='$DRagenthandled_today' where group_id='$DRgroup[$dr]';";
		$affected_rows = $dbhA->do($stmtA);
		if ($DB) {print "DROP RATE GROUP UPDATE: $DRgroup[$dr]|$affected_rows|$stmtA|\n";}

		$stmtA = "UPDATE vicidial_campaign_stats vcs, vicidial_campaigns vc SET vcs.drops_answers_today_pct='$DRdrops_answers_today_pct'  where vcs.campaign_id=vc.campaign_id and vc.drop_rate_group='$DRgroup[$dr]';";
		$affected_rows = $dbhA->do($stmtA);
		if ($DBX) {print "VCS update: $affected_rows|$stmtA|\n";}

		$dr++;
		}

	################################################################################
	#### END gather drop rate group stats
	################################################################################
	}


sub launch_max_calls_gather
	{
	################################################################################
	#### BEGIN gather stats for max channels and max calls
	################################################################################
	$serversSQL='';
	# Get list of active asterisk servers
	$stmtA = "SELECT server_ip from servers where active_asterisk_server='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$serversSQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();
	chop($serversSQL);

	if (length($serversSQL) > 5)
		{
		$stmtA = "SELECT count(*) from live_sip_channels where server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$lsc_count=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$lsc_count =	$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from live_channels where server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$lc_count=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$lc_count =		$aryA[0];
			}
		$sthA->finish();
		$tc_count = ($lsc_count + $lc_count);

		$stmtA = "SELECT count(*) from live_channels where channel NOT LIKE \"%pseudo%\" and server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$tcalls_count=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$tcalls_count =		$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_auto_calls where call_type='IN' and server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$incalls_count=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$incalls_count =		$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_auto_calls where call_type IN('OUT','OUTBALANCE') and server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$outcalls_count=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$outcalls_count =		$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_live_agents where last_update_time > '$VDL_one' and server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$live_agents=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$live_agents =	$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_live_agents where last_update_time > '$VDL_one' and extension LIKE \"R/%\" and server_ip IN($serversSQL);";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$live_remote_agents=0;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$live_remote_agents =	$aryA[0];
			}
		$sthA->finish();

		if ($DB) {print "$now_date MAX CHANNELS TOTALS:  $tc_count($lsc_count+$lc_count)|$tcalls_count|$incalls_count|$outcalls_count|$live_agents|$live_remote_agents\n";}


		$STATSmax_channels=0;
		$STATSmax_calls=0;
		$stmtA = "SELECT max_channels,max_calls,max_inbound,max_outbound,max_agents,max_remote_agents from vicidial_daily_max_stats where campaign_id='' and stats_type='TOTAL' and stats_flag='OPEN' order by update_time desc limit 1;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$STATSmax_channels =		$aryA[0];
			$STATSmax_calls =			$aryA[1];
			$STATSmax_inbound =			$aryA[2];
			$STATSmax_outbound =		$aryA[3];
			$STATSmax_agents =			$aryA[4];
			$STATSmax_remote_agents =	$aryA[5];
			$sthA->finish();

			$update_SQL='';
			if ($STATSmax_channels < $tc_count) 
				{$update_SQL .= ",max_channels='$tc_count'";}
			if ($STATSmax_calls < $tcalls_count) 
				{$update_SQL .= ",max_calls='$tcalls_count'";}
			if ($STATSmax_inbound < $incalls_count) 
				{$update_SQL .= ",max_inbound='$incalls_count'";}
			if ($STATSmax_outbound < $outcalls_count) 
				{$update_SQL .= ",max_outbound='$outcalls_count'";}
			if ($STATSmax_agents < $live_agents) 
				{$update_SQL .= ",max_agents='$live_agents'";}
			if ($STATSmax_remote_agents < $live_remote_agents) 
				{$update_SQL .= ",max_remote_agents='$live_remote_agents'";}

			if (length($update_SQL) > 5) 
				{
				$stmtA = "UPDATE vicidial_daily_max_stats SET update_time=NOW()$update_SQL where campaign_id='' and stats_type='TOTAL' and stats_flag='OPEN';";
				$affected_rows = $dbhA->do($stmtA);
				if ($DBX) {print "DAILY STATS UPDATE $campaign_id[$i]|$affected_rows|$stmtA|\n";}
				}
			}
		else
			{
			$sthA->finish();

			$stmtA = "INSERT INTO vicidial_daily_max_stats SET stats_date='$file_date',update_time=NOW(),max_channels='$tc_count',max_calls='$tcalls_count',max_inbound='$incalls_count',max_outbound='$outcalls_count',max_agents='$live_agents',max_remote_agents='$live_remote_agents',campaign_id='',stats_type='TOTAL',stats_flag='OPEN';";
			$affected_rows = $dbhA->do($stmtA);
			if ($DBX) {print "DAILY STATS INSERT    TOTAL|$affected_rows|$stmtA|\n";}
			}
		}
	################################################################################
	#### END gather stats for max channels and max calls
	################################################################################
	}



sub launch_carrier_stats_gather
	{
	################################################################################
	#### BEGIN gather carrier stats for real-time report
	################################################################################
	$TFhour_total=0; @TFhour_status=@MT; @TFhour_count=@MT;
	$SIXhour_total=0; @SIXhour_status=@MT; @SIXhour_count=@MT;
	$ONEhour_total=0; @ONEhour_status=@MT; @ONEhour_count=@MT;
	$FTminute_total=0; @FTminute_status=@MT; @FTminute_count=@MT;
	$FIVEminute_total=0; @FIVEminute_status=@MT; @FIVEminute_count=@MT;
	$ONEminute_total=0; @ONEminute_status=@MT; @ONEminute_count=@MT;

	### BEGIN calculate times needed for queries ###
	$secC = time();
	$epochONEminuteAGO = ($secC - 60);
	$epochFIVEminutesAGO = ($secC - 300);
	$epochFIFTEENminutesAGO = ($secC - 900);
	$epochONEhourAGO = ($secC - 3600);
	$epochSIXhoursAGO = ($secC - 21600);
	$epochTWENTYFOURhoursAGO = ($secC - 86400);

	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($secC);
	$mon++;	$year = ($year + 1900);
	if ($mon < 10) {$mon = "0$mon";}
	if ($mday < 10) {$mday = "0$mday";}
	if ($hour < 10) {$hour = "0$hour";}
	if ($min < 10) {$min = "0$min";}
	if ($sec < 10) {$sec = "0$sec";}
	$timeNOW = "$year-$mon-$mday $hour:$min:$sec";

	($Osec,$Omin,$Ohour,$Omday,$Omon,$Oyear,$Owday,$Oyday,$Oisdst) = localtime($epochONEminuteAGO);
	$Omon++;	$Oyear = ($Oyear + 1900);
	if ($Omon < 10) {$Omon = "0$Omon";}
	if ($Omday < 10) {$Omday = "0$Omday";}
	if ($Ohour < 10) {$Ohour = "0$Ohour";}
	if ($Omin < 10) {$Omin = "0$Omin";}
	if ($Osec < 10) {$Osec = "0$Osec";}
	$timeONEminuteAGO = "$Oyear-$Omon-$Omday $Ohour:$Omin:$Osec";

	($Fsec,$Fmin,$Fhour,$Fmday,$Fmon,$Fyear,$Fwday,$Fyday,$Fisdst) = localtime($epochFIVEminutesAGO);
	$Fmon++;	$Fyear = ($Fyear + 1900);
	if ($Fmon < 10) {$Fmon = "0$Fmon";}
	if ($Fmday < 10) {$Fmday = "0$Fmday";}
	if ($Fhour < 10) {$Fhour = "0$Fhour";}
	if ($Fmin < 10) {$Fmin = "0$Fmin";}
	if ($Fsec < 10) {$Fsec = "0$Fsec";}
	$timeFIVEminutesAGO = "$Fyear-$Fmon-$Fmday $Fhour:$Fmin:$Fsec";

	($Isec,$Imin,$Ihour,$Imday,$Imon,$Iyear,$Iwday,$Iyday,$Iisdst) = localtime($epochFIFTEENminutesAGO);
	$Imon++;	$Iyear = ($Iyear + 1900);
	if ($Imon < 10) {$Imon = "0$Imon";}
	if ($Imday < 10) {$Imday = "0$Imday";}
	if ($Ihour < 10) {$Ihour = "0$Ihour";}
	if ($Imin < 10) {$Imin = "0$Imin";}
	if ($Isec < 10) {$Isec = "0$Isec";}
	$timeFIFTEENminutesAGO = "$Iyear-$Imon-$Imday $Ihour:$Imin:$Isec";

	($Hsec,$Hmin,$Hhour,$Hmday,$Hmon,$Hyear,$Hwday,$Hyday,$Hisdst) = localtime($epochONEhourAGO);
	$Hmon++;	$Hyear = ($Hyear + 1900);
	if ($Hmon < 10) {$Hmon = "0$Hmon";}
	if ($Hmday < 10) {$Hmday = "0$Hmday";}
	if ($Hhour < 10) {$Hhour = "0$Hhour";}
	if ($Hmin < 10) {$Hmin = "0$Hmin";}
	if ($Hsec < 10) {$Hsec = "0$Hsec";}
	$timeONEhourAGO = "$Hyear-$Hmon-$Hmday $Hhour:$Hmin:$Hsec";

	($Ssec,$Smin,$Shour,$Smday,$Smon,$Syear,$Swday,$Syday,$Sisdst) = localtime($epochSIXhoursAGO);
	$Smon++;	$Syear = ($Syear + 1900);
	if ($Smon < 10) {$Smon = "0$Smon";}
	if ($Smday < 10) {$Smday = "0$Smday";}
	if ($Shour < 10) {$Shour = "0$Shour";}
	if ($Smin < 10) {$Smin = "0$Smin";}
	if ($Ssec < 10) {$Ssec = "0$Ssec";}
	$timeSIXhoursAGO = "$Syear-$Smon-$Smday $Shour:$Smin:$Ssec";

	($Wsec,$Wmin,$Whour,$Wmday,$Wmon,$Wyear,$Wwday,$Wyday,$Wisdst) = localtime($epochTWENTYFOURhoursAGO);
	$Wmon++;	$Wyear = ($Wyear + 1900);
	if ($Wmon < 10) {$Wmon = "0$Wmon";}
	if ($Wmday < 10) {$Wmday = "0$Wmday";}
	if ($Whour < 10) {$Whour = "0$Whour";}
	if ($Wmin < 10) {$Wmin = "0$Wmin";}
	if ($Wsec < 10) {$Wsec = "0$Wsec";}
	$timeTWENTYFOURhoursAGO = "$Wyear-$Wmon-$Wmday $Whour:$Wmin:$Wsec";

	if ($DB > 0) 
		{
		print "Carrier stats gather starting now:\n";
		print "Time now:                    $timeNOW\n";
		}
	if ($DBX > 0) 
		{
		print "Time one minute ago:         $timeONEminuteAGO\n";
		print "Time five minutes ago:       $timeFIVEminutesAGO\n";
		print "Time fifteen minutes ago:    $timeFIFTEENminutesAGO\n";
		print "Time one hour ago:           $timeONEhourAGO\n";
		print "Time six hours ago:          $timeSIXhoursAGO\n";
		print "Time twenty four hours ago:  $timeTWENTYFOURhoursAGO\n";
		}
	### END calculate times needed for queries ###

	$CARRIERstatsHTML='';
	$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeTWENTYFOURhoursAGO\" group by dialstatus;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$ctp=0;
	while ($sthArows > $ctp)
		{
		@aryA = $sthA->fetchrow_array;
		$TFhour_status[$ctp] =	$aryA[0];
		$TFhour_count[$ctp] =	$aryA[1];
		$TFhour_total = ($TFhour_total + $aryA[1]);
		$dialstatuses .= "'$aryA[0]',";
		$ctp++;
		}
	$sthA->finish();
	$dialstatuses =~ s/,$//gi;

	$CARRIERstatsHTML .= "<TR BGCOLOR=white><TD ALIGN=left COLSPAN=8>";
	$CARRIERstatsHTML .= "<TABLE CELLPADDING=1 CELLSPACING=1 BORDER=0 BGCOLOR=white>";
	$CARRIERstatsHTML .= "<TR BGCOLOR='#E6E6E6'>";
	$CARRIERstatsHTML .= "<TD ALIGN=LEFT><font size=1 face='helvetica'><B>CARRIER STATS: &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=LEFT><font size=1 face='helvetica'><B>&nbsp; HANGUP STATUS &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 24 HOURS &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 6 HOURS &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 1 HOUR &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 15 MIN &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 5 MIN &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "<TD ALIGN=CENTER><font size=1 face='helvetica'><B>&nbsp; 1 MIN &nbsp; </B></TD>";
	$CARRIERstatsHTML .= "</TR>";

	if (length($dialstatuses) > 1)
		{
		$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeSIXhoursAGO\" group by dialstatus;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$print_sctp=0;
		while ($sthArows > $print_sctp)
			{
			@aryA = $sthA->fetchrow_array;
			$SIXhour_total = ($SIXhour_total + $aryA[1]);
			$print_ctp=0;
			while ($print_ctp < $ctp)
				{
				$temp_status = $aryA[0];
				if ($TFhour_status[$print_ctp] =~ /^$temp_status$/)
					{
					$SIXhour_count[$print_ctp] = $aryA[1];
					}
				$print_ctp++;
				}
			$print_sctp++;
			}
		$sthA->finish();

		$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeONEhourAGO\" group by dialstatus;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$print_sctp=0;
		while ($sthArows > $print_sctp)
			{
			@aryA = $sthA->fetchrow_array;
			$ONEhour_total = ($ONEhour_total + $aryA[1]);
			$print_ctp=0;
			while ($print_ctp < $ctp)
				{
				$temp_status = $aryA[0];
				if ($TFhour_status[$print_ctp] =~ /^$temp_status$/)
					{$ONEhour_count[$print_ctp] = $aryA[1];}
				$print_ctp++;
				}
			$print_sctp++;
			}
		$sthA->finish();

		$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeFIFTEENminutesAGO\" group by dialstatus;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$print_sctp=0;
		while ($sthArows > $print_sctp)
			{
			@aryA = $sthA->fetchrow_array;
			$FTminute_total = ($FTminute_total + $aryA[1]);
			$print_ctp=0;
			while ($print_ctp < $ctp)
				{
				$temp_status = $aryA[0];
				if ($TFhour_status[$print_ctp] =~ /^$temp_status$/)
					{$FTminute_count[$print_ctp] = $aryA[1];}
				$print_ctp++;
				}
			$print_sctp++;
			}
		$sthA->finish();

		$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeFIVEminutesAGO\" group by dialstatus;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$print_sctp=0;
		while ($sthArows > $print_sctp)
			{
			@aryA = $sthA->fetchrow_array;
			$FIVEminute_total = ($FIVEminute_total + $aryA[1]);
			$print_ctp=0;
			while ($print_ctp < $ctp)
				{
				$temp_status = $aryA[0];
				if ($TFhour_status[$print_ctp] =~ /^$temp_status$/)
					{$FIVEminute_count[$print_ctp] = $aryA[1];}
				$print_ctp++;
				}
			$print_sctp++;
			}
		$sthA->finish();

		$stmtA="SELECT dialstatus,count(*) from vicidial_carrier_log where call_date >= \"$timeONEminuteAGO\" group by dialstatus;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$print_sctp=0;
		while ($sthArows > $print_sctp)
			{
			@aryA = $sthA->fetchrow_array;
			$ONEminute_total = ($ONEminute_total + $aryA[1]);
			$print_ctp=0;
			while ($print_ctp < $ctp)
				{
				$temp_status = $aryA[0];
				if ($TFhour_status[$print_ctp] =~ /^$temp_status$/)
					{$ONEminute_count[$print_ctp] = $aryA[1];}
				$print_ctp++;
				}
			$print_sctp++;
			}
		$sthA->finish();

		$print_ctp=0;
		while ($print_ctp < $ctp)
			{
			if (length($TFhour_count[$print_ctp])<1) {$TFhour_count[$print_ctp]=0;}
			if (length($SIXhour_count[$print_ctp])<1) {$SIXhour_count[$print_ctp]=0;}
			if (length($ONEhour_count[$print_ctp])<1) {$ONEhour_count[$print_ctp]=0;}
			if (length($FTminute_count[$print_ctp])<1) {$FTminute_count[$print_ctp]=0;}
			if (length($FIVEminute_count[$print_ctp])<1) {$FIVEminute_count[$print_ctp]=0;}
			if (length($ONEminute_count[$print_ctp])<1) {$ONEminute_count[$print_ctp]=0;}

			$dividend=$TFhour_count[$print_ctp]; $divisor=$TFhour_total;	$TFhour_prw = &MathZDC;
			$dividend=$SIXhour_count[$print_ctp]; $divisor=$SIXhour_total;	$SIXhour_prw = &MathZDC;
			$dividend=$ONEhour_count[$print_ctp]; $divisor=$ONEhour_total;	$ONEhour_prw = &MathZDC;
			$dividend=$FTminute_count[$print_ctp]; $divisor=$FTminute_total;	$TFminute_prw = &MathZDC;
			$dividend=$FIVEminute_count[$print_ctp]; $divisor=$FIVEminute_total;	$FIVEminute_prw = &MathZDC;
			$dividend=$ONEminute_count[$print_ctp]; $divisor=$ONEminute_total;	$ONEminute_prw = &MathZDC;

			$TFhour_pct = (100 * $TFhour_prw);
			$SIXhour_pct = (100 * $SIXhour_prw);
			$ONEhour_pct = (100 * $ONEhour_prw);
			$TFminute_pct = (100 * $TFminute_prw);
			$FIVEminute_pct = (100 * $FIVEminute_prw);
			$ONEminute_pct = (100 * $ONEminute_prw);

		#	if ($DBX) 
		#		{
		#		print "$TFhour_prw  | ($TFhour_count[$print_ctp], $TFhour_total)\n";
		#		print "$SIXhour_prw  | ($SIXhour_count[$print_ctp], $SIXhour_total)\n";
		#		print "$ONEhour_prw  | ($ONEhour_count[$print_ctp], $ONEhour_total)\n";
		#		print "$TFminute_prw  | ($FTminute_count[$print_ctp], $FTminute_total)\n";
		#		print "$FIVEminute_prw  | ($FIVEminute_count[$print_ctp], $FIVEminute_total)\n";
		#		print "$ONEminute_prw  | ($ONEminute_count[$print_ctp], $ONEminute_total)\n";
		#		}

			$CARRIERstatsHTML .= "<TR>";
			$CARRIERstatsHTML .= "<TD BGCOLOR=white><font size=1 face='helvetica'>&nbsp;</TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=LEFT><font size=1 face='helvetica'>&nbsp; &nbsp; $TFhour_status[$print_ctp] </TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $TFhour_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $TFhour_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $SIXhour_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $SIXhour_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $ONEhour_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $ONEhour_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $FTminute_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $TFminute_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $FIVEminute_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $FIVEminute_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'> $ONEminute_count[$print_ctp] </font>&nbsp;<font size=1 color='#990000' face='helvetica'>".sprintf("%01.1f", $ONEminute_pct)."%</font></TD>";
			$CARRIERstatsHTML .= "</TR>";
			$print_ctp++;
			}
		$CARRIERstatsHTML .= "<TR>";
		$CARRIERstatsHTML .= "<TD BGCOLOR=white><font size=1 face='helvetica'>generated: $timeNOW</TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=LEFT><font size=1 face='helvetica'><B>&nbsp; &nbsp; TOTALS</B></TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($TFhour_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($SIXhour_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($ONEhour_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($FTminute_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($FIVEminute_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "<TD BGCOLOR='#E6E6E6' ALIGN=CENTER><font size=1 face='helvetica'><B> ".($ONEminute_total+0)."</B> </TD>";
		$CARRIERstatsHTML .= "</TR>";
		}
	else
		{
		$CARRIERstatsHTML .= "<TR><TD BGCOLOR=white colspan=7><font size=1 face='helvetica'>no carrier log entries in last 24 hours</TD></TR>";
		}
	$CARRIERstatsHTML .= "</TABLE>";
	$CARRIERstatsHTML .= "</TD></TR>";

	$stmtA="INSERT IGNORE INTO vicidial_html_cache_stats SET stats_type='carrier_stats',stats_id='ALL',stats_date=NOW(),stats_count='$TFhour_total',stats_html=\"$CARRIERstatsHTML\" ON DUPLICATE KEY UPDATE stats_date=NOW(),stats_count='$TFhour_total',stats_html=\"$CARRIERstatsHTML\";";
	$affected_rows = $dbhA->do($stmtA);
	if ($DB) {print "CARRIER STATS INSERT/UPDATE    TOTAL|$affected_rows|$stmtA|\n";}
	################################################################################
	#### END gather carrier stats for real-time report
	################################################################################
	}

sub launch_inbound_gather
	{
	################################################################################
	#### BEGIN gather stats for inbound groups for the real-time display
	################################################################################
	$stmtA = "SELECT group_id from vicidial_inbound_groups where active='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$ibg_count=0;
	while ($sthArows > $ibg_count)
		{
		@aryA = $sthA->fetchrow_array;
		$group_id[$ibg_count] =		$aryA[0];
		$ibg_count++;
		}
	$sthA->finish();
	if ($DB) {print "$now_date INBOUND GROUPS TO GET STATS FOR:  $ibg_count|$#group_id       IT: $master_loop\n";}


	##### LOOP THROUGH EACH INBOUND GROUP AND GATHER STATS #####
	$p=0;
	foreach(@group_id)
		{
		&calculate_drops_inbound;

		$p++;
		}

	################################################################################
	#### END gather stats for inbound groups for the real-time display
	################################################################################
	}



sub calculate_drops_inbound
	{
	$debug_ingroup_output='';
	$answer_sec_pct_rt_stat_one = '20';
	$answer_sec_pct_rt_stat_two = '30';
	# GET inbound group hold stat seconds settings
	$stmtA = "SELECT answer_sec_pct_rt_stat_one,answer_sec_pct_rt_stat_two from vicidial_inbound_groups where group_id='$group_id[$p]';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$answer_sec_pct_rt_stat_one = $aryA[0];
		$answer_sec_pct_rt_stat_two = $aryA[1];
		}
	$sthA->finish();

	$camp_ANS_STAT_SQL='';
	# GET LIST OF HUMAN-ANSWERED STATUSES
	$stmtA = "SELECT status from vicidial_statuses where human_answered='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_ANS_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();

	$stmtA = "SELECT distinct(status) from vicidial_campaign_statuses where human_answered='Y';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$camp_ANS_STAT_SQL .=	 "'$aryA[0]',";
		$rec_count++;
		}
	$sthA->finish();
	chop($camp_ANS_STAT_SQL);
	if (length($camp_ANS_STAT_SQL)<2) 
		{$camp_ANS_STAT_SQL="'-NONE-'";}

	if ($DBX) {print "     ANSWERED STATUSES: $group_id[$p]|$camp_ANS_STAT_SQL|\n";}
	$debug_ingroup_output .= "     ANSWERED STATUSES: $group_id[$p]|$camp_ANS_STAT_SQL|\n";

	#$RESETdrop_count_updater++;
	$iVCScalls_today[$p]=0;
	$iVCSanswers_today[$p]=0;
	$iVCSdrops_today[$p]=0;
	$iVCSdrops_today_pct[$p]=0;
	$iVCSdrops_answers_today_pct[$p]=0;
	$answer_sec_pct_rt_stat_one_PCT[$p]=0;
	$answer_sec_pct_rt_stat_two_PCT[$p]=0;
	$hold_sec_answer_calls[$p]=0;
	$hold_sec_drop_calls[$p]=0;
	$hold_sec_queue_calls[$p]=0;
	$iVCSlive_calls[$p]=0;
	$itotal_agents[$p]=0;
	$itotal_remote_agents[$p]=0;

	# DAILY STATS UPDATE
	if ($daily_stats > 0)
		{
		$stmtA = "SELECT count(*) from vicidial_auto_calls where campaign_id='$group_id[$p]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$iVCSlive_calls[$p] =	$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_live_agents where closer_campaigns LIKE \"% $group_id[$p] %\" and last_update_time > '$VDL_one';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$itotal_agents[$p] =	$aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from vicidial_live_agents where closer_campaigns LIKE \"% $group_id[$p] %\" and last_update_time > '$VDL_one' and extension LIKE \"R/%\";";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$itotal_remote_agents[$p] =	$aryA[0];
			}
		$sthA->finish();
		$debug_ingroup_output .= "     DAILY STATS|$iVCSlive_calls[$p]|$itotal_agents[$p]|$itotal_remote_agents[$p]|";
		}

	# TODAY CALL AND DROP STATS
	$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$iVCScalls_today[$p] =	$aryA[0];
		}
	$sthA->finish();

	if ($iVCScalls_today[$p] > 0)
		{
		# TODAY ANSWERS
		$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and status NOT IN('DROP','XDROP','HXFER','QVMAIL','HOLDTO','LIVE','QUEUE','TIMEOT','AFTHRS','NANQUE','INBND','MAXCAL');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$iVCSanswers_today[$p] =	$aryA[0];
			}
		$sthA->finish();

		# TODAY DROPS
		$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($DBX > 0) {print "$stmtA\n";}
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$iVCSdrops_today[$p] =	$aryA[0];
			if ($iVCSdrops_today[$p] > 0)
				{
				$iVCSdrops_today_pct[$p] = ( ($iVCSdrops_today[$p] / $iVCScalls_today[$p]) * 100 );
				$iVCSdrops_today_pct[$p] = sprintf("%.2f", $iVCSdrops_today_pct[$p]);
				if ($iVCSanswers_today[$p] < 1) {$iVCSanswers_today[$p] = 1;}
				$iVCSdrops_answers_today_pct[$p] = ( ($iVCSdrops_today[$p] / $iVCSanswers_today[$p]) * 100 );
				$iVCSdrops_answers_today_pct[$p] = sprintf("%.2f", $iVCSdrops_answers_today_pct[$p]);
				}
			}
		$sthA->finish();

		# TODAY ANSWER PERCENT OF HOLD SECONDS one and two
		$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and queue_seconds <= $answer_sec_pct_rt_stat_one and status NOT IN('DROP','XDROP','HXFER','QVMAIL','HOLDTO','LIVE','QUEUE','TIMEOT','AFTHRS','NANQUE','INBND','MAXCAL');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$answer_sec_pct_rt_stat_one_PCT[$p] = $aryA[0];
			}
		$sthA->finish();

		$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and queue_seconds <= $answer_sec_pct_rt_stat_two and status NOT IN('DROP','XDROP','HXFER','QVMAIL','HOLDTO','LIVE','QUEUE','TIMEOT','AFTHRS','NANQUE','INBND','MAXCAL');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$answer_sec_pct_rt_stat_two_PCT[$p] = $aryA[0];
			}
		$sthA->finish();

		# TODAY TOTAL HOLD TIME FOR ANSWERED CALLS
		$stmtA = "SELECT sum(queue_seconds) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and status NOT IN('DROP','XDROP','HXFER','QVMAIL','HOLDTO','LIVE','QUEUE','TIMEOT','AFTHRS','NANQUE','INBND','MAXCAL');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			if ($aryA[0] > 0)
				{$hold_sec_answer_calls[$p] = $aryA[0];}
			}
		$sthA->finish();

		# TODAY TOTAL HOLD TIME FOR DROP CALLS
		$stmtA = "SELECT sum(queue_seconds) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and status IN('DROP','XDROP');";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			if ($aryA[0] > 0)
				{$hold_sec_drop_calls[$p] = $aryA[0];}
			}
		$sthA->finish();

		# TODAY TOTAL QUEUE TIME FOR QUEUE CALLS
		$stmtA = "SELECT sum(queue_seconds) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			if ($aryA[0] > 0)
				{$hold_sec_queue_calls[$p] = $aryA[0];}
			}
		$sthA->finish();
		}



	# DETERMINE WHETHER TO GATHER STATUS CATEGORY STATISTICS
	$VSC_categories=0;
	$VSCupdateSQL='';
	$stmtA = "SELECT vsc_id from vicidial_status_categories where tovdad_display='Y' limit 4;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$VSC_categories[$rec_count] =	$aryA[0];
		$rec_count++;
		}
	$sthA->finish();

	$g=0;
	foreach (@VSC_categories)
		{
		$VSCcategory=$VSC_categories[$g];
		$VSCtally='';
		$CATstatusesSQL='';
		# FIND STATUSES IN STATUS CATEGORY
		$stmtA = "SELECT status from vicidial_statuses where category='$VSCcategory';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$rec_count=0;
		while ($sthArows > $rec_count)
			{
			@aryA = $sthA->fetchrow_array;
			$CATstatusesSQL .=		 "'$aryA[0]',";
			$rec_count++;
			}
		$sthA->finish();

		# FIND CAMPAIGN_STATUSES IN STATUS CATEGORY
		$stmtA = "SELECT status from vicidial_campaign_statuses where category='$VSCcategory';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$rec_count=0;
		while ($sthArows > $rec_count)
			{
			@aryA = $sthA->fetchrow_array;
			$CATstatusesSQL .=		 "'$aryA[0]',";
			$rec_count++;
			}
		$sthA->finish();

		chop($CATstatusesSQL);
		if (length($CATstatusesSQL)>2)
			{
			# FIND STATUSES IN STATUS CATEGORY
			$stmtA = "SELECT count(*) from $vicidial_closer_log where campaign_id='$group_id[$p]' and call_date > '$VDL_date' and status IN($CATstatusesSQL);";
			#	if ($DBX) {print "|$stmtA|\n";}
			$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
			$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
			$sthArows=$sthA->rows;
			if ($sthArows > 0)
				{
				@aryA = $sthA->fetchrow_array;
				$VSCtally =		$aryA[0];
				}
			$sthA->finish();
			}
		$g++;
		if ($DBX) {print "     $group_id[$p]|$VSCcategory|$VSCtally|$CATstatusesSQL|\n";}
		$VSCupdateSQL .= "status_category_$g='$VSCcategory',status_category_count_$g='$VSCtally',";
		$debug_ingroup_output .= "     $group_id[$p]|$VSCcategory|$VSCtally|$CATstatusesSQL|";
		}
	while ($g < 4)
		{
		$g++;
		$VSCupdateSQL .= "status_category_$g='',status_category_count_$g='0',";
		}
	chop($VSCupdateSQL);

	$vcs_exists=1;
	$stmtA = "SELECT count(*) from vicidial_campaign_stats where campaign_id='$group_id[$p]';";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	if ($sthArows > 0)
		{
		@aryA = $sthA->fetchrow_array;
		$vcs_exists =		 $aryA[0];
		}
	$sthA->finish();

	if ($vcs_exists < 1)
		{
		$stmtA = "INSERT INTO vicidial_campaign_stats (campaign_id) values('$group_id[$p]');";
		$affected_rows = $dbhA->do($stmtA);
		if ($DBX) {print "$group_id[$p]|$stmtA|\n";}
		}

	$stmtA = "UPDATE vicidial_campaign_stats SET calls_today='$iVCScalls_today[$p]',answers_today='$iVCSanswers_today[$p]',drops_today='$iVCSdrops_today[$p]',drops_today_pct='$iVCSdrops_today_pct[$p]',drops_answers_today_pct='$iVCSdrops_answers_today_pct[$p]',hold_sec_stat_one='$answer_sec_pct_rt_stat_one_PCT[$p]',hold_sec_stat_two='$answer_sec_pct_rt_stat_two_PCT[$p]',hold_sec_answer_calls='$hold_sec_answer_calls[$p]',hold_sec_drop_calls='$hold_sec_drop_calls[$p]',hold_sec_queue_calls='$hold_sec_queue_calls[$p]',$VSCupdateSQL where campaign_id='$group_id[$p]';";
	$affected_rows = $dbhA->do($stmtA);
	if ($DBX) {print "INBOUND $group_id[$p]|$affected_rows|$stmtA|\n";}

	print "$p         IN-GROUP: $group_id[$p]   CALLS: $iVCScalls_today[$p]   ANSWER: $iVCSanswers_today[$p]   DROPS: $iVCSdrops_today[$p]\n";
	print "               Stat1: $answer_sec_pct_rt_stat_one_PCT[$p]   Stat2: $answer_sec_pct_rt_stat_two_PCT[$p]   Hold: $hold_sec_queue_calls[$p]|$hold_sec_answer_calls[$p]|$hold_sec_drop_calls[$p]\n";
	$debug_ingroup_output .= "$p         IN-GROUP: $group_id[$p]   CALLS: $iVCScalls_today[$p]   ANSWER: $iVCSanswers_today[$p]   DROPS: $iVCSdrops_today[$p]\n";
	$debug_ingroup_output .= "               Stat1: $answer_sec_pct_rt_stat_one_PCT[$p]   Stat2: $answer_sec_pct_rt_stat_two_PCT[$p]   Hold: $hold_sec_queue_calls[$p]|$hold_sec_answer_calls[$p]|$hold_sec_drop_calls[$p]\n";

	$debug_ingroup_output =~ s/;|\\\\|\/|\'//gi;
	$stmtA="INSERT IGNORE INTO vicidial_campaign_stats_debug SET server_ip='INBOUND',campaign_id='$group_id[$p]',entry_time='$now_date',debug_output='$debug_ingroup_output' ON DUPLICATE KEY UPDATE entry_time='$now_date',debug_output='$debug_ingroup_output';";
	$affected_rows = $dbhA->do($stmtA);

	##### BEGIN - DAILY STATS UPDATE INGROUP
	if ($daily_stats > 0)
		{
		$STATSmax_inbound=0;
		$STATSmax_agents=0;
		$STATSmax_remote_agents=0;
		$STATStotal_calls=0;
		$stmtA = "SELECT max_inbound,max_agents,max_remote_agents,total_calls from vicidial_daily_max_stats where campaign_id='$group_id[$p]' and stats_type='INGROUP' and stats_flag='OPEN' order by update_time desc limit 1;";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		if ($sthArows > 0)
			{
			@aryA = $sthA->fetchrow_array;
			$STATSmax_inbound =			$aryA[0];
			$STATSmax_agents =			$aryA[1];
			$STATSmax_remote_agents =	$aryA[2];
			$STATStotal_calls =			$aryA[3];
			$sthA->finish();

			$update_SQL='';
			if ($STATSmax_inbound < $iVCSlive_calls[$p]) 
				{$update_SQL .= ",max_inbound='$iVCSlive_calls[$p]'";}
			if ($STATSmax_agents < $itotal_agents[$p]) 
				{$update_SQL .= ",max_agents='$itotal_agents[$p]'";}
			if ($STATSmax_remote_agents < $itotal_remote_agents[$p])
				{$update_SQL .= ",max_remote_agents='$itotal_remote_agents[$p]'";}
			if ($STATStotal_calls < $iVCScalls_today[$p]) 
				{$update_SQL .= ",total_calls='$iVCScalls_today[$p]'";}
			if (length($update_SQL) > 5) 
				{
				$stmtA = "UPDATE vicidial_daily_max_stats SET update_time=NOW()$update_SQL where campaign_id='$group_id[$p]' and stats_type='INGROUP' and stats_flag='OPEN';";
				$affected_rows = $dbhA->do($stmtA);
				if ($DBX) {print "DAILY STATS UPDATE $campaign_id[$p]|$affected_rows|$stmtA|\n";}
				}
			}
		else
			{
			$sthA->finish();

			$stmtA = "INSERT INTO vicidial_daily_max_stats SET stats_date='$file_date',update_time=NOW(),max_inbound='$iVCSlive_calls[$p]',max_agents='$itotal_agents[$p]',max_remote_agents='$itotal_remote_agents[$p]',total_calls='$iVCScalls_today[$p]',campaign_id='$group_id[$p]',stats_type='INGROUP',stats_flag='OPEN';";
			$affected_rows = $dbhA->do($stmtA);
			if ($DBX) {print "DAILY STATS INSERT $group_id[$p]|$affected_rows|$stmtA|\n";}
			}
		}
	##### END - DAILY STATS UPDATE INGROUP
	}
##### END calculate_drops_inbound



##### BEGIN calculate the proper dial level #####
sub calculate_dial_level
	{
	$RESETdiff_ratio_updater++;
	$VCSINCALL[$i]=0;
	$VCSREADY[$i]=0;
	$VCSCLOSER[$i]=0;
	$VCSPAUSED[$i]=0;
	$VCSagents[$i]=0;
	$VCSagents_calc[$i]=0;
	$VCSagents_active[$i]=0;

	$adaptive_string  = "\n";
	$adaptive_string .= "CAMPAIGN:   $campaign_id[$i]     $i\n";

	# COUNTS OF STATUSES OF AGENTS IN THIS CAMPAIGN
	$stmtA = "SELECT count(*),status from vicidial_live_agents where campaign_id='$campaign_id[$i]' and last_update_time > '$VDL_one' group by status;";
	$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
	$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
	$sthArows=$sthA->rows;
	$rec_count=0;
	while ($sthArows > $rec_count)
		{
		@aryA = $sthA->fetchrow_array;
		$VCSagent_count[$i] =	$aryA[0];
		$VCSagent_status[$i] =	$aryA[1];
		$rec_count++;
		if ($VCSagent_status[$i] =~ /INCALL|QUEUE/) {$VCSINCALL[$i] = ($VCSINCALL[$i] + $VCSagent_count[$i]);}
		if ($VCSagent_status[$i] =~ /READY/) {$VCSREADY[$i] = ($VCSREADY[$i] + $VCSagent_count[$i]);}
		if ($VCSagent_status[$i] =~ /CLOSER/) {$VCSCLOSER[$i] = ($VCSCLOSER[$i] + $VCSagent_count[$i]);}
		if ($VCSagent_status[$i] =~ /PAUSED/) {$VCSPAUSED[$i] = ($VCSPAUSED[$i] + $VCSagent_count[$i]);}
		$VCSagents[$i] = ($VCSagents[$i] + $VCSagent_count[$i]);
		}
	$sthA->finish();

	if ($available_only_ratio_tally[$i] =~ /Y/) 
		{$VCSagents_calc[$i] = $VCSREADY[$i];}
	else
		{
		$VCSagents_calc[$i] = ($VCSINCALL[$i] + $VCSREADY[$i]);
		if ( ($available_only_tally_threshold[$i] =~ /LOGGED-IN_AGENTS/) && ($available_only_tally_threshold_agents[$i] > $VCSagents[$i]) )
			{
			$adaptive_string .= "   !! AVAILABLE ONLY TALLY THRESHOLD triggered for LOGGED-IN_AGENTS: ($available_only_tally_threshold_agents[$i] > $VCSagents[$i])\n";
			$VCSagents_calc[$i] = $VCSREADY[$i];
			$available_only_ratio_tally[$i] = 'Y*';
			}
		if ( ($available_only_tally_threshold[$i] =~ /NON-PAUSED_AGENTS/) && ($available_only_tally_threshold_agents[$i] > $VCSagents_calc[$i]) )
			{
			$adaptive_string .= "   !! AVAILABLE ONLY TALLY THRESHOLD triggered for NON-PAUSED_AGENTS: ($available_only_tally_threshold_agents[$i] > $VCSagents_calc[$i])\n";
			$VCSagents_calc[$i] = $VCSREADY[$i];
			$available_only_ratio_tally[$i] = 'Y*';
			}
		if ( ($available_only_tally_threshold[$i] =~ /WAITING_AGENTS/) && ($available_only_tally_threshold_agents[$i] > $VCSREADY[$i]) )
			{
			$adaptive_string .= "   !! AVAILABLE ONLY TALLY THRESHOLD triggered for WAITING_AGENTS: ($available_only_tally_threshold_agents[$i] > $VCSREADY[$i])\n";
			$VCSagents_calc[$i] = $VCSREADY[$i];
			$available_only_ratio_tally[$i] = 'Y*';
			}
		}
	$VCSagents_active[$i] = ($VCSINCALL[$i] + $VCSREADY[$i] + $VCSCLOSER[$i]);
	### END - GATHER STATS FOR THE vicidial_campaign_stats TABLE ###

	if ($campaign_allow_inbound[$i] =~ /Y/)
		{
		# GET AVERAGES FROM THIS CAMPAIGN
		$stmtA = "SELECT differential_onemin,agents_average_onemin from vicidial_campaign_stats where campaign_id='$campaign_id[$i]';";
		$sthA = $dbhA->prepare($stmtA) or die "preparing: ",$dbhA->errstr;
		$sthA->execute or die "executing: $stmtA ", $dbhA->errstr;
		$sthArows=$sthA->rows;
		$rec_count=0;
		while ($sthArows > $rec_count)
			{
			@aryA = $sthA->fetchrow_array;
			$differential_onemin[$i] =		$aryA[0];
			$agents_average_onemin[$i] =	$aryA[1];
			$rec_count++;
			}
		$sthA->finish();
		}
	else
		{
		$agents_average_onemin[$i] =	$total_agents_avg[$i];  
		$differential_onemin[$i] =		$stat_differential[$i];
		}

	if ( ($dial_method[$i] =~ /ADAPT_HARD_LIMIT|ADAPT_AVERAGE|ADAPT_TAPERED/) || ($force_test>0) )
		{
		# Calculate the optimal dial_level differential for the past minute
		$differential_target[$i] = ($differential_onemin[$i] + $adaptive_dl_diff_target[$i]);
		if ( ($differential_target[$i] != 0) && ($agents_average_onemin[$i] != 0) )
			{
			$differential_mul[$i] = ($differential_target[$i] / $agents_average_onemin[$i]);
			$differential_pct_raw[$i] = ($differential_mul[$i] * 100);
			}
		else
			{
			$differential_mul[$i] = 0;
			$differential_pct_raw[$i] = 0;
			}
		$differential_pct[$i] = sprintf("%.2f", $differential_pct_raw[$i]);

		# Factor in the intensity setting
		$intensity_mul[$i] = ($adaptive_intensity[$i] / 100);
		if ($differential_pct_raw[$i] < 0)
			{
			$abs_intensity_mul[$i] = abs($intensity_mul[$i] - 1);
			$intensity_diff[$i] = ($differential_pct_raw[$i] * $abs_intensity_mul[$i]);
			}
		else
			{$intensity_diff[$i] = ($differential_pct_raw[$i] * ($intensity_mul[$i] + 1) );}
		$intensity_pct[$i] = sprintf("%.2f", $intensity_diff[$i]);	
		$intensity_diff_mul[$i] = ($intensity_diff[$i] / 100);

		# Suggested dial_level based on differential
		$suggested_dial_level[$i] = ($auto_dial_level[$i] * ($differential_mul[$i] + 1) );
		$suggested_dial_level[$i] = sprintf("%.3f", $suggested_dial_level[$i]);

		# Suggested dial_level based on differential with intensity setting
		$intensity_dial_level[$i] = ($auto_dial_level[$i] * ($intensity_diff_mul[$i] + 1) );
		$intensity_dial_level[$i] = sprintf("%.3f", $intensity_dial_level[$i]);

		# Calculate last timezone target for ADAPT_TAPERED
		$last_target_hour_final[$i] = $adaptive_latest_server_time[$i];
	#	if ($last_target_hour_final[$i]>2400) {$last_target_hour_final[$i]=2400;}
		$tapered_hours_left[$i] = ($last_target_hour_final[$i] - $current_hourmin);
		if ($tapered_hours_left[$i] > 1000)
			{$tapered_rate[$i] = 1;}
		else
			{$tapered_rate[$i] = ($tapered_hours_left[$i] / 1000);}

		$adaptive_string .= "SETTINGS-\n";
		$adaptive_string .= "   DIAL LEVEL:    $auto_dial_level[$i]\n";
		$adaptive_string .= "   DIAL METHOD:   $dial_method[$i]\n";
		$adaptive_string .= "   AVAIL ONLY:    $available_only_ratio_tally[$i]\n";
		$adaptive_string .= "   DROP PERCENT:  $adaptive_dropped_percentage[$i]\n";
		$adaptive_string .= "   MAX LEVEL:     $adaptive_maximum_level[$i]\n";
		$adaptive_string .= "   SERVER TIME:   $current_hourmin\n";
		$adaptive_string .= "   LATE TARGET:   $last_target_hour_final[$i]     ($tapered_hours_left[$i] left|$tapered_rate[$i])\n";
		$adaptive_string .= "   INTENSITY:     $adaptive_intensity[$i]\n";
		$adaptive_string .= "   DLDIFF TARGET: $adaptive_dl_diff_target[$i]\n";
		$adaptive_string .= "CURRENT STATS-\n";
		$adaptive_string .= "   AVG AGENTS:      $agents_average_onemin[$i]\n";
		$adaptive_string .= "   AGENTS:          $VCSagents[$i]  ACTIVE: $VCSagents_active[$i]   CALC: $VCSagents_calc[$i]  INCALL: $VCSINCALL[$i]    READY: $VCSREADY[$i]\n";
		$adaptive_string .= "   DL DIFFERENTIAL: $differential_target[$i] = ($differential_onemin[$i] + $adaptive_dl_diff_target[$i])\n";
		$adaptive_string .= "DIAL LEVEL SUGGESTION-\n";
		$adaptive_string .= "      PERCENT DIFF: $differential_pct[$i]\n";
		$adaptive_string .= "      SUGGEST DL:   $suggested_dial_level[$i] = ($auto_dial_level[$i] * ($differential_mul[$i] + 1) )\n";
		$adaptive_string .= "      INTENSE DIFF: $intensity_pct[$i]\n";
		$adaptive_string .= "      INTENSE DL:   $intensity_dial_level[$i] = ($auto_dial_level[$i] * ($intensity_diff_mul[$i] + 1) )\n";
		if ($intensity_dial_level[$i] > $adaptive_maximum_level[$i])
			{
			$adaptive_string .= "      DIAL LEVEL OVER CAP! SETTING TO CAP: $adaptive_maximum_level[$i]\n";
			$intensity_dial_level[$i] = $adaptive_maximum_level[$i];
			}
		if ($intensity_dial_level[$i] < 1)
			{
			$adaptive_string .= "      DIAL LEVEL TOO LOW! SETTING TO 1\n";
			$intensity_dial_level[$i] = "1.0";
			}
		$adaptive_string .= "DROP STATS-\n";
		$adaptive_string .= "   TODAY DROPS:     $VCScalls_today[$i]   $VCSdrops_today[$i]   $VCSdrops_today_pct[$i]%\n";
		$adaptive_string .= "     ANSWER DROPS:     $VCSanswers_today[$i]   $VCSdrops_answers_today_pct[$i]%\n";
		$adaptive_string .= "   ONE HOUR DROPS:  $VCScalls_hour[$i]/$VCSanswers_hour[$i]   $VCSdrops_hour[$i]   $VCSdrops_hour_pct[$i]%\n";
		$adaptive_string .= "   HALF HOUR DROPS: $VCScalls_halfhour[$i]/$VCSanswers_halfhour[$i]   $VCSdrops_halfhour[$i]   $VCSdrops_halfhour_pct[$i]%\n";
		$adaptive_string .= "   FIVE MIN DROPS:  $VCScalls_five[$i]/$VCSanswers_five[$i]   $VCSdrops_five[$i]   $VCSdrops_five_pct[$i]%\n";
		$adaptive_string .= "   ONE MIN DROPS:   $VCScalls_one[$i]/$VCSanswers_one[$i]   $VCSdrops_one[$i]   $VCSdrops_one_pct[$i]%\n";

		### DROP PERCENTAGE RULES TO LOWER DIAL_LEVEL ###
		if ( ($VCScalls_one[$i] > 20) && ($VCSdrops_one_pct[$i] > 50) )
			{
			$intensity_dial_level[$i] = ($intensity_dial_level[$i] / 2);
			$adaptive_string .= "      DROP RATE OVER 50% FOR LAST MINUTE! CUTTING DIAL LEVEL TO: $intensity_dial_level[$i]\n";
			}
		if ( ($VCScalls_today[$i] > 50) && ($VCSdrops_answers_today_pct[$i] > $adaptive_dropped_percentage[$i]) )
			{
			if ($dial_method[$i] =~ /ADAPT_HARD_LIMIT/) 
				{
				$intensity_dial_level[$i] = "1.0";
				$adaptive_string .= "      DROP RATE OVER HARD LIMIT FOR TODAY! HARD DIAL LEVEL TO: 1.0\n";
				}
			if ($dial_method[$i] =~ /ADAPT_AVERAGE/) 
				{
				$intensity_dial_level[$i] = ($intensity_dial_level[$i] / 2);
				$adaptive_string .= "      DROP RATE OVER LIMIT FOR TODAY! AVERAGING DIAL LEVEL TO: $intensity_dial_level[$i]\n";
				}
			if ($dial_method[$i] =~ /ADAPT_TAPERED/) 
				{
				if ($tapered_hours_left[$i] < 0) 
					{
					$intensity_dial_level[$i] = "1.0";
					$adaptive_string .= "      DROP RATE OVER LAST HOUR LIMIT FOR TODAY! TAPERING DIAL LEVEL TO: 1.0\n";
					}
				else
					{
					$intensity_dial_level[$i] = ($intensity_dial_level[$i] * $tapered_rate[$i]);
					$adaptive_string .= "      DROP RATE OVER LIMIT FOR TODAY! TAPERING DIAL LEVEL TO: $intensity_dial_level[$i]\n";
					}
				}
			}

		### BEGIN Dial Level Threshold Check ###
		$VCSagents_nonpaused_temp = ($VCSINCALL[$i] + $VCSREADY[$i]);
		if ( ($dial_level_threshold[$i] =~ /LOGGED-IN_AGENTS/) && ($dial_level_threshold_agents[$i] > $VCSagents[$i]) )
			{
			$adaptive_string .= "   !! DIAL LEVEL THRESHOLD triggered for LOGGED-IN_AGENTS: ($dial_level_threshold_agents[$i] > $VCSagents[$i])\n";
			$intensity_dial_level[$i] = "1.0";
			}
		if ( ($dial_level_threshold[$i] =~ /NON-PAUSED_AGENTS/) && ($dial_level_threshold_agents[$i] > $VCSagents_nonpaused_temp) )
			{
			$adaptive_string .= "   !! DIAL LEVEL THRESHOLD triggered for NON-PAUSED_AGENTS: ($dial_level_threshold_agents[$i] > $VCSagents_nonpaused_temp)\n";
			$intensity_dial_level[$i] = "1.0";
			}
		if ( ($dial_level_threshold[$i] =~ /WAITING_AGENTS/) && ($dial_level_threshold_agents[$i] > $VCSREADY[$i]) )
			{
			$adaptive_string .= "   !! DIAL LEVEL THRESHOLD triggered for WAITING_AGENTS: ($dial_level_threshold_agents[$i] > $VCSREADY[$i])\n";
			$intensity_dial_level[$i] = "1.0";
			}
		### END Dial Level Threshold Check ###


		### ALWAYS RAISE DIAL_LEVEL TO 1.0 IF IT IS LOWER ###
		if ($intensity_dial_level[$i] < 1)
			{
			$adaptive_string .= "      DIAL LEVEL TOO LOW! SETTING TO 1\n";
			$intensity_dial_level[$i] = "1.0";
			}

		if (!$TEST)
			{
			$stmtA = "UPDATE vicidial_campaigns SET auto_dial_level='$intensity_dial_level[$i]' where campaign_id='$campaign_id[$i]';";
			$Uaffected_rows = $dbhA->do($stmtA);
			}

		$adaptive_string .= "DIAL LEVEL UPDATED TO: $intensity_dial_level[$i]          CONFIRM: $Uaffected_rows\n";
		}

	if ($DB) {print "campaign stats updated:  $campaign_id[$i]   $adaptive_string\n";}

	&adaptive_logger;
	}
##### END calculate the proper dial level #####


##### BEGIN math divisor sub #####
sub MathZDC
	{
	$quotient=0;
#	if ($DBX) {print "MathZDC sub DEBUG:      dividend: $dividend   divisor:  $divisor\n";}

	if ( ($divisor == '0') || (length($divisor) < 1) )
		{
		return $quotient;
		}
	else 
		{
		if ($dividend == '0')
			{
			return 0;
			}
		else 
			{
			$percent = ($dividend/$divisor);
			return $percent;
			}
		}
	}

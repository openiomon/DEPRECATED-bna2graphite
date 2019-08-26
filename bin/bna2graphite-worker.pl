#!/usr/bin/perl
# =============================================================================
#
#  File Name        : bna2graphite.pl
#
#  Project Name     : Brocade Grafana
#
#  Author           : Timo Drach
#
#  Platform         : Linux Perl
#
#  Initially written: 08.05.2017
#
#  Description      : Script for import of performance and error counter of a
#                     Brocade Network Advisor to a graphite backend
#
# ==============================================================================================


use strict;
use warnings;
use lib '/opt/bna2graphite/lib/perl5/';
use POSIX qw(strftime);
use POSIX qw(ceil);
use Time::HiRes qw(nanosleep usleep gettimeofday tv_interval);
use IO::Socket::INET;
use LWP::UserAgent;
use constant false => 0;
use constant true  => 1;
use Log::Log4perl;
use Getopt::Long;
use Time::Local;
use JSON;
use Switch;
use Systemd::Daemon qw( -hard notify );

my %args;  # variable to store command line options for use with getopts
my $log; # log4perl logger

# Logfilevariable


my $logfile = "";
my $loglevel = "INFO";
my $conf = "";

# BNA connection variables

my $bnaservername = "";
my $bnashortname = "";
my $bnaurl = "";
my $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });
my %bnaservers;
my $bnauser = "";
my $bnapasswd = "";
my $graphitehost = "127.0.0.1";
my $graphiteport = "2003";

my $scripttime = time;

my $bnatoken = "";

my $metricconffile = '/opt/bna2graphite/conf/metrics.conf';
my $hostmappingfile = '/opt/bna2graphite/conf/hostmapping.conf';
my @logbyport;
my @logbyhost;
my $usewwnasalias = false;
my %hostmapping;

my %fabrickey;
my %switchinfo;
my %switchref;
my %portinfo;
my %wwninfo;
my %allenddevices;
my %plainportinfo;
my %perfstats;
my %switchstats;

my $monitoruport=true;
my $monitorgport=true;

my $socketcnt = 0;
my $sockettimer;
my $maxmetricsperminute = 500000;
my $socketdelay = 10000;
my $delaymetric = 100;
my $socket;

my $pollinterval = 180;

my %metrics;
my %metrics_lookup;

# Service variables

my $daemon = false;
my $runeveryhours = 1;
my $minafterfullhours = 0;
my $statusdir = '/opt/bna2graphite/run/';
my $watchdog = 300;

# maxdelay is set to $watchdogtime in nanoseconds deviced by 1000 since we are sending the alive singnal every 100.000 inserts but the delay is done every 100 inserts. The factor 0.9 adds in some tollerance to avaid watchdog is killing service because delay for inserts is to high! This might happen if the 1st 100.000 inserts are done in less than 2 seconds...
my $maxdelay = ($watchdog*1000*1000*1000)/1000*0.9;

my $lastsuccessfulrun = 0;
my $lastsuccessfulrunend = 0;


sub console{
   	my $message = shift;
	if(!$daemon) {	
    		print $message,"\n";
	}
    	$log->info($message);
}

sub printUsage {
	print("Usage:\n");
	print("$0 [OPTIONS]\n");
    	print("OPTIONS:\n");
    	print("   -conf <file>                  conf file containig parameter for the import\n");
		print("   -bna <BNA fqdn>.              Full qualified domain name of the BNA server\n");
    	print("   -minutes <number of minutes>  Number of minutes that should be imported (between 30 and 1440)\n");
    	print("   -daemon                       Flag which will supress the output to console\n");
    	print("   -h                            print this output\n");
    	print("\n");

}

sub parseCmdArgs{
	my $help = "";
	GetOptions (    "conf=s"                => \$conf,              # String
					"bna=s"					=> \$bnaservername,		# String
                    "minutes=s"             => \$pollinterval,   	# String
					"daemon"				=> \$daemon,			# flag
                    "h"                     => \$help)              # flag
    or die("Error in command line arguments\n");

    # keine Konfigdatei => Script wird beendet.
    if($conf eq "") {
	    printUsage();
      	exit(1);
    } else {
      	# Einlesen der Konfigdatei.
       	readconfig();
    }
    if(($pollinterval<30) || ($pollinterval >1440)) {
      	print ("Invalid nunber of minutes specified: ".$pollinterval."\n\n");
      	printUsage();
       	exit(1);
    }
	
	if($bnaservername=~'^https://') {
		print ("Please specify BNA FDQN and NOT URL!");
		exit(1);
	} else {
		$bnaurl = 'https://'.$bnaservername;
		if(!defined $bnaservers{$bnaservername}) {
			print "BNA server defined as CLI Option is not defined in configuration file. Please check and correct!\n";
			exit(1);
		}
		$bnauser = $bnaservers{$bnaservername}{"user"};
		$bnapasswd = $bnaservers{$bnaservername}{"passwd"};
		if($bnaservername =~ /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/) {
			$bnashortname =~ s/\./_/g;
		} else {
			my @values = split(/\./,$bnaservername);
			$bnashortname = uc($values[0]);
		}
	}	
	if($help) {
		printUsage();
	}
}

sub readconfig {
        # öffnen des Config-Files...
        open my $configfilefp, '<', $conf or die "Can't open file: $!";
        my $section = "";
        while(<$configfilefp>) {
        	my $configline = $_;
        	chomp ($configline);
        	# Überspringen von allen Zeilen welche mit # beginnen oder leer sind.
        	if (($configline !~ "^#") && ($configline ne "")){
        		# bestimmen der Config-File Section
        		if ($configline =~ '\[') {
        			$configline =~ s/\[//g;
        			$configline =~ s/\]//g;
        			$configline =~ s/\s//g;
        			$section = $configline;
        		} else {
        			# Einlesen der Parameter je nach Config-File-Section
        			switch($section) {
					case "BNA" {
                    	my @values = split (";",$configline);
						$bnaservers{$values[0]}{"user"}=$values[1];
						$bnaservers{$values[0]}{"passwd"}=$values[2];
                    }
					case "Log" {
                    	my @values = split ("=",$configline);
                        if($configline=~"logdir") {
						   	$logfile = $values[1];
                          	$logfile =~ s/\s//g;
						    my $lastchar = substr($logfile,-1);
						    if($lastchar ne "\/") {
						        $logfile.="\/";
						    }
                        } elsif ($configline=~"loglevel") {
							my $configloglevel = $values[1];
							$configloglevel=~ s/\s//g;
							if(uc($configloglevel) eq "FATAL") {
								$loglevel = "FATAL";
							} elsif (uc($configloglevel) eq "ERROR") {
								$loglevel = "ERROR";
							} elsif (uc($configloglevel) eq "WARN") {
								$loglevel = "WARN";
							} elsif (uc($configloglevel) eq "INFO") {
								$loglevel = "INFO";
							} elsif (uc($configloglevel) eq "DEBUG") {
								$loglevel = "DEBUG";
							} elsif (uc($configloglevel) eq "TRACE") {
								$loglevel = "TRACE";
							}
							# otherwise keep default which is INFO
						}
					}
					case "graphite" {
                        my @values = split ("=",$configline);
                        if($configline =~ "host") {
                        	$graphitehost = $values[1];
                            $graphitehost =~ s/\s//g;
                        } elsif ($configline =~ "port") {
                          	$graphiteport = $values[1];
                            $graphiteport =~ s/\s//g;
						}
                    }
					case "ports" {
                        my @values = split ("=",$configline);
                       	if($configline =~ "monitor_uports") {
                            if($configline =~ "0") {
                            	$monitoruport = false;
                            }
                        } elsif ($configline =~ "monitor_gports") {
                            if($configline =~ "0") {
                                $monitorgport = false;
							}
						}
					}
					case "performance" {
						my @values = split ("=",$configline);
						if($configline =~ "maxmetricsperminute") {
							$maxmetricsperminute = $values[1];
						}
					}
					case "service" {
						my @values = split ("=",$configline);
						if($configline =~ "runeveryhours") {
							$runeveryhours = $values[1];
						} elsif ($configline =~ "runminutesafterhour") {
							$minafterfullhours = $values[1];
						} elsif ($configline =~ "statusdir") {
							$statusdir = $values[1];
							$statusdir =~ s/\s//g;
						    my $lastchar = substr($statusdir,-1);
						    if($lastchar ne "\/") {
						        $statusdir.="\/";
						    }
						}
					}
					case "metrics" {
						my @values = split("=",$configline);
						if($configline =~ "logbyport") {
							my $logbyportline = $values[1];
							chomp($logbyportline);
							$logbyportline =~ s/\s//g;
							@logbyport = split(",",$logbyportline);
							
						} elsif ($configline =~ "logbyhost") {
							my $logbyhostline = $values[1];
							chomp ($logbyhostline);
							$logbyhostline =~ s/\s//g;
							@logbyhost = split(",",$logbyhostline);
						} elsif ($configline =~ "metricconffile") {
							$metricconffile = $values[1];
							chomp($metricconffile);
							$metricconffile =~ s/\s//g;
						} elsif ($configline =~ "usewwnasalias") {
							$usewwnasalias = $values[1];
							chomp($usewwnasalias);
							$usewwnasalias =~ s/\s//g;
						}
					}
				}
			}
		}
	}
}

sub readmetricfile {
	if(-f $metricconffile) {
		open my $metricfp, '<', $metricconffile or die "Can't open file: $!";
		while(<$metricfp>) {
			my $line = $_;
			if($line !~ "^#") {
				my @linevalues = split(",",$line);
				if(defined($linevalues[0])) {
					my $metric = lc($linevalues[0]);
					$metric =~ s/\s//g;
					if(defined($linevalues[1])) {
						my $entity = lc($linevalues[1]);
						$entity =~ s/\s//g;
						if(defined($linevalues[2])) {
							my $type = lc($linevalues[2]);
							$type =~ s/\s//g;
							$metrics{$entity}{$type}{$metric} = 1;
							$metrics_lookup{$metric}{"entity"} = $entity;
							$metrics_lookup{$metric}{"type"} = $type;
						} else {
							$log->warn("Omitting line of metrics configuration file since metric type is not defined: ".$line." Please check!");
						}
					} else {
						$log->warn("Omitting line of metrics configuration file since metric entity is not defined: ".$line." Please check!");
					}
				} else {
					$log->warn("Omitting line of metrics configuration file since metric is not defined: ".$line." Please check!");
				}
			}
		}
		close($metricfp);
	} else {
		$log->error("Unable to find metrics configuration file with path: ".$metricconffile);
		exit(1);
	}
}

sub readhostmapping {
	%hostmapping = ();
	if(-f $hostmappingfile) {
		open my $mappingfp, '<', $hostmappingfile or die "Can't open file: $!";
		while(<$mappingfp>){
			my $line = $_;
			if($line !~ "^#") {
				chomp($line);
				my $splitchar = ",";
				if($line=~";") {
					$splitchar=";";
				} 
				my @linevalues = split($splitchar,$line);
				if ((scalar @linevalues)<2) {
					$log->warn("Omitting host mapping: ".$line." since it has less than 2 elements! Please check!");
					next;
				} elsif (((scalar @linevalues)<3) && !$usewwnasalias) {
					$log->warn("Omitting host mapping: ".$line." since it has less than 3 elements but but usage of WWNs as alias is disabled! Please check!");
					next;
				}
				my $hostname = $linevalues[0];
				my $wwpn = uc($linevalues[1]);
				if (length($wwpn)==16) {
					my $wellformedwwpn = substr($wwpn,0,2).":".substr($wwpn,2,2).":".substr($wwpn,4,2).":".substr($wwpn,6,2).":".substr($wwpn,8,2).":".substr($wwpn,10,2).":".substr($wwpn,12,2).":".substr($wwpn,14,2);
					$wwpn = $wellformedwwpn;
				}
				my $wwpnalias = "";
				if($usewwnasalias) {
					$wwpnalias = $wwpn;
				} else {
					$wwpnalias = $linevalues[2];
				}
				$hostmapping{$wwpn}{"host"} = $hostname;
				$hostmapping{$wwpn}{"alias"} = $wwpnalias;
				$log->debug("Loaded host mapping: ".$hostname." with WWN: >".$wwpn."< using alias: ".$wwpnalias);
			}
		}
		close($mappingfp);
	} else {
		$log->error("Unable to find hostmapping-file with path: ".$hostmappingfile);
	}
}


sub getbnatoken {
	alive();
	my $bnaloginurl = $bnaurl."/rest/login";
	my $req = HTTP::Request->new(POST => $bnaloginurl);
	$req->header('WSUsername' => $bnauser);
	$req->header('WSPassword' => $bnapasswd);
	$req->header('Accept' => 'application/vnd.brocade.networkadvisor+json;version=v1');
	my $curlcmd = "curl -ks -X POST -H \"WSUsername:".$bnauser."\" -H \"WSPassword:".$bnapasswd."\" -H \"Accept:application/vnd.brocade.networkadvisor+json;version=v1\" -i ".$bnaloginurl;
	$log->debug("For troubleshooting run: ".$curlcmd);
	my $resp = $ua->request($req);
	if ($resp->is_success) {
    	$bnatoken = $resp->header("WStoken");
		$log->info("HTTP(s) Login successful. Token received: ".$bnatoken);
		return($bnatoken);
	} else {
    	$log->error("Failed to login with HTTP POST error code: ".$resp->code);
    	$log->error("Failed to login with HTTP POST error message: ".$resp->message);
		$log->fatal("Exit bna2graphite due to failed login to BNA! Please check URL and credentials");
		exit(1);
	}
}

sub http_get {
	alive();
	my $geturl = $_[0];
	my $req = HTTP::Request->new(GET => $geturl);
	$req->header('WSToken' => $bnatoken);
	$req->header('Accept' => 'application/vnd.brocade.networkadvisor+json;version=v1');
	my $curlcmd = "curl -ks -X GET -H \"WStoken:".$bnatoken."\" -H \"Accept:application/vnd.brocade.networkadvisor+json;version=v1\" -i ".$geturl;
	$log->debug("For troubleshooting run: ".$curlcmd);
	my $resp = $ua->request($req);
	if ($resp->is_success) {
		my $responsecontent = $resp->decoded_content;
       	return($responsecontent);
    } else {
       	$log->error("Failed to GET data from ".$geturl." with HTTP GET error code: ".$resp->code);
        $log->error("Failed to GET data from ".$geturl." with HTTP GET error message: ".$resp->message);
        $log->fatal("Exit bna2graphite due to failed HTTP GET Operation! Please check URL!");
        exit(1);
    }
}

sub getfabrics {
	my $bnafabricurl = $bnaurl."/rest/resourcegroups/All/fcfabrics";
	my $name = "";
	my $fabricwwn = "";
	my $line  = http_get($bnafabricurl);
	if($line =~ "{") {
		my %json = %{decode_json($line)};
		my @fabrics = $json{"fcFabrics"};
		foreach my $fabric (@fabrics) {
			my @testarray = @{$fabric};
			foreach my $teststring (@testarray) {
				my %testhash = %{$teststring};
				foreach my $testkey (keys %testhash) {
					if(defined $testhash{$testkey}) {
						if($testkey eq "name") {
							$name = $testhash{$testkey};
							$name =~ s/\s/_/g;
							$name =~ s/(\)|\()//g;
							$name =~ s/\./_/g;
						} elsif ($testkey eq "key") {
							$fabrickey{$name} = $testhash{$testkey};
							$log->trace("Retrieved Fabric: ".$name." with key: ".$fabrickey{$name});
						}
					}
				}
			}
		}
	}
}

sub getfcswitches {
	foreach my $fabric (sort keys %fabrickey) {
		my $bnaswitchurl = $bnaurl."/rest/resourcegroups/All/fcfabrics/".$fabrickey{$fabric}."/fcswitches";
		my $switchkey = "";
		my $switchname = "";
		my $switchwwn = "";
		my $switchopstate = "";
		my $switchstate = "";
		my $switchstatus = "";
		my $line = http_get($bnaswitchurl);
		if($line =~ "{") {
			my %json = %{decode_json($line)};
			my @switches = $json{"fcSwitches"};
			foreach my $switch (@switches) {
				my @switcharray = @{$switch};
				foreach my $switchelements (@switcharray) {
					my %switchhash = %{$switchelements};
					foreach my $switchattribute (keys %switchhash) {
						if(defined $switchhash{$switchattribute}) {
							if($switchattribute eq "key") {
								$switchkey = $switchhash{$switchattribute};
							} elsif ($switchattribute eq "name") {	
								$switchname = $switchhash{$switchattribute};
								$switchname =~ s/\s/_/g;
								$switchname =~ s/(\)|\()//g;
								$switchname =~ s/\./_/g;
							} elsif ($switchattribute eq "wwn") {
								$switchwwn = $switchhash{$switchattribute};
							} elsif ($switchattribute eq "operationalStatus") {
								$switchopstate = $switchhash{$switchattribute};
							} elsif ($switchattribute eq "state") {
								$switchstate = $switchhash{$switchattribute};
							} elsif ($switchattribute eq "statusReason") {
								$switchstatus = $switchhash{$switchattribute};	
							}
						}
					}
					$switchinfo{$fabric}{$switchname}{"key"} = $switchkey;
                    $switchinfo{$fabric}{$switchname}{"wwn"} = $switchwwn;
                    $switchinfo{$fabric}{$switchname}{"operationalStatus"} = $switchopstate;
                    $switchinfo{$fabric}{$switchname}{"state"} = $switchstate;
                    $switchinfo{$fabric}{$switchname}{"statusReason"} = $switchstatus;
                    $log->debug("Retrieved: ".$fabric.": ".$switchname." - ".$switchkey." - ".$switchwwn." - ".$switchopstate." - ".$switchstate." - ".$switchstatus);
					$switchref{$fabric}{$switchkey} = $switchname;
				}
			}
		}
	}
}

sub getenddevices {
	foreach my $fabric (sort keys %fabrickey) {
		my $bnaswitchurl = $bnaurl."/rest/resourcegroups/All/fcfabrics/".$fabrickey{$fabric}."/enddevices";
		my $wwnn = "";
		my $type = "";
		my $line = http_get($bnaswitchurl);
		if ($line =~ "{") {
			my %json = %{decode_json($line)};
			my @enddevices = $json{"endDevices"};
			foreach my $enddevice (@enddevices) {
				my @enddevicearray = @{$enddevice};
				foreach my $enddeviceelements (@enddevicearray) {
					my %enddevicehash = %{$enddeviceelements};
					foreach my $enddeviceattribute (keys %enddevicehash) {
						if($enddeviceattribute eq "wwn") {
							$wwnn = $enddevicehash{$enddeviceattribute};
						} elsif ($enddeviceattribute eq "type") {
							$type = $enddevicehash{$enddeviceattribute};
							$type = lc $type;
							$type =~ s/\+/_/g;
						}
					}
					if($wwnn ne "") {
						if(!defined $allenddevices{$wwnn}) {
							$allenddevices{$wwnn}{"type"} = $type;
							$log->debug("Enddevice: ".$wwnn." found with type: ".$type);
						} else {
							$log->info("Duplicate enddevices detected with WWNN: ".$wwnn."! Please verify!");
						}
					}
				}
			}
		}
	}
}

sub getportinfos {
	foreach my $fabric (sort keys %fabrickey) {
		foreach my $switchname (sort keys %{$switchinfo{$fabric}}) {
			if($switchname =~ "^fcr_.d_") {
				$log->debug("Omitting switch: ".$switchname." of fabric ".$fabric." since it looks like a fc routing front domain");
				next;
			}
			
			my $bnaporturl = $bnaurl."/rest/resourcegroups/All/fcfabrics/".$fabrickey{$fabric}."/fcswitches/".$switchinfo{$fabric}{$switchname}{"key"}."/fcports";
			my $portkey = "";
			my $portwwn = "";
			my $portname = "";
			my $portslotnumber = "";
			my $portnumber = "";
			my $porttype = "";
			my $remotewwpn = "";
			my $remotewwnn = "";
			my $longdistance = "";
			my $line = http_get($bnaporturl);
			if($line =~ "{") {
				my %json = %{decode_json($line)};
				my @fcports = $json{"fcPorts"};
				foreach my $fcport (@fcports) {
					my @fcportarray = @{$fcport};
					foreach my $portelemets (@fcportarray) {
						my %porthash = %{$portelemets};
						foreach my $portattribute (keys %porthash) {
							if(defined $porthash{$portattribute}) {
								if ($portattribute eq "key") {
									$portkey = $porthash{$portattribute};
								} elsif ($portattribute eq "wwn") {
									$portwwn = $porthash{$portattribute};
								} elsif ($portattribute eq "name") {
									$portname = $porthash{$portattribute};
								} elsif ($portattribute eq "slotNumber") {
									$portslotnumber = $porthash{$portattribute};
								} elsif ($portattribute eq "portNumber") {
									$portnumber = $porthash{$portattribute};
								} elsif ($portattribute eq "type") {
									$porttype = $porthash{$portattribute};
								} elsif ($portattribute eq "remotePortWwn") {
									$remotewwpn = $porthash{$portattribute};
								} elsif ($portattribute eq "remoteNodeWwn") {
									$remotewwnn = $porthash{$portattribute};	
								} elsif ($portattribute eq "longDistanceSetting") {
									$longdistance = $porthash{$portattribute};
								}
							}
						}

						

						$portinfo{$fabric}{$switchname}{$portkey}{"slot"} = $portslotnumber;							
						$portinfo{$fabric}{$switchname}{$portkey}{"port"} = $portnumber;							
						$portinfo{$fabric}{$switchname}{$portkey}{"wwn"} = $portwwn;							
						if(($porttype eq 'E_PORT') && ($longdistance ne '0')) {
							$porttype = 'LE_PORT';
						}
						$portinfo{$fabric}{$switchname}{$portkey}{"type"} = $porttype;							
						$portinfo{$fabric}{$switchname}{$portkey}{"name"} = $portname;							
						$portinfo{$fabric}{$switchname}{$portkey}{"remotewwpn"} = $remotewwpn;
						$portinfo{$fabric}{$switchname}{$portkey}{"remotewwnn"} = $remotewwnn;


						if($remotewwpn ne "") {
							$wwninfo{$remotewwpn}{"fabric"} = $fabric;
							$wwninfo{$remotewwpn}{"switch"} = $switchname;
							$wwninfo{$remotewwpn}{"portkey"} = $portkey;
						}
						if(defined ($allenddevices{$remotewwnn}{"type"})) {
							$log->debug("Retrieving: ".$fabric.": ".$switchname." - ".$portslotnumber." - ".$portnumber." - ".$portname." - ".$porttype." - ".$portkey." with remote WWPN: ".$remotewwpn." (Type: ".$allenddevices{$remotewwnn}{"type"}.")");
						} else {
							$log->debug("Retrieving: ".$fabric.": ".$switchname." - ".$portslotnumber." - ".$portnumber." - ".$portname." - ".$porttype." - ".$portkey." with remote WWPN: ".$remotewwpn." WWNN: ".$remotewwnn);
						}
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"portkey"}=$portkey;
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"wwn"}=$portwwn;
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"type"}=$porttype;
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"name"}=$portname;
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"remotewwpn"} = $remotewwpn;
						$plainportinfo{$fabric}{$switchname}{$portslotnumber}{$portnumber}{"remotewwnn"} = $remotewwnn;
					}
				}
			}
		}
	}
}

sub getswitchstats {
	my $epochtime = time;
    	my $endtime = $epochtime - (5*60);
    	my $starttime = ($endtime - ($pollinterval*60))*1000;
    	$endtime = $endtime * 1000;

	my $switch = "";
	my $metrictime = "";
	my $metricvalue = "";

	foreach my $fabric (sort keys %switchinfo) {
		foreach my $metrictype (sort keys %{$metrics{"switch"}}) {
			foreach my $switchmetric (sort keys %{$metrics{"switch"}{$metrictype}}) {
				my $bnastaturl = $bnaurl."/rest/resourcegroups/All/fcfabrics/".$fabrickey{$fabric}."/".$switchmetric."?granularity=GRANULARITY_MINIMUM&startdate=".$starttime."&enddate=".$endtime;
				$log->info("Quering Metric: ".$switchmetric." for fabric: ".$fabric);
				my $line = http_get($bnastaturl);
				if($line =~ "{") {
               				my %json = %{decode_json($line)};
					my @performancedatas = $json{"performanceDatas"};
            				foreach my $performancedata (@performancedatas) {
                   				my @perfdataarray = @{$performancedata};
                   				foreach my $perfdataelements (@perfdataarray) {
                   					my %perfdatahash = %{$perfdataelements};
                  					foreach my $perfdataattribute (sort keys %perfdatahash) {
                   						if(defined $perfdatahash{$perfdataattribute}) {
									if($perfdataattribute eq "targetKey") {
										$switch = $switchref{$fabric}{$perfdatahash{$perfdataattribute}};
									} elsif ($perfdataattribute eq "timeSeriesDatas") {
										my @timeseries = @{$perfdatahash{$perfdataattribute}};
                								foreach my $timeentry (@timeseries) {
                        	               						my %timeserieshash = %{$timeentry};
                                	    						foreach my $timeattribute (sort keys %timeserieshash) {
                                        	 						if(defined ($timeserieshash{$timeattribute})) {
                                               								if($timeattribute eq "timeInSeconds") {
                                               			    						$metrictime = $timeserieshash{$timeattribute};
                                        								} elsif ($timeattribute eq "value") {
                                               		  							$metricvalue = $timeserieshash{$timeattribute};
														my $metrictouse = $switchmetric;
														my $tempsensorindex = 0;
                        											my $fanindex = 0;
														if($switchmetric eq "timeseriestemperature") {
															$metrictouse = $switchmetric."_".$tempsensorindex;
															while(defined $switchstats{$fabric}{$switch}{$metrictouse}{$metrictime}) {
																$tempsensorindex+=1;
																$metrictouse = $switchmetric."_".$tempsensorindex;
															}
														} elsif ($switchmetric eq "timeseriesfanspeed") {
															$metrictouse = $switchmetric."_".$fanindex;
															while(defined $switchstats{$fabric}{$switch}{$metrictouse}{$metrictime}) {
																$fanindex += 1;
																$metrictouse = $switchmetric."_".$fanindex;
															}
														}
														if(defined $switchstats{$fabric}{$switch}{$metrictouse}{$metrictime}) {
															$log->warn("Collision in Metric". $switchmetric);
														}
														$switchstats{$fabric}{$switch}{$metrictouse}{$metrictime}=$metricvalue;
														if($loglevel eq "TRACE") {
															$log->trace("Switchdata: ".$fabric." - ".$switch. " : ".$metrictouse." at ".$metrictime." is ".$metricvalue);
														}
													}
												}
											}
										}
									}
								}
							}		
						}
					}
				}
			}
		}
	}
}

sub getportstats {
	my $epochtime = time;
	my $endtime = $epochtime - (5*60);
	my $starttime = ($endtime - (($pollinterval+5)*60))*1000;	
	$endtime = $endtime * 1000;
	my $slot = "";
	my $port = "";
	my $value = "";
	my $metrictime = "";
	my $metricvalue = "";
	foreach my $fabric (sort keys %switchinfo) {
		foreach my $switch (sort keys %{$switchinfo{$fabric}}) {
			if($switch =~ "^fcr_.d_") {
				#log->debug("Omitting data collection for switch ".$switch." of fabric ".$fabric." since it lookup like a fiberchannel routing fron domain!");
				next;
			}
			foreach my $metrictype (sort keys %{$metrics{"port"}}) {
				foreach my $metric (sort keys %{$metrics{"port"}{$metrictype}} ) {
					my $bnastaturl = $bnaurl."/rest/resourcegroups/All/fcfabrics/".$fabrickey{$fabric}."/fcswitches/".$switchinfo{$fabric}{$switch}{"key"}."/".$metric."?granularity=GRANULARITY_MINIMUM&startdate=".$starttime."&enddate=".$endtime;
					$log->info("Querying Metric: ".$metric." for Switch: ".$switch." from fabric: ".$fabric);
					my $targetkey = "";
					my $rxtx = "";
					my $line = http_get($bnastaturl);
					if($line =~ "{") {
						my %json = %{decode_json($line)};
						my @performancedatas = $json{"performanceDatas"};
						foreach my $performancedata (@performancedatas) {
							my @perfdataarray = @{$performancedata};
							foreach my $perfdataelements (@perfdataarray) {
								my %perfdatahash = %{$perfdataelements};
								foreach my $perfdataattribute (sort keys %perfdatahash) {
									if(defined $perfdatahash{$perfdataattribute}) {
										if($perfdataattribute eq "targetKey") {
											$targetkey = $perfdatahash{$perfdataattribute};
											$slot = $portinfo{$fabric}{$switch}{$targetkey}{"slot"};
											$port = $portinfo{$fabric}{$switch}{$targetkey}{"port"};
										} elsif ($perfdataattribute eq "measureName") {
											if($perfdatahash{$perfdataattribute} =~ "Rx") {
												$rxtx = "rx";
											} elsif ($perfdatahash{$perfdataattribute} =~ "Tx") {
												$rxtx = "tx";
											}						
										} elsif ($perfdataattribute eq "timeSeriesDatas") {
											my @timeseries = @{$perfdatahash{$perfdataattribute}};
											foreach my $timeentry (@timeseries) {
												my %timeserieshash = %{$timeentry};
												foreach my $timeattribute (sort keys %timeserieshash) {
													if(defined ($timeserieshash{$timeattribute})) {
														if($timeattribute eq "timeInSeconds") {
															$metrictime = $timeserieshash{$timeattribute};
														} elsif ($timeattribute eq "value") {
															$metricvalue = $timeserieshash{$timeattribute};
															my $metrictouse = $metric;
															if($metric eq "timeseriestraffic") {
																$metrictouse = $metric."_".$rxtx;;
															} elsif ($metric eq "timeseriesutilpercentage") {
																$metrictouse = $metric."_".$rxtx;;
															} elsif ($metric eq "timeseriessfppower") {
																if ($rxtx eq "rx") {
																	$metrictouse = $metric."_rxp";
																} elsif ($rxtx eq "tx") {
																	$metrictouse = $metric."_txp";
																}
															} elsif ($metric eq "timeserieslinkresets") {
																if($rxtx eq "rx") {
																	$metrictouse = $metric."_in";
																} elsif ($rxtx eq "tx") {
																	$metrictouse = $metric."_out";
																}
															}
															if(defined $perfstats{$fabric}{$switch}{$slot}{$port}{$metrictouse}{$metrictime}) {
																$log->warn("Collsion in Metric: ".$metrictouse." at time ".$metrictime." for key ".$targetkey);
															}
															$perfstats{$fabric}{$switch}{$slot}{$port}{$metrictouse}{$metrictime} = $metricvalue;	
															if($loglevel eq "TRACE") {
																$log->trace("Performancedata: ".$fabric." - ".$switch." - ".$slot."/".$port." at ".$metrictime." for ".$metrictouse." with value: ".$metricvalue);
															}
														}
													}
												}
											}
										}	
									}	
								}
							}
						}
					}
				}
			}
		}
	}
}

sub logstats2graphite {
	$sockettimer = [gettimeofday];
	initsocket();
	foreach my $fabric (sort keys %perfstats) {
		foreach my $switch (sort keys %{$perfstats{$fabric}}) {
			foreach my $slot (sort keys %{$perfstats{$fabric}{$switch}}) {
				if($slot<0) {
					$log->warn("There is a slot -1 reported by ".$switch." of fabric ".$fabric." ! Please check discovery of the Switch through BNA!");
					next;
				}
				foreach my $port (sort keys %{$perfstats{$fabric}{$switch}{$slot}}) {
					if($port<0) {
                    				$log->warn("There is a port -1 reported by ".$switch." of fabric ".$fabric." on slot ".$slot." ! Please check discovery of the Switch through BNA!");
                        			next;
                    			}
					foreach my $metric (sort keys %{$perfstats{$fabric}{$switch}{$slot}{$port}}) {
						foreach my $metrictime (sort keys %{$perfstats{$fabric}{$switch}{$slot}{$port}{$metric}}) {	
							my $value = $perfstats{$fabric}{$switch}{$slot}{$port}{$metric}{$metrictime};
							my $porttype = $plainportinfo{$fabric}{$switch}{$slot}{$port}{"type"};
							if((!$monitoruport) && $porttype eq "U_PORT") {
								$log->trace("skipped U-Port: ".$fabric." ".$switch." ".$slot."/".$port." ".$metric." ".$metrictime);
								next;
							}
							if((!$monitorgport) && $porttype eq "G_PORT") {
								$log->trace("skipped G-Port: ".$fabric." ".$switch." ".$slot."/".$port." ".$metric." ".$metrictime);
								next;
							}
							my $cleanmetric = $metric;
							my $basemetric = $metric;
							if($metric =~ "_") {
								$cleanmetric =~ s/_/\./g;		
								my @metricelements = split("_",$metric);
								$basemetric = $metricelements[0];
							}
							
							if(grep(/^$metrics_lookup{$basemetric}{"type"}/,@logbyport)) {
								toGraphite("brocade.stats.ports.".$fabric.".".$switch.".".$porttype.".".$slot.".".$port.".".$cleanmetric." ".$value." ".$metrictime);
							}
							if(grep(/^$metrics_lookup{$basemetric}{"type"}/,@logbyhost)) {
								my $devicewwpn = uc $plainportinfo{$fabric}{$switch}{$slot}{$port}{"remotewwpn"};
								my $devicewwnn = uc $plainportinfo{$fabric}{$switch}{$slot}{$port}{"remotewwnn"};
								if(defined($hostmapping{$devicewwpn})) {
									my $hostname = $hostmapping{$devicewwpn}{"host"};
									my $wwpnalias = $hostmapping{$devicewwpn}{"alias"};
									my $remotetype = $allenddevices{$devicewwnn}{"type"};
									toGraphite("brocade.stats.hosts.".$remotetype.".".$fabric.".".$hostname.".".$wwpnalias.".".$cleanmetric." ".$value." ".$metrictime);
								}
							}
						} 
					}
				}
			} 
		}
	}
	foreach my $fabric (sort keys %switchstats) {
		foreach my $switch (sort keys %{$switchstats{$fabric}}) {
			foreach my $metric (sort keys %{$switchstats{$fabric}{$switch}}) {
				foreach my $timestamp (sort keys %{$switchstats{$fabric}{$switch}{$metric}}) {
					my $value = $switchstats{$fabric}{$switch}{$metric}{$timestamp};
					my $cleanmetric = $metric;
					if($metric =~ "_") {
						$cleanmetric =~ s/_/\./g;
					}
					toGraphite("brocade.stats.switches.".$fabric.".".$switch.".".$cleanmetric." ".$value." ".$timestamp);
				}
			}
		}
	}
	closesocket();
}

sub logscriptstats{
	my $metric = $_[0];
	my $value = $_[1];
	my $newsocket = $_[2];
	if($newsocket) {
		initsocket();
	}
	toGraphite("brocade.bna2graphite.stats.".$metric." ".$value." ".$scripttime);
	if($newsocket) {
		closesocket();
	}
}

sub initsocket {
	$socket = new IO::Socket::INET (
    	PeerHost => $graphitehost,
    	PeerPort => $graphiteport,
    	Proto => 'tcp',
	);
	die "cannot connect to socket ".$graphitehost.":".$graphiteport." with message: $!\n" unless $socket;
	setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
	$log->debug("Opening connection ".$socket->sockhost().":".$socket->sockport()." => ".$socket->peerhost().":".$socket->peerport());
}
	
## sub to close socket to graphite host
	
sub closesocket {
	#console("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
	$log->debug("Closing Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
	$socket->shutdown(2);
	#console("Closed Socket ".$socket->sockhost().":".$socket->sockport()." - ".$socket->peerhost().":".$socket->peerport());
}
	
# sub to send plain text protocol strings to graphite host including possibility to throttle the amount of messages send to graphite

sub toGraphite {
	$socketcnt+=1;
	my $message = $_[0];	
	$socket->send($message."\n");
	# not every message will be delayed since to allow quick systems to be utilized. Delay will only happen when the delay time is larger than 0ns since nanosleep(0) will consume time.
	if(($socketdelay>0)&&!($socketcnt % $delaymetric)) {
		nanosleep($socketdelay);
	}
	# every 100.000 inserts we will check how long it takes for 100.000 in obejcts to insert. The delay will be adjusted base on this result compared to the maximum amount of metrics that should be imported.
	if($socketcnt>=100000) {	
		alive();	
		my $elapsed = tv_interval ( $sockettimer, [gettimeofday]);
		my $metricsperminute = 60/$elapsed*100000;	
		if($socketdelay>0) {
			$socketdelay = int($socketdelay*($metricsperminute/$maxmetricsperminute));
			# in case of running as service avoid that to large delay will trigger the watchdog...
			if($daemon) {
				if($socketdelay > $maxdelay) {
					$socketdelay = $maxdelay;
				}
			}
		} else {
			# if the delay was going down to 0ns there need to be a possibility to increase the delay again starting with 1us.
			$socketdelay = int(1000*($metricsperminute/$maxmetricsperminute));
		}	
		$log->info("Elapsed time for last 100.000 Metrics: ".$elapsed." => metrics per minute: ".$metricsperminute."\t new delay: ".$socketdelay);
		$sockettimer = [gettimeofday];
		$socketcnt = 0;
	}
}

# Sub to read time of last successful run from file
sub readlastruntime {
	my $runfile = $statusdir.$bnashortname."_run.txt";
	if (!-f $runfile) {
		$lastsuccessfulrun = 0;	
	} else {
		open(my $fh,'<',$runfile) or die "Can't open < ".$runfile." to write last successul runtime: $!";
		while(<$fh>) {
			my $line = $_;
			my @values = split(" ",$line);
			$lastsuccessfulrun = $values[0];			
		}
	}
}

# Sub to write time of last successful run to file

sub writelastruntime {
	my $runfile = $statusdir.$bnashortname."_run.txt";
	if (!-d $statusdir) {
		mkdir $statusdir;
	}
	open(my $fh,'>',$runfile) or die "Can't open < ".$runfile." to write last successul runtime: $!";
	$log->info("Writing status to runfile (".$runfile.") with last successful runtime (".$lastsuccessfulrun.") and pollinterval (".$pollinterval.").");
	print $fh $lastsuccessfulrun." ".$pollinterval." ".$lastsuccessfulrunend;
	close $fh;
}

# Sub to calculate how many hours should be imported based on start time of last successful run. Will only be used when running as Daemon.

sub getminutestoimport {
	if($lastsuccessfulrun == 0) {
		return($pollinterval);
	}
	my $deltaseconds = time - $lastsuccessfulrun;
	my $minutes = ceil($deltaseconds/60);
	# Roundup to 5 minutes
	$minutes = ceil($minutes/5)*5;
	if($minutes>1440) {
		$minutes=1440;
	} 
	$log->info("Next run should import ".$minutes." minutes of data from BNA!");
	return($minutes);
}

# Sub to delay process for achieve scheduling based on configuration files. Will only be used when running as Daemon.

sub delayuntilnextrun {
	servicestatus("Waiting for next run...");
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my $modulo = $hour%$runeveryhours;
	while(($min != $minafterfullhours) || ($modulo != 0)) {
		my $tracemsg = "Sleeping for 10 sec since Minute ".$min." != ".$minafterfullhours;
		if($modulo != 0) {
			$tracemsg.= " and not reached the runeveryhours period (Modulo = ".$modulo.")";
		} else {
			$tracemsg.= " !";
		}
		$log->trace($tracemsg);
		sleep(10);
		($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
		$modulo = $hour%$runeveryhours;
		alive();
	}
}

# Sub to initialize Systemd Service

sub initservice {
	notify( READY => 1 );
	$log->trace("Service is initialized...");
}

# Sub to update status of Systemd Service when running as Daemon

sub servicestatus {
	my $message = $_[0];
	notify( STATUS => $message );
	$log->trace("Status message: ".$message." is send to service...");
}

# Sub to signal a stop of the script to the service when running as Daemon

sub stopservice {
	notify ( STOPPING => 1 )
}

# Sub to send heartbeat wo watchdog of Systemd service when running as Daemon.

sub alive {
	if($daemon) {
		notify ( WATCHDOG => 1 );
		if($loglevel eq "TRACE") {
			$log->trace("Heartbeat is send to watchdog of service...");
		}
	}
}

sub cleanhashes {
	%fabrickey=();
	%switchinfo=();
	%switchref=();
	%portinfo=();
	%plainportinfo=();
	%perfstats=();
	%switchstats=();
	%allenddevices=();
}


parseCmdArgs();

$logfile .= 'bna2graphite_'.$bnashortname.'.log';

print $logfile."\n";

my $log4perlConf  = qq(
log4perl.logger.main.report            = $loglevel,  FileAppndr1
log4perl.appender.FileAppndr1          = Log::Log4perl::Appender::File
log4perl.appender.FileAppndr1.filename = $logfile
log4perl.appender.FileAppndr1.owner    = openiomon
log4perl.appender.FileAppndr1.group    = openiomon
log4perl.appender.FileAppndr1.umask    = 0000
log4perl.appender.FileAppndr1.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.FileAppndr1.layout.ConversionPattern = %d [%p] (%F:%L) %M > %m %n
);
Log::Log4perl->init(\$log4perlConf);
$log = Log::Log4perl->get_logger('main.report');


initservice();
readlastruntime();
readmetricfile();

do {
	alive();	
	if($daemon) {
		delayuntilnextrun();
		$scripttime = time;
		$pollinterval = getminutestoimport();
	}
	if((scalar @logbyhost)>0) {
		readhostmapping();
	}
	my $curtime = time;
	my $starttime = time;
	$sockettimer = [gettimeofday];
	servicestatus("Querying BNA configration data...");
	console("Logon to BNA...");
	$bnatoken = getbnatoken();
	logscriptstats("bna_logon",time-$curtime,true);
	$curtime = time;
	console("Getting Fabrics...");
	getfabrics();
	logscriptstats("get_fabrics",time-$curtime,true);
	$curtime = time;
	console("Getting SAN Switches...");
	getfcswitches();
	logscriptstats("get_switches",time-$curtime,true);
	$curtime = time;
        console("Getting enddevices...");
	getenddevices();
	logscriptstats("get_enddevices",time-$curtime,true);
	$curtime = time;
	console("Getting port configuration...");
	getportinfos();
	logscriptstats("get_ports",time-$curtime,true);
	servicestatus("Querying switch statistics...");
	$curtime = time;
	console("Getting switch statistics for ".$pollinterval." Minutes...");
	getswitchstats();
	logscriptstats("get_switchstats",time-$curtime,true);
	$curtime = time;
	servicestatus("Querying port statistics...");
	console("Getting port statistics for ".$pollinterval." Minutes...");
	getportstats();
	logscriptstats("get_portstats",time-$curtime,true);
	$curtime = time;
	servicestatus("Logging data to graphite...");
	console("Logging data to graphite...");
	logstats2graphite();
	logscriptstats("log_allstats",time-$curtime,true);
	logscriptstats("interval_gathered",$pollinterval,true);
	#console("Socketcnt=".$socketcnt);
	console("Done!");
	$lastsuccessfulrun = $starttime;
	$lastsuccessfulrunend = time;
	writelastruntime();
	cleanhashes();
} while($daemon);

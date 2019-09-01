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
#  Initially written: 13.11.2017
#
#  Description      : Script controls the services responsible for importing the performance data from Brocade Network Advisor (BNA)
#
#  Dependencies     : The following non standard perl modules are needed
#                     perl-Log-Log4perl perl-Switch
#
#  Modification History:
#
#  Author           Date        Version         Comment
#  ===============  =========== =============== =================================================
#  Drach (td)       26.11.2017  0.1             Initial version
#
#  End Modification History
# ==============================================================================================


use strict;
use warnings;
use Switch;
use constant false => 0;
use constant true  => 1;
use Log::Log4perl;
use Getopt::Long;
use POSIX qw(strftime);

#log variables
my $log; # log4perl logger
my $logfile = '/opt/bna2graphite/log/bna2graphite.log';
my $loglevel = 'INFO';

# command arguments variables
my $register ='';
my $deregister ='';
my $enable ='';
my $disable ='';
my $start ='';
my $stop ='';
my $restart ='';
my $status ='';
my $help;
my $conf = '/opt/bna2graphite/conf/bna2graphite.conf';

# service parameters
my $runeveryhours = 1;
my $minafterfullhours = 0;
my $serviceuser = 'openiomon';
my $servicegroup = 'openiomon';
my $watchdog = 300;
my $libdir = "/opt/bna2graphite/lib/";
my $workdir = "/opt/bna2graphite/";
my $stdoutopt = 'null';
my $stderropt = 'null';

# hash for bna servers in configfile

my %bnaservers;


sub console {
    my $message = shift;
    print $message,"\n";
    $log->info($message);
}

# Sub to print the parameter reference

sub printUsage {
    print("Usage:\n");
    print("$0 [OPTIONS]\n");
    print("OPTIONS:\n");
    print("   -conf         <file>          conf file containig parameter for the import\n");
    print("   -register     <name or ALL>   name of the BNA server to be registerd as service\n");
    print("   -deregister   <name or ALL>   name of the BNA server which service should be deregisterd\n");
    print("   -enable       <name or ALL>   activate automatic service start for the BNA server\n");
    print("   -disable.     <name or ALL>   deactivate automatic service start for the BNA server\n");
    print("   -start.       <name or ALL>   start for the service for the BNA server\n");
    print("   -stop         <name or ALL>   stop for the service for the BNA server\n");
    print("   -restart      <name or ALL>   restart for the service for the BNA server\n");
    print("   -status.      <name or ALL>   status of the service for the BNA server\n");
    print("   -h                            print this output\n");
    print("\n");
}

sub parseCmdArgs {
    my $help = "";
    GetOptions (    "conf=s"            => \$conf,              # String
                    "register=s"        => \$register,          # String
                    "deregister=s"      => \$deregister,        # String
                    "enable=s"          => \$enable,            # String
                    "disable=s"         => \$disable,           # String
                    "start=s"           => \$start,             # String
                    "stop=s"            => \$stop,              # String
                    "restart=s"         => \$restart,           # String
                    "status=s"          => \$status,            # String
                    "h"                 => \$help)              # flag
    or die("Error in command line arguments\n");

    if($help) {
        printUsage();
        exit(0);
    }

    # Wrong or missing config file?
    if(!-f $conf) {
        print "Configuration file: ".$conf." cannot be found! Please specify configuration file!\n\n";
        printUsage();
        exit(1);
    } else {
        # read config file to get params
        readconfig();
    }

    if(($register eq "") && ($deregister eq "") && ($enable eq "") && ($disable eq "") && ($start eq "") && ($stop eq "") && ($restart eq "") && ($status eq "")) {
        printUsage();
        exit(1);
    }

    if(($register ne "") && ($deregister ne "")) {
        print "Cannot register and deregister service at the same time!\n";
        exit(1);
    }

    if(($enable ne "") && ($disable ne "")) {
        print "Cannot enable and disable service at the same time!\n";
        exit(1);
    }

    if(($start ne "") && ($stop ne "")) {
        print "Cannot start and stop service at the same time!\n";
        exit(1);
    }

    if(($start ne "") && ($restart ne "")) {
        print "Cannot start and restart service at the same time!\n";
        exit(1);
    }

    if(($stop ne "") && ($restart ne "")) {
        print "Cannot stop and restart service at the same time!\n";
        exit(1);
    }


}

sub readconfig {
    # Open the configfile...
    open my $configfilefp, '<', $conf or die "Can't open file: $!";
    my $section = "";
    while(<$configfilefp>) {
        my $configline = $_;
        chomp ($configline);
        # Skip all line starting with a # (hash).
        if (($configline !~ "^#") && ($configline ne "")){
            # read the section from the configfile
            if ($configline =~ '\[') {
                $configline =~ s/\[//g;
                $configline =~ s/\]//g;
                $configline =~ s/\s//g;
                $section = $configline;
            } else {
                # Read the config parameters based on the config file section
                switch($section) {
                    case "BNA" {
                        my @values = split (";",$configline);
                        $bnaservers{$values[0]}{"user"}=$values[1];
                        $bnaservers{$values[0]}{"passwd"}=$values[2];
                        my $bnashortname = "";
                        if($values[0] =~ /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/) {
                            $bnashortname =~ s/\./_/g;
                        } else {
                            my @namevalues = split(/\./,$values[0]);
                            $bnashortname = $namevalues[0];
                        }
                        $bnaservers{$values[0]}{"shortname"} = uc($bnashortname);
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
                            $logfile.='bna2graphite.log';
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
                    case "service" {
                        my @values = split ("=",$configline);
                        if($configline =~ "runeveryhours") {
                            $runeveryhours = $values[1];
                            $runeveryhours =~ s/\s//g;
                        } elsif ($configline =~ "runminutesafterhour") {
                            $minafterfullhours = $values[1];
                            $minafterfullhours =~ s/\s//g;
                        } elsif ($configline =~ "serviceuser") {
                            $serviceuser = $values[1];
                        } elsif ($configline =~ "servicegroup") {
                            $servicegroup = $values[1];
                        } elsif ($configline =~ "watchdogtimeout") {
                            $watchdog = $values[1];
                        } elsif ($configline =~ "libdirectory") {
                            $libdir = $values[1];
                            my $lastchar = substr($libdir,-1);
                            if($lastchar ne "\/") {
                                $libdir.="\/";
                            }
                        } elsif ($configline =~ "workingdirectory") {
                            $workdir = $values[1];
                            $workdir =~ s/\s//g;
                            my $lastchar = substr($workdir,-1);
                            if($lastchar ne "\/") {
                                $workdir.="\/";
                            }
                        }
                    }
                }
            }
        }
    }
}

# sub to reload systemctl daemon after changes to service files

sub reloadsystemctl {
    console("Reloading systemctl daemon...");
    my $rc = system('systemctl daemon-reload');
    if($rc != 0) {
        console("Reload of systemctl daemon with command systemctl daemon-reload was not successful! Please ivenstigate!");
    } else {
        console("Reload was done successful!");
    }
}

# sub will register services based on BNA server name or ALL BNA servers

sub registerservice {
    my $bnaserver = $_[0];
    if($bnaserver eq 'ALL') {
        foreach my $bnaserver (sort keys %bnaservers) {
            registerservice($bnaserver);
        }
    } else {
        if(!defined $bnaservers{$bnaserver}) {
            console("BNA ".$bnaserver." cannot be found of configuration file ".$conf." ! Please check BNA server FQDN or configuration file!");
            exit(1);
        }
        console("Registering service for ".$bnaserver." (BNA-user: ".$bnaservers{$bnaserver}{'user'}.")");
        my $servicefile = '/usr/lib/systemd/system/bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.'.service';
        if(-f $servicefile) {
            console("There is already a service with the name bna2graphite-".$bnaservers{$bnaserver}{'shortname'}." registerd. You can either start, stop or restart the service. For updates to servicefile please deregister an register again.");
        } else {

            my $sfh;
            open $sfh, '>', $servicefile or die "Can't open file: $!";

            print $sfh "[Unit]\n";
            print $sfh "Description=BNA2GRAPHITE Service for ".$bnaserver." (BNA-user: ".$bnaservers{$bnaserver}{'user'}.")\n";
            print $sfh "Documentation=http://www.openiomon.org\n";
            print $sfh "Wants=network-online.target\n";
            print $sfh "After=network-online.target\n";
            print $sfh "After=go-carbon.service\n\n";
            print $sfh "[Service]\n";
            print $sfh "Environment=\"PERL5LIB=".$libdir."perl5/:".$libdir."perl5/x86_64-linux-thread-multi/:/usr/local/lib64/perl5:/usr/local/share/perl5:/usr/lib64/perl5/vendor_perl:/usr/share/perl5/vendor_perl:/usr/lib64/perl5:/usr/share/perl5\"\n";
            print $sfh "User=".$serviceuser."\n";
            print $sfh "Group=".$servicegroup."\n";
            print $sfh "Type=notify\n";
            print $sfh "Restart=always\n";
            print $sfh "RestartSec=30\n";
            print $sfh "WatchdogSec=".$watchdog."\n";
            print $sfh "WorkingDirectory=".$workdir."\n";
            print $sfh "RuntimeDirectoryMode=0750\n";
            print $sfh "StandardOutput=".$stdoutopt."\n";
            print $sfh "StandardError=".$stderropt."\n";
            print $sfh "ExecStart=".$workdir."bin/bna2graphite-worker.pl\t\t\t\\\n";
            print $sfh "\t\t-conf ".$workdir."conf/bna2graphite.conf\t\\\n";
            print $sfh "\t\t-bna ".$bnaserver."\t\t\t\t\\\n";
            print $sfh "\t\t-minutes ".($runeveryhours*60)."\t\t\t\t\t\\\n";
            print $sfh "\t\t-daemon\n\n";
            print $sfh "[Install]\n";
            print $sfh "WantedBy=multi-user.target\n";
            close($sfh);
            console("Servicefile: ".$servicefile." has been created!");
        }
    }
}

# sub will remove services based on BNA server name or ALL BNA servers

sub deregisterservice {
    my $bnaserver = $_[0];
    if($bnaserver eq 'ALL') {
        foreach my $bnaserver (sort keys %bnaservers) {
            deregisterservice($bnaserver);
        }
    } else {
        console("Trying to deregister service for BNA ".$bnaserver."...");
        if(!-f '/usr/lib/systemd/system/bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.'.service'){
            console("\tThere is no service registered for ".$bnaserver."! Nothing to do...");
            return(0);
        }
        service($bnaserver,'stop');
        service($bnaserver,'disable');
        unlink '/usr/lib/systemd/system/bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.'.service';
        $log->debug("Executed unlink for file /usr/lib/systemd/system/bna2graphite-".$bnaservers{$bnaserver}{'shortname'}.".service");
        console("Service for ".$bnaserver." has been deregistered!");
    }
}

# sub to perform action on service (e.g. start, stop, restart, enable, disable)

sub service {
    my $bnaserver = $_[0];
    my $action = $_[1];
    if($bnaserver eq 'ALL') {
        foreach my $bnaserver (sort keys %bnaservers) {
            service($bnaserver,$action);
        }
    } else {
        console("Trying to ".$action." service for BNA ".$bnaserver."...");
        if(!-f '/usr/lib/systemd/system/bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.'.service'){
            console("\tService cannot be found for BNA ".$bnaserver.". Please register service or correct defined service for BNA or verify configuration file!");
            return(0);
        }
        my $cmd = 'systemctl '.$action.' bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.' > /dev/null 2>&1';
        $log->debug("Running system command: ".$cmd);
        my $rc = system($cmd);
        if($rc==0) {
            console("Service ".$action."ed for BNA ".$bnaserver."!");
        } else {
            console("Failed to ".$action." service for BNA ".$bnaserver."! Please investigate!");
        }
    }
}

# sub will report the status of a services based on BNA server name or ALL BNA services

sub servicestatus {
    my $bnaserver = $_[0];
    if($bnaserver eq 'ALL') {
        foreach my $bnaserver (sort keys %bnaservers) {
            servicestatus($bnaserver);
        }
    } else {
        $log->info("Gettings state and status of service for BNA ".$bnaserver);
        console($bnaserver.":");
        if(!-f '/usr/lib/systemd/system/bna2graphite-'.$bnaservers{$bnaserver}{'shortname'}.'.service'){
            console("\tService cannot be found for BNA defined in configuration file. Please register service or correct confinguration file!");
            return(0);
        }
        my $querycmd = "systemctl status bna2graphite-".$bnaservers{$bnaserver}{'shortname'};
        my @result = `$querycmd`;
        my $state = "";
        foreach my $line (@result) {
            if ($line =~ "Loaded:") {
                my @values = split(":",$line);
                my $loaded = $values[1];
                chomp($loaded);
                console("\tLoaded:\t\t\t".$loaded);
            } elsif ($line =~ "Active:"){
                my @values = split(":",$line);

                for (my $i=1;$i<(scalar(@values));$i+=1) {
                    $state .= $values[$i].":";
                }
                chop($state);
                chomp($state);
                console("\tActive:\t\t\t".$state);
            } elsif ($line =~ "Status:"){
                my @values = split(":",$line);
                my $status = $values[1];
                $status =~ s/\"//g;
                chomp($status);
                if($state =~ "inactive") {
                    console("\tLast status was:\t".$status);
                } else {
                    console("\tStatus:\t\t\t".$status);
                }
            }
        }
        my $runfile = $workdir."run/".$bnaservers{$bnaserver}{'shortname'}."_run.txt";
        if(!-f $runfile) {
            console("\tLast successful run:\t NEVER");
        } else {
            open my $runfh,'<',$runfile or die "Can't open file: $!";
            while(<$runfh>) {
                my $line = $_;
                my @values = split(" ",$line);
                my $lastrunepoch = $values[0];
                my $pollinterval = $values[1];
                my $lastrunepochend = $values[2];
                if($lastrunepoch == 0) {
                    console("\tLast successful run:\t NEVER");
                } else {
                    my $timestringstart = strftime '%Y-%m-%d %H:%M:%S', localtime($lastrunepoch);
                    my $timestringend = strftime '%Y-%m-%d %H:%M:%S', localtime($lastrunepochend);
                    console("\tLast successful run:\t ".$timestringstart." - ".$timestringend." (pollinterval: ".$pollinterval."mins)\n");
                }
            }
        }
    }
}


# parse CLI parameters...
parseCmdArgs();

# Log4perl initialzation...
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

if($register ne "") {
    registerservice($register);
    reloadsystemctl();
}

if($deregister ne "") {
    deregisterservice($deregister);
    reloadsystemctl();
}

if($status ne "") {
    servicestatus($status);
}

if($start ne "") {
    service($start,'start');
}

if($stop ne "") {
    service($stop,'stop');
}

if($restart ne "") {
    service($restart,'restart');
}

if($enable ne "") {
    service($enable,'enable');
}

if($disable ne "") {
    service($disable,'disable');
}

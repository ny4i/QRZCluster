#! /opt/local/bin/perl -w
use v5.10;
# QRZCluster
# 
# Copyright (C) 2017  Thomas M. Schaefer, NY4I.
#
# This program is free software; you can redistribute it and/or modify 
# it under the terms of the GNU General Public License as published by 
# the Free Software Foundation; either version 2 of the License, or 
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, 
# but WITHOUT ANY WARRANTY; without even the implied warranty of 
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the 
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License 
# along with this program; if not, write to the 
# Free Software Foundation, Inc., 59 Temple Place - Suite 330, 
# Boston, MA 02111-1307, USA. 

# return sprintf("CC11^%0.1f^%s^", $freq, $spotted) . join('^', cldate($t), ztime($t), @_, $spotted_cc, $spotter_cc, $loc_spotted, $loc_spotter);

# I wonder if I should set the VE7CC format so I can parse this easier? But, what about sites that do not support that format?
# Maybe a switch to tell us what format we are to parse.
# Then if we see set/ve7cc from the client, we send it to them in ve7cc format
# http://www.koders.com/perl/fid986ACDD690BE4DE083B9C2814FDF4F5B69C22491.aspx

#DX de K3MM-#:     7010.9  LY1CM        16 dB  23 WPM  CQ              0349Z
#123456789012345678901234567890123456789012345678901234567890                                      
                
#use strict;
#use Audio::Beep;
use IO::Socket;
use Ham::Reference::QRZ;   # https://github.com/bradmc/Ham-Reference-QRZ.git
use Getopt::Std;
use Data::Dumper;
use POE;
use POE::Component::Server::TCP;
use POE::Component::Client::TCP;
require POE::Wheel::ReadLine if $^O !~ /^MSWin/;    # For reading lines from the console.
require POE::Wheel::Run::Win32 if $^O =~ /^MSWin/;
use Cache::FileCache;
#use CHI;
use constant {
	 MULT_ALL		=> 1 
	,MULT_DX			=> 2
	,MULT_ARRL     => 3
	,MODE_W        => 1
	,MODE_SSB      => 2
	,MODE_TTY      => 3
	,MODE_ALL      => 4
	,SOURCE_US     => 1
	,SOURCE_US_VE  => 2
	,SOURCE_ALL    => 3
	,SOURCE_DX     => 4
};
sub CheckContest(); # Forward declaration
my $cache = new Cache::FileCache( { 'namespace' => 'QRZ',
                                    'default_expires_in' => 1200} );
                                    
my $cacheSection = new Cache::FileCache( { 'namespace' => 'ARRLSECTION',
                                           'default_expires_in' => 1200} );                                
my %users;
my $cached;
my %logonTable;
my %options=();
my %sectionsWorked = ();
getopts("sh:u:p:c:nxvqlt:m:w",\%options);
my $verbose = (defined $options{'v'}?1:0);
my $workedSectionsCount;
my $loopCounter = 0;
my $soundAlert = 0;

print "ARRL Section DX Cluster Reporter Server\n";
print "Version 2.04 January 2017\n";
print "Created by Tom Schaefer, NY4I with assistance from Bob Wanek, N2ESP\n";
print "Inspired by the quick multiplier checkers at W4GAC (SPARC) Contesters\n";
print "Copyright 2017 Tom Schaefer, NY4I\n";
print "This program makes use of the following modules:\n";
print "\tPOE framework, Ham::Reference::QRZ\n";
print "Additionally, the CTY files from Jim Reisert, AD1C are used as well as \n";
print " parts of the dxcc script by Fabian Kurz, DJ1YFK\n";
print "Copyright claims for external modules are retained by their respective owners\n";
#Usage() if (!defined $options{'h'} || 
#            !defined $options{'u'} || 
#            !defined $options{'p'});
Usage() if (!defined $options{'h'});
   

my $lidadditions="^QRP\$|^LGT\$";
my $csadditions="(^P\$)|(^M{1,2}\$)|(^AM\$)";
my %LOTWUsers;
my %validSections;
%validSections = &LoadValidSections();
%LOTWUsers = &LoadLOTWFile();

my %Needed;
%Needed = &LoadNeeded();
my $version = &read_cty(); # Load DXCC Table for processing calls not in QRZ

print "CTY.DAT file version $version by Jim Reisert, AD1C\n";
my ($contest,%contestInfo) = CheckContest();
print Dumper(%contestInfo) if $verbose;
print "Customizing spots for $contest contest.\n" unless ($contest =~ /None/);
my $mycall = "";
my $format = 'A14 A2 A8 A2 A11 A2 A29 A2 A4';
my $username = $options{'u'};
my $password = $options{'p'};
my $onlyLOTW = (defined $options{'l'}?1:0);
if ($onlyLOTW) {
   print "Skipping any stations that do NOT use LOTW\n";
}
#&LoadSectionsWorked();
my $mode = &CheckMode();

if (defined $options{'c'}){
   if ($options{'c'} =~ /-\d{1,2}/){
      $mycall = $options{'c'};
   } else {
      $mycall = $options{'c'}."-9";
   }
} else {
   $mycall = $username."-9";
}
 if (defined $options{'n'}){
    print "******* Only showing NEEDED spots\n";
}

if (defined $options{'w'}){
	print "Using sectionsWorked file to filter spots\n";
}

if (!defined $options{'x'}){
   print "SKIPPING CW SPOTTER SPOTS!!! Use -x to allow\n";
}
print "Connecting to DX Cluster $options{h} as $mycall\n"; 
my $qrz = Ham::Reference::QRZ->new(
   username => $username,
   password => $password
 );
 
my $host = $options{'h'};
my $port = 23;
my $loggedIn = 0;
my $server;

print "Listening for client connections on port 2323\n"; 
 
 # Create a new client to connect to the cluster.
 POE::Component::Server::TCP->new(
  Alias              => "QRZCluster",
  Port               => 2323,
  InlineStates       => {send => \&handle_send},
  ClientConnected    => \&client_connected,
  ClientError        => \&client_error,
  ClientDisconnected => \&client_disconnected,
  ClientInput        => \&client_input,
 );
 
 
 POE::Component::Client::TCP->new(
  RemoteAddress => $host,
  RemotePort    => $port,
  Connected     => sub {
    print "connected to $host:$port ...\n";
    $server = $_[SESSION]->ID();

  },
  ConnectError => sub {
    print "could not connect to $host:$port ...\n";
  },
  ServerInput => \&ProcessInput,
);

#Implement the server using POE too to make this much cleaner.

$poe_kernel->run();
exit 0;
 
 


sub broadcast {
  my ($message) = @_;
  foreach my $user (keys %users) {
    $poe_kernel->post($user => send => "$message");
  }
}

# Handle an outgoing message by sending it to the client.
sub handle_send {
  my ($heap, $message) = @_[HEAP, ARG0];
  $heap->{client}->put($message);
}

# Handle a connection.  Register the new user, and broadcast a message
# to whoever is already connected.
sub client_connected {
  my ($kernel, $heap, $session, $input) = @_[KERNEL, HEAP, SESSION, ARG0];

  my $session_id = $session->ID;
  $users{$session_id} = 1;
  print "$session_id connected\n";
  $heap->{client}->put("\nlogin:\n\n");
  $logonTable{$session_id} = 0;

}

# The client disconnected.  Remove them from the chat room and
# broadcast a message to whoever is left.
sub client_disconnected {
  my $session_id = $_[SESSION]->ID;
  delete $users{$session_id};
  $logonTable{$session_id} = 0;
  print "$session_id disconnected\n";
}

# The client socket has had an error.  Remove them from the chat room
# and broadcast a message to whoever is left.
sub client_error {
  my $session_id = $_[SESSION]->ID;
  delete $users{$session_id};
  $logonTable{$session_id} = 0;
  print "$session_id disconnected\n";
  $_[KERNEL]->yield("shutdown");
}

# Broadcast client input to everyone in the chat room.
sub client_input {
  my ($kernel, $heap, $session, $input) = @_[KERNEL, HEAP, SESSION, ARG0];
  my $session_id = $session->ID;
  if (!$logonTable{$session_id}){
     print " ******* $session_id callsign = $input ********\n";
     $heap->{client}->put("$input\n\nHello \n\n\n");
     $heap->{client}->put("$input de VE7CC-1 16-Feb-2011 0301z  CCC>");
     $heap->{client}->put("$input de VE7CC-1 16-Feb-2011 0301z  CCC>");
     $logonTable{$session_id} = 1;
  } elsif ($input =~ /^DX/){ # DX Spot command, send it on to main connection
     $kernel->post($server => send_message => $input."\n");  
  } elsif ($input =~ /^set/i){
     print "Command received $input\n";
     if ($input =~ /^set verbose on/i) {
     	$verbose = 1;
     	print "Verbose enabled\n";
     } elsif ($input =~ /^set verbose off/i) {
        $verbose = 0;
        print "Verbose disabled\n";
     }
  	
  }
  
  
  print "$session_id sent $input\n";
  $kernel->post($server => send_message => $input."\n");
}



# This subroutine creates our ReadLine module and sends our inital
# Prompt.  ReadLine's "InputEvent" parameter specifies the event that
# will be sent when it has read a line of input or some other user
# generated exception.  As we've seen, it is triggered by POE just
# after the session is created.
sub readline_run {
  my ($heap) = $_[HEAP];
  $heap->{readline_wheel} = POE::Wheel::ReadLine->new(InputEvent => 'got_input');
  $heap->{readline_wheel}->put("*** Connected to VE7CC-1:");
  $heap->{readline_wheel}->put("Greetings from the VE7CC-1 cluster.");
  $heap->{readline_wheel}->put("Located near Vancouver BC");
  $heap->{readline_wheel}->put("Running CC Cluster software version 3.018b");
  $heap->{readline_wheel}->put(""); 
  $heap->{readline_wheel}->put("*************************************************************************");
  $heap->{readline_wheel}->put("*                                                                       *");
  $heap->{readline_wheel}->put("*     Please login with a callsign indicating your correct country      *"); 
  $heap->{readline_wheel}->put("*                          Portable calls are ok.                       *"); 
  $heap->{readline_wheel}->put("*                                                                       *");  
  $heap->{readline_wheel}->put("*************************************************************************"); 
  $heap->{readline_wheel}->put(""); 
  $heap->{readline_wheel}->put("New commands:");
  $heap->{readline_wheel}->put(""); 
  $heap->{readline_wheel}->put("set/skimmer   turns on Skimmer spots.");
  $heap->{readline_wheel}->put("set/noskimmer turns off Skimmer spots.");
  $heap->{readline_wheel}->put(""); 
  $heap->{readline_wheel}->put("set/own      turns on Skimmer spots for own call.");
  $heap->{readline_wheel}->put("set/noown    turns them off.");
  $heap->{readline_wheel}->put(""); 
  $heap->{readline_wheel}->put("set/nobeacon  turns off spots for beacons.");
  $heap->{readline_wheel}->put("set/beacon    turns them back on.");
  $heap->{readline_wheel}->put("");
  $heap->{readline_wheel}->put("For information on CC Cluster software see:");
  $heap->{readline_wheel}->put("http://bcdxc.org/ve7cc/ccc/CCC_Commands.htm");
  $heap->{readline_wheel}->put(" ");
  $heap->{readline_wheel}->put("AR User program now at ver. 2.394");
  $heap->{readline_wheel}->put("Please enter your callsign at the login prompt.");
  $heap->{readline_wheel}->put("");
  $heap->{readline_wheel}->put("login:"); 
  $heap->{readline_wheel}->put("");
  $heap->{readline_wheel}->get("");
}

# The session is about to stop.  Ensure that the ReadLine object is
# deleted, so it can place your terminal back into a sane mode.  This
# function is triggered by POE's "_stop" event.
sub readline_stop {
  delete $_[HEAP]->{readline_wheel};
}

# The input handler adds user input to an input history, displays what
# the user entered, and prompts for another line.  It also handles the
# "interrupt" exception, which is thrown by POE::Wheel::ReadLine when
# the user presses Ctrl+C.
# If you recall, POE::Session->create() has mapped the "got_input"
# event to the got_input_handler() function.  Looking back, you will
# see that POE::Wheel::ReadLine->new() is used to generate "got_input"
# events for each line of input the user enters.
# ReadLine input handlers take two arguments other than the usual
# KERNEL, HEAP, and so on.  ARG0 contains any input that was entered.
# If ARG0 is undefined, then ARG1 holds a word describing a
# user-generated exception such as "interrupt" (the user pressed
# Ctrl+C) or "cancel" (the user pressed Ctrl+G).
sub got_input_handler {
  my ($heap, $kernel, $input, $exception) = @_[HEAP, KERNEL, ARG0, ARG1];
  if (defined $input) {
    $heap->{readline_wheel}->addhistory($input);
    $heap->{readline_wheel}->put("I heard $input");
  }
  elsif ($exception eq 'interrupt') {
    $heap->{readline_wheel}->put("Goodbye.");
    delete $heap->{readline_wheel};
    return;
  }
  else {
    $heap->{readline_wheel}->put("\tException: $exception");
  }
  $heap->{readline_wheel}->get("Say Something Else: ");
}

##################################################################################################
# DX Cluster Input Processor
##################################################################################################
sub ProcessInput {
	#when the server answer the question
    my ($kernel, $heap, $buf) = @_[KERNEL, HEAP, ARG0];
    my $lotw = 0;
    my $state;
    my $newComment = "";
    my ($DXCCCall, $ARRLCall, $stateCall);
    
    print "Received: $buf\n" if $verbose;
    # We need to check for the login prompt
    if ($loggedIn != 1 && $buf =~ /Please enter your call:/) {
    print "***Found login prompt\n" if $verbose;
       $_[HEAP]->{server}->put($mycall."\n");
       $loggedIn = 1;
       sleep(5);
       $_[HEAP]->{server}->put('set/nofilter');
       $_[HEAP]->{server}->put('set/filter DXBM/OFF');
       $_[HEAP]->{server}->put('set/filter DXBM/REJECT VHF');
       $_[HEAP]->{server}->put('set/filter doc/pass k,xe,ve');
       print "Waiting 5 seconds to sync cluster data stream...\n";
       sleep(5);
       print "Mode = $mode\n" if $verbose; 
       given ($mode){
       	when (MODE_CW){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 80-CW,40-CW,20-CW,15-CW,10-CW');}
       	when (MODE_SSB){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 80-SSB,40-SSB,20-SSB,15-SSB,10-SSB');}
       	when (MODE_RTTY){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 80-RTTY,40-RTTY,20-RTTY,15-RTTY,10-RTTY');}
       }
       
       given ($contestInfo{SOURCE}){
          when (SOURCE_US){$_[HEAP]->{server}->put('set/filter K/PASS');}
   	 }
       if (defined $options{'x'}){
          sleep(5);
          $_[HEAP]->{server}->put('set/skimmer');
       } else {
          $_[HEAP]->{server}->put('set/noskimmer');
       }
       
       print "Contest = $contestInfo{'MULTS'}\n" if $verbose;    
       given ($contestInfo{'MULTS'}){
       	when (MULT_ARRL){
       		sleep(5);
       		print "Setting DXBM to ARRL Sections.\n" if $verbose;
       		$_[HEAP]->{server}->put('set/filter DXCTY/PASS K,VE,KH6,KL,KP2,KP4');
       	}
       }
       
       given ($contestInfo{CONTEST}){
          when(/ARRL160/){
          	$_[HEAP]->{server}->put('set/filter DXBM/OFF');
          	sleep(3);
          	$_[HEAP]->{server}->put('set/filter DXBM/PASS 160'); 
          	sleep(3);
          	given ($mode){
       			when (MODE_CW){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-CW');}
       			when (MODE_SSB){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-SSB');}
       			when (MODE_RTTY){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-RTTY');}
       		}
          	
          }
          when(/CQ160/){
          	$_[HEAP]->{server}->put('set/filter DXBM/OFF');
          	sleep(3);
          	$_[HEAP]->{server}->put('set/filter DXBM/PASS 160');
          	sleep(3); 
          	given ($mode){
       			when (MODE_CW){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-CW');}
       			when (MODE_SSB){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-SSB');}
       			when (MODE_RTTY){ $_[HEAP]->{server}->put('set/filter DXBM/PASS 160-RTTY');}
       		}
       		sleep(3);
          }
          when (/ARRL10/){
          	$_[HEAP]->{server}->put('set/filter DXBM/OFF');
          	$_[HEAP]->{server}->put('set/filter DXBM/PASS 10-CW,10-SSB'); 
          }
       }
       sleep(5);
       $_[HEAP]->{server}->put('show/filter DXBM');
       $_[HEAP]->{server}->put('show/mydx');
    }
    
   &LoadSectionsWorked(); # Add code to do this every 10 spots 
   
   if ($buf =~ /DX de/){
      my ($source,$aspace,$freq,$bspace,$call,$cspace,$comment,$dspace,$spotTime) = unpack($format,$buf);
      if ($source =~ /#/){
         return unless (defined $options{'x'});
      }
      return if ($call =~ /\//); # Skip portables as we can't easily guess location
      if ($call =~ /^[AWKN]\d[A-Z]$/){ # Skip 1x1 calls
      	print "Skipping 1x1 call $call\n" if $verbose;
      	return;
      }
      #return if ($call =~ /K7E|W2GD/);
      my @dxcc = &dxcc($call);
      #my $listing = GetQRZRecord($call);
      #return unless $listing->{FOUND};
      #$section = $listing->{section};
      #print "-----------After GetQRZRecord---------\n" if $verbose;
      #print Dumper($listing) if $verbose;
      if (1) { #defined $listing){
         print "DXCC = $dxcc[0]\n" if $verbose;
         if ($dxcc[0] =~ /United States|Hawaii|Alaska|Canada|Puerto Rico|Virgin Is./i) {
      	    print "Processing $call as ".$dxcc[0]." call\n" if $verbose;
      	    my $listing = GetQRZRecord($call);
      	    return unless $listing->{FOUND};
      	    $section = $listing->{section};
      	    #return unless (defined $section); # This should only be done if section is critical (e.g. ARRLSS)
      	    if ($section =~ /YT/){ # Fix until HamReference module is fixed
      	       $section = "NT";
      	    }
      	    if ($section =~ /NB/){ # Fix until HamReference module is fixed
	        $section = "MAR";
      	    }
      	    if (defined $options{'s'}) { 
      	       #   my $state = '';
	       if (defined ($listing->{state})) {
	          $state = $listing->{state}; 
	       } else {
	          print "Could not retrieve state for $call from QRZ\n";
		  return;
	          $state = "No State";
               }
      	       $newComment = "[$state] $comment";
      	    } else {
      	       if (defined $section) {
      	          $newComment = "[$section]  $comment";
      	       }
      	       else {
      	          my $county = $listing->{county};
      	          print "Could not find ARRL section for $call in $county.\n" if defined($county);
      	          print Dumper($listing) if $verbose;
      	       } 
			}
			
		 } else { # No US/VE callsign
		   $newComment = "[".$dxcc[0]."] $comment";
		 }
		 if ($LOTWUsers{$call}){
	    	 $lotw = 1;
	       $newComment = "*".$newComment;
	    }
	     
	     
	     if ($cached){
	        $newComment = "-".$newComment;
	        $cached = 0;
	     } 
	  } else { # No QRZ Record
	     print "Could not retreive QRZ record for $call\n";
	     return;
	     $newComment = "[". $dxcc[0] . "] $comment";
	  }
	  
	  $band = FrequencyToBand($freq);
	  #&LoadActiveBand();
	  #if (defined $activeBand){
	  #   return unless ($band eq $activeBand);
	  #}
	  $buf = pack $format, $source,$aspace,$freq,$bspace,$call,$cspace,$newComment,$dspace,$spotTime;
	  
	  # If the section is NOT in the hash, then show it.
	  print "Checking if >$section< is in sectionsWorked array\n" if $verbose;
	  #print @sectionsWorked;
	  if (defined $options{'w'}){
	     # See if the comment has a section in it.
	     $trimmedComment = &trim($comment);
	     if (exists $validSections{$trimmedComment}){
	        $section = $trimmedComment;
	        print "Found section $trimmedComment in comments section >$comment<\n" if $verbose;
	     }
	     if (defined $section && exists $sectionsWorked{$section}){
	  	print "Skipping $section as previously worked\n" if $verbose;
	  	return;
	     }
	  }
	   
	   
	  if ($onlyLOTW) {
		 return unless ($lotw == 1); 
	  }
	  
	  if (defined $options{'n'}){
	     print "Check $band and $state against Needed table\n" if $verbose;
	     return unless ($Needed{($band.$state)});
	  }
	  
	  &Alert() if $soundAlert;
	  print "$buf"."Z\n";
	  broadcast("$buf"."Z"); # Send to all connected clients
   } else {
   	 print "$buf\n";
   }
}

sub Alert()
{
	#beep(1200,400);
	#beep(1,250);
	#beep(1200,250);
	#beep(1,250);
	#beep(1200,400);
}
sub FrequencyToBand()
{
   my $freq = shift;
   return 160 if ($freq > 1800 && $freq < 2000);
   return 80 if ($freq > 3500 && $freq < 4000);
   return 40 if ($freq > 7000 && $freq < 7350);
   return 20 if ($freq > 14000 && $freq < 14350);
   return 15 if ($freq > 21000 && $freq < 21450);
   return 10 if ($freq > 28000 && $freq < 29800);
}
  
sub GetQRZRecord()
{
	my ($call) = @_;
	
	#my $section;
	my $listing = $cache->get($call);
	if (not defined $listing) {
		print "$call NOT in cache...calling QRZ.\n" if $verbose;
		$qrz->set_callsign($call);
		$listing = $qrz->get_listing;
		if ( $qrz->is_error ) {
	   	my $err_msg = $qrz->error_message;
	   	print "QRZ error message = $err_msg\n" if $verbose;
	   	given ($err_msg){
	   		when (/Session Timeout/){
	   			print "QRZ session timed out - Login reinitiated\n";
	      		$qrz->login;
		  			$qrz->set_callsign($call);
		  			$listing = $qrz->get_listing; # Primes the pump
		  			return $listing if ($qrz->is_error);
		  		}
		  		when (/Not found/){
		  			print "QRZ entry for $call not found\n" if $verbose;
		  			$listing->{FOUND} = 0;
		  		}
		  	}	  	
		} else {
			$listing->{FOUND} = 1;
		}
		# Now get the rest...
		print "ADDING $call to cache.\n" if $verbose;
		$listing->{section} = $qrz->get_arrl_section();
		if (defined($listing->{lotw})){
			print "lotw is defined and is $listing->{lotw}\n" if $verbose;
			if ($listing->{lotw} =~ /0/){
		   	if ($LOTWUsers{$call}){
		   		$listing->{lotw} = "1";
		   		print "LOTW found in QRZ record. Adding $call to LOTWUsers hash\n" if $verbose;
					$LOTWUsers{$call} = 1;
		   	}
			}
		} 
		$cache->set($call, $listing);
	} else {
	   print "$call was in cache.\n" if $verbose;
	   # See if valid listing
	   $cached = 1;
	}
	return ($listing);
}


sub CheckContest()
{
   my $contest;
   my %contestInfo;
   if (defined $options{'t'}){
	  given ($options{'t'}){
	    when (/ARRL10/){
	    	$contest = "ARRL 10 Meters";
	    	$contestInfo{MULTS} = MULT_ALL;
	    	$contestInfo{SOURCE} = SOURCE_US_VE;
	    	$contestInfo{BAND} = "10";
	    }
	    when(/ARRLSS/){
	    	$contest = "ARRL Sweepstakes";
	    	$contestInfo{MULTS} = MULT_ARRL;
	    }
	    when(/NAQP/){
	    	$contest = "North American QSO Party";
	    	$contestInfo{MULTS} = MULT_ARRL;
	    }
	    when(/ARRL160/){
	    	$contest = "ARRL 160m";
	    	$contestInfo{MULTS} = MULT_ARRL;
	    	$contestInfo{BAND} = "160";
	    	$mode = MODE_CW;
	    }
	    when (/CQWW/){
	    	$contest = "CQ Worldwide DX";
	    	$contestInfo{MULTS} = MULT_ALL;
	    	$contestInfo{SOURCE} = SOURCE_US;
	    }
	    when (/CQ160/){
	    	$contest = "CQ 160";
	    	$contestInfo{MULTS} = MULT_ALL;
	    	$contestInfo{SOURCE} = SOURCE_US;
	    }
	    when (/CQWPX/){
	    	$contest = "CQ WPX";
	    	$contestInfo{MULTS} = MULT_ALL;
	    }
	    when (/QSOPARTY/){
	    	$contest = "QSO Party";
	    	$contestInfo{MULTS} = MULT_ALL;
	    	$contestInfo{SOURCE} = SOURCE_US;
	    }
	    when (/ARRLDX/){
	    	$contest = "ARRL DX";
	    	$contestInfo{MULTS} = MULT_DX;
	    }
	    default {
	    	$contest = "None";
	    	$contestInfo{MULTS} = MULT_ALL;
	    }
	  }
	} else {
	   $contest = "None";
	   $contestInfo{MULTS} = MULT_ALL;
	}
	$contestInfo{CONTEST} = $contest;
	return $contest,%contestInfo;
}

# Perl trim function to remove whitespace from the start and end of the string
sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}
# Left trim function to remove leading whitespace
sub ltrim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	return $string;
}
# Right trim function to remove trailing whitespace
sub rtrim($)
{
	my $string = shift;
	$string =~ s/\s+$//;
	return $string;
}
 
sub CheckMode()
{
	my $mode = 0;
	if (defined $options{'m'}){
		given ($options{'m'}){
			when (/CW|code|morse|a1|a1a/i){ $mode = MODE_CW;}
			when (/SSB|PH|PHONE|VOICE|USB|LSB/i){ $mode = MODE_SSB;}
			when (/RTTY|PSK|FSK|PSK31|PSK63/i){ $mode = MODE_RTTY;}
			default {$mode = MODE_ALL;}
		}
	} else {
	   $mode = MODE_ALL;
	}
	return $mode;
}   

sub Usage {
   print "Usage: QRZCluster.pl -h <servername>[:<port>] -u <QRZ Username> -p <QRZ Password> -c <MyCall for cluster> -t <Contest Name> -m <Mode>\n";
   print "   where:\n";
   print "   <servername> is the DX Cluster\n";
   print "   <port> is the TCP/IP to connect to the cluster with [default=23]\n";
   print "   <QRZ Username> is your QRZ subscription username\n";
   print "   <QRZ password> is your QRZ subsciption password\n";
   print "      REMEMBER: YOU MUST BE AT LEAST AN XML SUBSCRIBER ON QRZ FOR THIS TO WORK\n\n";
   print "   <MyCall for cluster> is the call to connect to the cluster\n";
   print "      Note that is -c is used, the program adds -9 to the call to avoid conflicts\n";
   print "   <Contest Name> is one of the following:\n";
   print "       ARRLSS, CQWW, ARRLDX, CQWPX\n";
   print "   <Mode> = CW, RTTY, or SSB\n";  
   print "\n";
   print "   This program will add the ARRL Section to the beginning of the spot or if a DX station, \n";
   print "   it will add the country. If the spot has an asterisk (*) in front of the comment, that means\n";
   print "   the callsign uses LOTW\n";
   print "   if the -s option is used, then the state/providence will be displayed instead of the section\n";
   print "   If the -t option is used with a callsign, this is the call that will be used to connect to the cluster.\n";
   print "       Note if there is not a -<number> in the call, a -9 will be added.\n";
   print "   If -l is used, then only station that use LOTW are displayed\n";
   print "   If -x is used, then CW Skimmer stations are displayed\n";
   print "   If -n is used, then only NEEDED spots are shown\n";
   print "     Note that needed spots have to be setup in the script currently\n";
   
   #print "Dependencies...\n";
   #print join("\n", map { s|/|::|g; s|\.pm$||; $_ } keys %INC);
   #foreach (sort keys %INC) {print "$_\n"}
   exit;
}		

sub wpx {
  my ($prefix,$a,$b,$c);
  
  # First check if the call is in the proper format, A/B/C where A and C
  # are optional (prefix of guest country and P, MM, AM etc) and B is the
  # callsign. Only letters, figures and "/" is accepted, no further check if the
  # callsign "makes sense".
  # 23.Apr.06: Added another "/X" to the regex, for calls like RV0AL/0/P
  # as used by RDA-DXpeditions....
    
if ($_[0] =~ 
	/^((\d|[A-Z])+\/)?((\d|[A-Z]){3,})(\/(\d|[A-Z])+)?(\/(\d|[A-Z])+)?$/) {
   
    # Now $1 holds A (incl /), $3 holds the callsign B and $5 has C
    # We save them to $a, $b and $c respectively to ensure they won't get 
    # lost in further Regex evaluations.
   
    ($a, $b, $c) = ($1, $3, $5);
    if ($a) { chop $a };            # Remove the / at the end 
    if ($c) { $c = substr($c,1,)};  # Remove the / at the beginning
    
    # In some cases when there is no part A but B and C, and C is longer than 2
    # letters, it happens that $a and $b get the values that $b and $c should
    # have. This often happens with liddish callsign-additions like /QRP and
    # /LGT, but also with calls like DJ1YFK/KP5. ~/.yfklog has a line called    
    # "lidadditions", which has QRP and LGT as defaults. This sorts out half of
    # the problem, but not calls like DJ1YFK/KH5. This is tested in a second
    # try: $a looks like a call (.\d[A-Z]) and $b doesn't (.\d), they are
    # swapped. This still does not properly handle calls like DJ1YFK/KH7K where
    # only the OP's experience says that it's DJ1YFK on KH7K.

if (!$c && $a && $b) {                  # $a and $b exist, no $c
        if ($b =~ /$lidadditions/) {    # check if $b is a lid-addition
            $b = $a; $a = undef;        # $a goes to $b, delete lid-add
        }
        elsif (($a =~ /\d[A-Z]+$/) && ($b =~ /\d$/)) {   # check for call in $a
        }
}    

	# *** Added later ***  The check didn't make sure that the callsign
	# contains a letter. there are letter-only callsigns like RAEM, but not
	# figure-only calls. 

	if ($b =~ /^[0-9]+$/) {			# Callsign only consists of numbers. Bad!
			return undef;			# exit, undef
	}

    # Depending on these values we have to determine the prefix.
    # Following cases are possible:
    #
    # 1.    $a and $c undef --> only callsign, subcases
    # 1.1   $b contains a number -> everything from start to number
    # 1.2   $b contains no number -> first two letters plus 0 
    # 2.    $a undef, subcases:
    # 2.1   $c is only a number -> $a with changed number
    # 2.2   $c is /P,/M,/MM,/AM -> 1. 
    # 2.3   $c is something else and will be interpreted as a Prefix
    # 3.    $a is defined, will be taken as PFX, regardless of $c 

    if ((not defined $a) && (not defined $c)) {  # Case 1
            if ($b =~ /\d/) {                    # Case 1.1, contains number
                $b =~ /(.+\d)[A-Z]*/;            # Prefix is all but the last
                $prefix = $1;                    # Letters
            }
            else {                               # Case 1.2, no number 
                $prefix = substr($b,0,2) . "0";  # first two + 0
            }
    }        
    elsif ((not defined $a) && (defined $c)) {   # Case 2, CALL/X
           if ($c =~ /^(\d)$/) {              # Case 2.1, number
                $b =~ /(.+\d)[A-Z]*/;            # regular Prefix in $1
                # Here we need to find out how many digits there are in the
                # prefix, because for example A45XR/0 is A40. If there are 2
                # numbers, the first is not deleted. If course in exotic cases
                # like N66A/7 -> N7 this brings the wrong result of N67, but I
                # think that's rather irrelevant cos such calls rarely appear
                # and if they do, it's very unlikely for them to have a number
                # attached.   You can still edit it by hand anyway..  
                if ($1 =~ /^([A-Z]\d)\d$/) {        # e.g. A45   $c = 0
                                $prefix = $1 . $c;  # ->   A40
                }
                else {                         # Otherwise cut all numbers
                $1 =~ /(.*[A-Z])\d+/;          # Prefix w/o number in $1
                $prefix = $1 . $c;}            # Add attached number    
            } 
            elsif ($c =~ /$csadditions/) {
                $b =~ /(.+\d)[A-Z]*/;       # Known attachment -> like Case 1.1
                $prefix = $1;
            }
            elsif ($c =~ /^\d\d+$/) {		# more than 2 numbers -> ignore
                $b =~ /(.+\d)[A-Z]*/;       # see above
                $prefix = $1;
			}
			else {                          # Must be a Prefix!
                    if ($c =~ /\d$/) {      # ends in number -> good prefix
                            $prefix = $c;
                    }
                    else {                  # Add Zero at the end
                            $prefix = $c . "0";
                    }
            }
    }
    elsif (defined $a) {                    # $a contains the prefix we want
            if ($a =~ /\d$/) {              # ends in number -> good prefix
                    $prefix = $a
            }
            else {                          # add zero if no number
                    $prefix = $a . "0";
            }
    }

# In very rare cases (right now I can only think of KH5K and KH7K and FRxG/T
# etc), the prefix is wrong, for example KH5K/DJ1YFK would be KH5K0. In this
# case, the superfluous part will be cropped. Since this, however, changes the
# DXCC of the prefix, this will NOT happen when invoked from with an
# extra parameter $_[1]; this will happen when invoking it from &dxcc.
    
if (($prefix =~ /(\w+\d)[A-Z]+\d/) && (not defined $_[1])) {
        $prefix = $1;                
}
    
return $prefix;
}
else { return ''; }    # no proper callsign received.
} # wpx ends here


##############################################################################
#
# &dxcc determines the DXCC country of a given callsign using the cty.dat file
# provided by K1EA at http://www.k1ea.com/cty/cty.dat .
# An example entry of the file looks like this:
#
# Portugal:                 14:  37:  EU:   38.70:     9.20:     0.0:  CT:
#     CQ,CR,CR5A,CR5EBD,CR6EDX,CR7A,CR8A,CR8BWW,CS,CS98,CT,CT98;
#
# The first line contains the name of the country, WAZ, ITU zones, continent, 
# latitude, longitude, UTC difference and main Prefix, the second line contains 
# possible Prefixes and/or whole callsigns that fit for the country, sometimes 
# followed by zones in brackets (WAZ in (), ITU in []).
#
# This sub checks the callsign against this list and the DXCC in which 
# the best match (most matching characters) appear. This is needed because for 
# example the CTY file specifies only "D" for Germany, "D4" for Cape Verde.
# Also some "unusual" callsigns which appear to be in wrong DXCCs will be 
# assigned properly this way, for example Antarctic-Callsigns.
# 
# Then the callsign (or what appears to be the part determining the DXCC if
# there is a "/" in the callsign) will be checked against the list of prefixes
# and the best matching one will be taken as DXCC.
#
# The return-value will be an array ("Country Name", "WAZ", "ITU", "Continent",
# "latitude", "longitude", "UTC difference", "DXCC").   
#
###############################################################################

sub dxcc {
	my $testcall = shift;
	my $matchchars=0;
	my $matchprefix='';
	my $test;
	my $zones = '';                 # annoying zone exceptions
	my $goodzone;
	my $letter='';


if ($testcall =~ /(^OH\/)|(\/OH[1-9]?$)/) {    # non-Aland prefix!
    $testcall = "OH";                      # make callsign OH = finland
}
elsif ($testcall =~ /(^3D2R)|(^3D2.+\/R)/) { # seems to be from Rotuma
    $testcall = "3D2RR";                 # will match with Rotuma
}
elsif ($testcall =~ /^3D2C/) {               # seems to be from Conway Reef
    $testcall = "3D2CR";                 # will match with Conway
}
elsif ($testcall =~ /\w\/\w/) {             # check if the callsign has a "/"
    $testcall = &wpx($testcall,1)."AA";		# use the wpx prefix instead, which may
                                         # intentionally be wrong, see &wpx!
}

$letter = substr($testcall, 0,1);

foreach $mainprefix (keys %prefixes) {

	foreach $test (@{$prefixes{$mainprefix}}) {
		my $len = length($test);

		if ($letter ne substr($test,0,1)) {			# gains 20% speed
			next;
		}

		$zones = '';

		if (($len > 5) && ((index($test, '(') > -1)			# extra zones
						|| (index($test, '[') > -1))) {
				$test =~ /^([A-Z0-9\/]+)([\[\(].+)/;
				$zones .= $2 if defined $2;
				$len = length($1);
		}

		if ((substr($testcall, 0, $len) eq substr($test,0,$len)) &&
								($matchchars <= $len))	{
			$matchchars = $len;
			$matchprefix = $mainprefix;
			$goodzone = $zones;
		}
	}
}

my @mydxcc;										# save typing work

if (defined($dxcc{$matchprefix})) {
	@mydxcc = @{$dxcc{$matchprefix}};
}
else {
	@mydxcc = qw/Unknown 0 0 0 0 0 0 ?/;
}

# Different zones?

if ($goodzone) {
	if ($goodzone =~ /\((\d+)\)/) {				# CQ-Zone in ()
		$mydxcc[1] = $1;
	}
	if ($goodzone =~ /\[(\d+)\]/) {				# ITU-Zone in []
		$mydxcc[2] = $1;
	}
}

# cty.dat has special entries for WAE countries which are not separate DXCC
# countries. Those start with a "*", for example *TA1. Those have to be changed
# to the proper DXCC. Since there are opnly a few of them, it is hardcoded in
# here.

if ($mydxcc[7] =~ /^\*/) {							# WAE country!
	if ($mydxcc[7] eq '*TA1') { $mydxcc[7] = "TA" }		# Turkey
	if ($mydxcc[7] eq '*4U1V') { $mydxcc[7] = "OE" }	# 4U1VIC is in OE..
	if ($mydxcc[7] eq '*GM/s') { $mydxcc[7] = "GM" }	# Shetlands
	if ($mydxcc[7] eq '*IG9') { $mydxcc[7] = "I" }		# African Italy
	if ($mydxcc[7] eq '*IT9') { $mydxcc[7] = "I" }		# Sicily
	if ($mydxcc[7] eq '*JW/b') { $mydxcc[7] = "JW" }	# Bear Island

}

# CTY.dat uses "/" in some DXCC names, but I prefer to remove them, for example
# VP8/s ==> VP8s etc.

$mydxcc[7] =~ s/\///g;

return @mydxcc; 

} # dxcc ends here 

sub LoadActiveBand()
{ # Not yet implemented - TMS 03NOV2013
	my $file = "activeBand.txt";
	undef $activeBand;
	open (FH, "< $file") or return; # "Can't open $file for read: $!";
	$activeBand = &trim($_);
	print "ACTIVE BAND = >$activeBand<\n";
	
	close FH or die "Cannot close $file: $!";
}
sub LoadSectionsWorked()
{
	
	$loopCounter = 0;
	print "Entering LoadSectionsWorked\n" if $verbose;
	my $file = "sectionsWorked.txt";
	open (FH, "< $file") or die "Can't open $file for read: $!";
	%sectionsWorked = (); # Empty the sections worked hash
	while (<FH>) {
	   next if /^#/; # Skip commentedlines
		$loopCounter++;
		chop;
		my $section = uc $_; # Upper case
		$sectionsWorked{$section} = 1;
	}
	close FH or die "Cannot close $file: $!";
	$sectionsWorked{"TOM"} = 1;
	
	die unless (exists $sectionsWorked{"TOM"});
	#if ($workedSectionsCount <> $loopCounter) {
	#   print "Loaded ($loopCounter - $workedSectionsCount) new sections\n";
	#   $workedSectionsCount = $loopCounter;
	#}
	print "Leaving LoadSectionsWorked: $loopCounter items loaded\n" if $verbose;
}
sub LoadLOTWFile()
{
	my %LOTWUsers;
	my $filename;
	if (-e "lotw1.txt"){
		print "\n Loading the HB9BZA LOTW Users file -- Download latest with wget http://www.hb9bza.net/lotw/lotw1.txt\n\n";
		$filename = "lotw1.txt";
		open LOTWUSERS, $filename;
		
		while (my $line = <LOTWUSERS>){
			$line = rtrim($line);
		   $LOTWUsers{$line} = 1;
		   #print "Loading $line into LOTWUsers hash\n" if $verbose;
		}
	}
	print "LOTWUsers test for NY4I = $LOTWUsers{'NY4I'}\n";
	return %LOTWUsers;
}
sub LoadValidSections()
{
	my %validSections;
	#Current section list as of 11/2/2013
	$validSections{"CT"} = 1;
	$validSections{"EMA"} = 1;
	$validSections{"ME"} = 1;
	$validSections{"NH"} = 1;
	$validSections{"RI"} = 1;
	$validSections{"VT"} = 1;
	$validSections{"WMA"} = 1;
	$validSections{"ENY"} = 1;
	$validSections{"NLI"} = 1;
	$validSections{"NNJ"} = 1;
	$validSections{"NNY"} = 1;
	$validSections{"SNJ"} = 1;
	$validSections{"WNY"} = 1;
	$validSections{"DE"} = 1;
	$validSections{"EPA"} = 1;
	$validSections{"MDC"} = 1;
	$validSections{"WPA"} = 1;
	$validSections{"AL"} = 1;
	$validSections{"GA"} = 1;
	$validSections{"KY"} = 1;
	$validSections{"NC"} = 1;
	$validSections{"NFL"} = 1;
	$validSections{"SC"} = 1;
	$validSections{"SFL"} = 1;
	$validSections{"WCF"} = 1;
	$validSections{"TN"} = 1;
	$validSections{"VA"} = 1;
	$validSections{"PR"} = 1;
	$validSections{"VI"} = 1;
	$validSections{"AR"} = 1;
	$validSections{"LA"} = 1;
	$validSections{"MS"} = 1;
	$validSections{"NM"} = 1;
	$validSections{"NTX"} = 1;
	$validSections{"OK"} = 1;
	$validSections{"STX"} = 1;
	$validSections{"WTX"} = 1;
	$validSections{"EB"} = 1;
	$validSections{"LAX"} = 1;
	$validSections{"ORG"} = 1;
	$validSections{"SB"} = 1;
	$validSections{"SCV"} = 1;
	$validSections{"SDG"} = 1;
	$validSections{"SF"} = 1;
	$validSections{"SJV"} = 1;
	$validSections{"SV"} = 1;
	$validSections{"PAC"} = 1;
	$validSections{"AZ"} = 1;
	$validSections{"WWA"} = 1;
	$validSections{"ID"} = 1;
	$validSections{"MT"} = 1;
	$validSections{"NV"} = 1;
	$validSections{"OR"} = 1;
	$validSections{"UT"} = 1;
	$validSections{"WWA"} = 1;
	$validSections{"WY"} = 1;
	$validSections{"AK"} = 1;
	$validSections{"MI"} = 1;
	$validSections{"OH"} = 1;
	$validSections{"WV"} = 1;
	$validSections{"IL"} = 1;
	$validSections{"IN"} = 1;
	$validSections{"WI"} = 1;
	$validSections{"CO"} = 1;
	$validSections{"IA"} = 1;
	$validSections{"KS"} = 1;
	$validSections{"MN"} = 1;
	$validSections{"MO"} = 1;
	$validSections{"NE"} = 1;
	$validSections{"ND"} = 1;
	$validSections{"SD"} = 1;
	$validSections{"MAR"} = 1;
	$validSections{"NL"} = 1;
	$validSections{"QC"} = 1;
	$validSections{"ONN"} = 1;
	$validSections{"ONS"} = 1;
	$validSections{"ONE"} = 1;
	$validSections{"GTA"} = 1;
	$validSections{"MB"} = 1;
	$validSections{"SK"} = 1;
	$validSections{"AB"} = 1;
	$validSections{"BC"} = 1;
	$validSections{"NT"} = 1;
	return %validSections;
}

sub LoadNeeded()
{
	# Band.State
   my %Needed;
   $Needed{("160AK")} = 1;
   $Needed{("160AZ")} = 1;
   $Needed{("160CA")} = 1;
   $Needed{("160CO")} = 1;
   $Needed{("160CT")} = 1;
   $Needed{("160DE")} = 1;
   $Needed{("160HI")} = 1;
   $Needed{("160ID")} = 1;
   $Needed{("160IA")} = 1;
   $Needed{("160KY")} = 1;
   $Needed{("160LA")} = 1;
   $Needed{("160MA")} = 1;
   $Needed{("160MI")} = 1;
   $Needed{("160MT")} = 1;
   $Needed{("160NE")} = 1;
   $Needed{("160NV")} = 1;
   $Needed{("160NH")} = 1;
   $Needed{("160NM")} = 1;
   $Needed{("160NY")} = 1;
   $Needed{("160ND")} = 1;
   $Needed{("160OK")} = 1;
   $Needed{("160OR")} = 1;
   $Needed{("160PA")} = 1;
   $Needed{("160SD")} = 1;
   $Needed{("160UT")} = 1;
   $Needed{("160WA")} = 1;
   $Needed{("160WV")} = 1;
   $Needed{("160WI")} = 1;
   $Needed{("160WY")} = 1;
   
   $Needed{("80AL")} = 1;
   $Needed{("80AZ")} = 1;
   $Needed{("80AR")} = 1;
   $Needed{("80CA")} = 1;
   $Needed{("80CO")} = 1;
   $Needed{("80CT")} = 1;
   $Needed{("80DE")} = 1;
   $Needed{("80ID")} = 1;
   $Needed{("80HI")} = 1;
   $Needed{("80KS")} = 1;
   $Needed{("80KY")} = 1;
   $Needed{("80LA")} = 1;
   $Needed{("80ME")} = 1;
   $Needed{("80MA")} = 1;
   $Needed{("80MI")} = 1;
   $Needed{("80MN")} = 1;
   $Needed{("80MS")} = 1;
   $Needed{("80MO")} = 1;
   $Needed{("80NE")} = 1;
   $Needed{("80NH")} = 1;
   $Needed{("80NJ")} = 1;
   $Needed{("80NM")} = 1;
   $Needed{("80NY")} = 1;
   $Needed{("80ND")} = 1;
   $Needed{("80OH")} = 1;
   $Needed{("80OK")} = 1;
   $Needed{("80OR")} = 1;
   $Needed{("80RI")} = 1;
   $Needed{("80SC")} = 1;
   $Needed{("80SD")} = 1;
   $Needed{("80TN")} = 1;
   $Needed{("80TX")} = 1;
   $Needed{("80WA")} = 1;
   $Needed{("80WV")} = 1;
   
   
   
   
   $Needed{("40CO")} = 1;
   $Needed{("40CT")} = 1;
   $Needed{("40DE")} = 1;
   $Needed{("40LA")} = 1;
   $Needed{("40MI")} = 1;
   $Needed{("40MT")} = 1;
   $Needed{("40MS")} = 1;
   $Needed{("40NE")} = 1;
   $Needed{("40NV")} = 1;
   $Needed{("40ND")} = 1;
   $Needed{("40OR")} = 1;
   $Needed{("40SC")} = 1;
   $Needed{("40VT")} = 1;
   $Needed{("40VA")} = 1;
   $Needed{("40WY")} = 1;
   
   # CW
   $Needed{("20FL")} = 1;
   $Needed{("20ID")} = 1;
   $Needed{("20IA")} = 1;
   $Needed{("20KY")} = 1;
   $Needed{("20LA")} = 1;
   $Needed{("20ME")} = 1;
   $Needed{("20NY")} = 1;
   $Needed{("20SC")} = 1;
   $Needed{("20VT")} = 1;
   $Needed{("20WV")} = 1;
   
   $Needed{("15GA")} = 1;
   $Needed{("15IA")} = 1;
   $Needed{("15KY")} = 1;
   $Needed{("15MS")} = 1;
   $Needed{("15WV")} = 1;
   
   $Needed{("10AL")} = 1;
   $Needed{("10AR")} = 1;
   $Needed{("10CT")} = 1;
   $Needed{("10DE")} = 1;
   $Needed{("10GA")} = 1;
   $Needed{("10IL")} = 1;
   $Needed{("10IN")} = 1;
   $Needed{("10KS")} = 1;
   $Needed{("10LA")} = 1;
   $Needed{("10ME")} = 1;
   $Needed{("10MA")} = 1;
   $Needed{("10MI")} = 1;
   $Needed{("10MS")} = 1;
   $Needed{("10MO")} = 1;
   $Needed{("10NE")} = 1;
   $Needed{("10NH")} = 1;
   $Needed{("10NC")} = 1;
   $Needed{("10ND")} = 1;
   $Needed{("10OH")} = 1;
   $Needed{("10PA")} = 1;
   $Needed{("10RI")} = 1;
   $Needed{("10SC")} = 1;
   $Needed{("10VA")} = 1;
   $Needed{("10WA")} = 1;
   $Needed{("10WV")} = 1;
   $Needed{("10WI")} = 1;
	return %Needed;
}

sub read_cty {
	# Read cty.dat from AD1C, or this program itself (contains cty.dat)
	my $self=0;
	my $filename;
	my $version;
	
	
	# To check the version, use this text from the Revisions page:
	# VER20110117, <a href="index.htm#Version">
	# Revisions Page is at http://www.country-files.com/category/contest/
	# Just check the first one.
	# One other option is to read the file from the Internet itself.
	# Obviously the whole point of this program is that we have Internet access.
	

	if (-e "cty.dat") {
	print "Reading local cty.dat file\n";
		$filename = "cty.dat";
	}
	else {
		$filename = $0;
		$self = 1;
	}

	open CTY, $filename;

	while (my $line = <CTY>) {
		# When opening itself, skip all lines before "CTY".
		if ($self) {
			if ($line =~ /^#CTY/) {
				$self = 0
			}
			next;
		}

		# In case we're reading this file, remove #s
		if (substr($line, 0, 1) eq '#') {
			substr($line, 0, 1) = '';
		}

		if ($line =~ /(VER\d{8})/){
			$version = $1;
		}
		
		
		if (substr($line, 0, 1) ne ' ') {			# New DXCC
			$line =~ /\s+([*A-Za-z0-9\/]+):\s+$/;
			$mainprefix = $1;
			$line =~ s/\s{2,}//g;
			@{$dxcc{$mainprefix}} = split(/:/, $line);
		}
		else {										# prefix-line
			$line =~ s/\s+//g;
			unless (defined($prefixes{$mainprefix}[0])) {
				@{$prefixes{$mainprefix}} = split(/,|;/, $line);
			}
			else {
				push(@{$prefixes{$mainprefix}}, split(/,|;/, $line));
			}
		}
	}
	close CTY;

	return $version;
} # read_cty








exit;
	

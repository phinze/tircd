#!/usr/bin/perl
# tircd - An ircd proxy to the Twitter API
# Copyright (c) 2009 Chris Nelson <tircd@crazybrain.org>
# tircd is free software; you can redistribute it and/or modify it under the terms of either:
# a) the GNU General Public License as published by the Free Software Foundation
# b) the "Artistic License"

use strict;
use JSON::Any;
use Net::Twitter::Lite;
use Time::Local;
use File::Glob ':glob';
use IO::File;
use LWP::UserAgent;
use Storable;
use POE qw(Component::Server::TCP Filter::Stackable Filter::Map Filter::IRCD);
use URI qw/host/;

my $VERSION = 0.8;

# I have no idea what the minimum Net::Twitter::Lite version is
#Do some sanity checks on the environment and warn if not what we want
#if ($Net::Twitter::Lite::VERSION < 2.10) {
#  print "Warning: Your system has an old version of Net::Twitter::Lite.  Please upgrade to the current version.\n";
#}

my $j = JSON::Any->new;
if ($j->handlerType eq 'JSON::Syck') {
  print "Warning: Your system is using JSON::Syck. This will cause problems with character encoding.   Please install JSON::PP or JSON::XS.\n";
}

#load and parse our own very simple config file
#didn't want to introduce another module requirement to parse XML or a YAML file
my $config_file = '/etc/tircd.cfg';
if ($ARGV[0]) {
  $config_file = $ARGV[0];
} elsif (-e 'tircd.cfg') {
  $config_file = 'tircd.cfg';
} elsif (-e bsd_glob('~',GLOB_TILDE | GLOB_ERR).'/.tircd') {
  $config_file = bsd_glob('~',GLOB_TILDE | GLOB_ERR).'/.tircd';
}

open(C,$config_file) || die("$0: Unable to load config file ($config_file): $!\n");
my %config = ();
while (<C>) {
  chomp;
  next if /^#/ || /^$/;
  my ($key,$value) = split(/\s/,$_,2);
  $config{$key} = $value;
}
close(C);

#config file backwards compatibility
$config{'timeline_count'} = 20 if !exists $config{'timeline_count'};

#storage for connected users
my %users;

#setup our filter to process the IRC messages, jacked from the Filter::IRCD docs
my $filter = POE::Filter::Stackable->new();
$filter->push( POE::Filter::Line->new( InputRegexp => '\015?\012', OutputLiteral => "\015\012" ));
#twitter's json feed escapes < and >, let's fix that
$filter->push( POE::Filter::Map->new(Code => sub {
  local $_ = shift;
  s/\&lt\;/\</g;
  s/\&gt\;/\>/g;
  s/\&quot\;/\"/g;
  return $_;
}));
if ($config{'debug'} > 1) {
  $filter->push(POE::Filter::IRCD->new(debug => 1));
} else {
  $filter->push(POE::Filter::IRCD->new(debug => 0));
}

# if configured to use SSL, and no env vars yet defined, set to config settings
if ($config{'use_ssl'} == 1 && !($ENV{'HTTPS_CA_FILE'} || $ENV{'HTTPS_CA_DIR'})) {
	if ($config{'https_ca_file'} and -e $config{'https_ca_file'}) {
		$ENV{'HTTPS_CA_FILE'} = $config{'https_ca_file'};
	} elsif ($config{'https_ca_dir'} && -d $config{'https_ca_dir'}) {
		$ENV{'HTTPS_CA_DIR'} = $config{'https_ca_dir'};
	}
}

#if needed setup our logging sesstion
if ($config{'logtype'} ne 'none') {
  POE::Session->create(
      inline_states => {
        _start => \&logger_setup,
        log => \&logger_log
      },
      args => [$config{'logtype'},$config{'logfile'}]
  );
}

#setup our 'irc server'
POE::Component::Server::TCP->new(
  Alias			=> "tircd",              
  Address		=> $config{'address'},
  Port			=> $config{'port'},
  InlineStates		=> { 
    PASS => \&irc_pass, 
    NICK => \&irc_nick, 
    USER => \&irc_user,
    MOTD => \&irc_motd, 
    MODE => \&irc_mode, 
    JOIN => \&irc_join,
    PART => \&irc_part,
    WHO  => \&irc_who,
    WHOIS => \&irc_whois,
    PRIVMSG => \&irc_privmsg,
    STATS => \&irc_stats,
    INVITE => \&irc_invite,
    KICK => \&irc_kick,
    QUIT => \&irc_quit,
    PING => \&irc_ping,
    AWAY => \&irc_away,
    TOPIC => \&irc_topic,

    '#twitter' => \&channel_twitter,
    
    server_reply => \&irc_reply,
    user_msg	 => \&irc_user_msg,

    twitter_api_error => \&twitter_api_error,    
    twitter_timeline => \&twitter_timeline,
    twitter_direct_messages => \&twitter_direct_messages,
    twitter_search => \&twitter_search,
    
    login => \&tircd_login,
    getfriend => \&tircd_getfriend,
    remfriend => \&tircd_remfriend,
    updatefriend => \&tircd_updatefriend,
    getfollower => \&tircd_getfollower,

    
  },
  ClientFilter		=> $filter, 
  ClientInput		=> \&irc_line,
  ClientConnected    	=> \&tircd_connect,
  ClientDisconnected	=> \&tircd_cleanup,
  Started 		=> \&tircd_setup
);    

$poe_kernel->run();                                                                
exit 0; 

########## STARTUP FUNCTIONS BEGIN

sub tircd_setup {
  $_[KERNEL]->call('logger','log',"tircd $VERSION started, using config from: $config_file.");
  $_[KERNEL]->call('logger','log',"Listening on: $config{'address'}:$config{'port'}."); 
}

#setup our logging session
sub logger_setup {
  my ($kernel, $heap, $type, $file) = @_[KERNEL, HEAP, ARG0, ARG1];
  $_[KERNEL]->alias_set('logger');
  
  my $handle = 0;
  if ($type eq 'file') {
    $handle = IO::File->new(">>$file");
  } elsif ($type eq 'stdout') {
    $handle = \*STDOUT;
  } elsif ($type eq 'stderr') {
    $handle = \*STDERR;
  }
  
  if ($handle) {
    #Win32 seems to blow up when trying to set FIONBIO on STDOUT/ERR
    $heap->{'file'} = ($^O eq 'MSWin32' && $type ne 'file') ? $handle : POE::Wheel::ReadWrite->new( Handle => $handle );
  }
}

########## 'INTERNAL' UTILITY FUNCTIONS
#log a message
sub logger_log {
  my ($heap, $msg, $from) = @_[HEAP, ARG0, ARG1];
  return if ! $heap->{'file'};
  
  $from = "[$from] " if defined $from;
  my $stamp = '['.localtime().'] ';
  if (ref $heap->{'file'} eq 'POE::Wheel::ReadWrite')  {
    $heap->{'file'}->put("$stamp$from$msg");
  } else {
    $heap->{'file'}->print("$stamp$from$msg\n");
  }
}

#trap twitter api errors
sub twitter_api_error {
  my ($kernel,$heap, $msg, $error) = @_[KERNEL, HEAP, ARG0, ARG1];
  
  if ($config{'debug'}) {
    $kernel->post('logger','log',$error->message().' '.$error->code().' '.$error,'debug/twitter_api_error');
  }

  $kernel->post('logger','log',$msg.' ('.$error->code() .' from Twitter API).',$heap->{'username'});  

  if ($error->code() == 400) {
    $msg .= ' Twitter API limit reached.';
  } else {
    $msg .= ' Twitter Fail Whale.';
  }
  $kernel->yield('server_reply',461,'#twitter',$msg);
}

#update a friend's info in the heap
sub tircd_updatefriend {
  my ($heap, $new) = @_[HEAP, ARG0];  

  foreach my $friend (@{$heap->{'friends'}}) {
    if ($friend->{'id'} == $new->{'id'}) {
      $friend = $new;
      return 1;
    }
  }
  return 0;
}

#check to see if a given friend exists, and return it
sub tircd_getfriend {
  my ($heap, $target) = @_[HEAP, ARG0];
  
  foreach my $friend (@{$heap->{'friends'}}) {
    if ($friend->{'screen_name'} eq $target) {
      return $friend;
    }
  }
  return 0;
}

sub tircd_getfollower {
  my ($heap, $target) = @_[HEAP, ARG0];
  
  foreach my $follower (@{$heap->{'followers'}}) {
    if ($follower->{'screen_name'} eq $target) {
      return $follower;
    }
  }
  return 0;
}

sub tircd_remfriend {
  my ($heap, $target) = @_[HEAP, ARG0];
  
  my @tmp = ();
  foreach my $friend (@{$heap->{'friends'}}) {
    if ($friend->{'screen_name'} ne $target) {
      push(@tmp,$friend);
    }
  }
  $heap->{'friends'} = \@tmp;
}

#called once we have a user/pass, attempts to auth with twitter
sub tircd_login {
	my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

	if ($heap->{'twitter'}) { #make sure we aren't called twice
		return;
	}

	# unless we have a bundle or directory of certs to verify against, ssl is b0rked
	if ($config{'use_ssl'}) {
		unless($ENV{'HTTPS_CA_FILE'} or $ENV{'HTTPS_CA_DIR'}) {
			$kernel->yield('logger','log',"You must provide the environment variable HTTPS_CA_FILE or HTTPS_CA_DIR before starting tircd.pl in order to verify SSL certificates.");
			$kernel->yield('server_reply',462,'Unable to verify SSL certificate');
			$kernel->yield('shutdown'); #disconnect 'em if we cant
				return;
		}
	}

	# base Net::Twitter::Lite object, add credentials after (possible) ssl check
	my $twitter = Net::Twitter::Lite->new(ssl=> $config{'use_ssl'}, source => 'tircd');
	# check ssl cert using LWP
	my $sslcheck = LWP::UserAgent->new;
	my $apiurl = URI->new($twitter->{'apiurl'});
	# second level domain, aka domain.tld. if this is present in the certificate, we are happy
	my $SLD = $apiurl->host;
	$SLD =~ s/.*\.([^.]*\.[^.]*)/$1/;;



	# if-ssl-cert-subject causes the certificate subject line to be checked against the regex in its value
	# upon checking the certificate, it will cancel the request and set the HTTP::Response is_error to 1 for us
	$sslcheck->default_header("If-SSL-Cert-Subject" => "CN=(.*\.){0,1}$SLD");
	# knock politely
	my $sslresp = $sslcheck->get($apiurl); 
	print $apiurl . "\n";

	# cert failed to verify against local bundle/ca_dir
	if( $sslresp->header('client-ssl-warning') ) {
		$kernel->yield('logger','log',"Unable to verify server certificate against local authority.");
		$kernel->yield('server_reply',462,'Unable to verify SSL certificate.');
		$kernel->yield('shutdown'); 
		return;
	}

	# cert response failed to be for expected domain
	if( $sslresp->is_error && $sslresp->code == 500 ) {
		$kernel->yield('logger','log',"Hostname (CN) of SSL certificate did not match domain being accessed, someone is doing something nasty!");
		$kernel->yield('server_reply',462,'SSL certificate has invalid Common Name (CN).');
		$kernel->yield('shutdown'); 
		return;
	}



	#start up the twitter interface, and see if we can connect with the given NICK/PASS INFO
	$twitter->credentials($heap->{'username'}, $heap->{'password'});
	if (!eval { $twitter->verify_credentials() }) {
		$kernel->post('logger','log','Unable to login to Twitter with the supplied credentials.',$heap->{'username'});
		$kernel->yield('server_reply',462,'Unable to login to Twitter with the supplied credentials.');
		$kernel->yield('shutdown'); #disconnect 'em if we cant
			return;
	}

	$kernel->post('logger','log','Successfully authenticated with Twitter.',$heap->{'username'});

	#stash the twitter object for use in the session  
	$heap->{'twitter'} = $twitter;

	#stash the username in a list to keep 'em from rejoining
	$users{$heap->{'username'}} = 1;

	#load our configs from disk if they exist
	if (-d $config{'storage_path'}) {
		$heap->{'config'}   = eval {retrieve($config{'storage_path'} . '/' . $heap->{'username'} . '.config');};
		$heap->{'channels'} = eval {retrieve($config{'storage_path'} . '/' . $heap->{'username'} . '.channels');};
	} 

	my @user_settings = qw(update_timeline update_directs timeline_count long_messages min_length join_silent filter_self shorten_urls convert_irc_replies);

	# copy base config for user if prior config failed to exist/retrieve
	if (!$heap->{'config'}) {
		my %copy = %config;
		$heap->{'config'} = \%copy;
	}
	foreach my $s (@user_settings) {
		if (!$heap->{'config'}->{$s}) {
			$heap->{'config'}->{$s} = $config{$s};
		}
	}
	foreach my $k (keys %{$heap->{'config'}}) {
		if (!grep($_ eq $k, @user_settings)) {
			delete $heap->{'config'}->{$k};
		}
	}

	if (!$heap->{'channels'}) {
		$heap->{'channels'} = {};
	}

	#we need this for the tinyurl support and others
	$heap->{'ua'} = LWP::UserAgent->new;
	$heap->{'ua'}->timeout(10);
	$heap->{'ua'}->env_proxy();

	#some clients need this shit
	$kernel->yield('server_reply','001',"Welcome to tircd $heap->{'username'}");
	$kernel->yield('server_reply','002',"Your host is tircd running version $VERSION");
	$kernel->yield('server_reply','003',"This server was created just for you!");
	$kernel->yield('server_reply','004',"tircd $VERSION i int");

	#show 'em the motd
	$kernel->yield('MOTD');  
}

sub tircd_connect {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $kernel->post('logger','log',$heap->{'remote_ip'}.' connected.');
}


sub tircd_cleanup {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $kernel->post('logger','log',$heap->{'remote_ip'}.' disconnected.',$heap->{'username'});
  
  #delete the username
  delete $users{$heap->{'username'}};

  #remove our timers so the session will die
  $kernel->delay('twitter_timeline');  
  $kernel->delay('twitter_direct_messages');

  # if storage_path directory doesn't exist, attempt to create
  unless ( -e $config{'storage_path'} && -d $config{'storage_path'} ) {
	  mkdir $config{'storage_path'};
	  if ($!) {
		  $kernel->post('logger','log','Was unable to create storage_dir at ' . $config{'storage_path'} . '.' . $!);  
	  }
  }
  
  #if defined, save our data for next time
  if ($config{'storage_path'} && -d $config{'storage_path'} && -w $config{'storage_path'}) {
    #mark all channels as not joined for the next reload
    foreach my $chan (keys %{$heap->{'channels'}}) {
        $heap->{'channels'}->{$chan}->{'joined'} = 0;
    }
    eval {store($heap->{'config'},$config{'storage_path'} . '/' . $heap->{'username'} . '.config');};
    eval {store($heap->{'channels'},$config{'storage_path'} . '/' . $heap->{'username'} . '.channels');};
  } else {
    $kernel->post('logger','log','storage_path is not set or is not writable, not saving configuration.',$heap->{'username'});  
  }
  $kernel->yield('shutdown');
}


########## 'INTERNAL' IRC I/O FUNCTIONS
#called everytime we get a line from an irc server
#trigger an event and move on, the ones we care about will get trapped
sub irc_line {
  my  ($kernel, $data) = @_[KERNEL, ARG0];
  if ($config{'debug'}) {
    if (!$data->{'params'}) {
      $data->{'params'} = [];
    }
    $kernel->post('logger','log',$data->{'prefix'}.' '.$data->{'command'}.' '.join(' ',@{$data->{'params'}}),'debug/irc_line');
  }
  $kernel->yield($data->{'command'},$data); 
}

#send a message that looks like it came from a user
sub irc_user_msg {
  my ($kernel, $heap, $code, $username, @params) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2..$#_];

  foreach my $p (@params) { #fix multiline tweets, submitted a patch to Filter::IRCD to fix this in the long term
    $p =~ s/\n/ /g;
  }

  if ($config{'debug'}) {
    $kernel->post('logger','log',$username.' '.$code.' '.join(' ',@params),'debug/irc_user_msg');
  }

  $heap->{'client'}->put({
    command => $code,
    prefix => "$username!$username\@twitter",
    params => \@params
  });
}

#send a message that comes from the server
sub irc_reply {
  my ($kernel, $heap, $code, @params) = @_[KERNEL, HEAP, ARG0, ARG1..$#_];

  foreach my $p (@params) {
    $p =~ s/\n/ /g;
  }

  if ($code ne 'PONG' && $code ne 'MODE' && $code != 436) {
    unshift(@params,$heap->{'username'}); #prepend the target username to the message;
  }

  if ($config{'debug'}) {
    $kernel->post('logger','log',':tircd '.$code.' '.join(' ',@params),'debug/irc_reply');
  }

  $heap->{'client'}->put({
    command => $code,
    prefix => 'tircd', 
    params => \@params     
  }); 
}


########### IRC EVENT FUNCTIONS

sub irc_pass {
  my ($heap, $data) = @_[HEAP, ARG0];
  $heap->{'password'} = $data->{'params'}[0]; #stash the password for later
}

sub irc_nick {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  if ($heap->{'username'}) { #if we've already got their nick, don't let them change it
    $kernel->yield('server_reply',433,'Changing nicks once connected is not currently supported.');    
    return;
  }

  if (exists $users{$data->{'params'}[0]}) {
    $kernel->yield('server_reply',436,$data->{'params'}[0],'You are already connected to Twitter with this username.');    
    $kernel->yield('shutdown');
    return;
  }

  $heap->{'username'} = $data->{'params'}[0]; #stash the username for later

  if ($heap->{'username'} && $heap->{'password'} && !$heap->{'twitter'}) {
    $kernel->yield('login');
  }
}

sub irc_user {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  if ($heap->{'username'} && $heap->{'password'} && !$heap->{'twitter'}) {
    $kernel->yield('login');
  }

}

#return the MOTD
sub irc_motd {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  $kernel->yield('server_reply',375,'- tircd Message of the Day -');

  my $ua = LWP::UserAgent->new;
  $ua->timeout(5);
  $ua->env_proxy();
  my $res = $ua->get('http://tircd.googlecode.com/svn/trunk/motd.txt');
  
  if (!$res->is_success) {
    $kernel->yield('server_reply',372,"- Unable to get the MOTD.");
  } else {
    my @lines = split(/\n/,$res->content);
    foreach my $line (@lines) {
      $kernel->yield('server_reply',372,"- $line");
    }
  }
  
  $kernel->yield('server_reply',376,'End of /MOTD command.');
}

sub irc_join {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  my @chans = split(/\,/,$data->{'params'}[0]);
  foreach my $chan (@chans) {
    $chan =~ s/\s//g;
    #see if we've registered an event handler for a 'special channel' (currently only #twitter)
    if ($kernel->call($_[SESSION],$chan,$chan)) {
      next;
    }
    
    #we might have something saved already, if not prep a new channel
    if (!exists $heap->{'channels'}->{$chan} ) {
      $heap->{'channels'}->{$chan} = {};
      $heap->{'channels'}->{$chan}->{'names'}->{$heap->{'username'}} = '@';  
    }
    
    $heap->{'channels'}->{$chan}->{'joined'} = 1;
    
    #otherwise, prep a blank channel  
    $kernel->yield('user_msg','JOIN',$heap->{'username'},$chan);	
    $kernel->yield('server_reply',332,$chan,"$chan");
    $kernel->yield('server_reply',333,$chan,'tircd!tircd@tircd',time());


    #send the /NAMES info
    my $all_users = '';
    foreach my $name (keys %{$heap->{'channels'}->{$chan}->{'names'}}) {
      $all_users .= $heap->{'channels'}->{$chan}->{'names'}->{$name} . $name .' ';
    }
    $kernel->yield('server_reply',353,'=',$chan,$all_users);
    $kernel->yield('server_reply',366,$chan,'End of /NAMES list');
    
    #restart the searching
    if ($heap->{'channels'}->{$chan}->{'topic'}) {
      $kernel->yield('user_msg','TOPIC',$heap->{'username'},$chan,$heap->{'channels'}->{$chan}->{'topic'});
      $kernel->yield('twitter_search',$chan);
    }
  }
}

sub irc_part {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $chan = $data->{'params'}[0];
  
  if ($heap->{'channels'}->{$chan}->{'joined'}) {
    delete $heap->{'channels'}->{$chan};
    $kernel->yield('user_msg','PART',$heap->{'username'},$chan);
  } else {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
  }
}

sub irc_mode { #ignore all mode requests except ban which is a block (send back the appropriate message to keep the client happy)
#this whole thing is messy as hell, need to refactor this function
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  my $mode = $data->{'params'}[1];
  my $opts = $data->{'params'}[2];

  #extract the nick from the banmask
  my ($nick,$host) = split(/\!/,$opts,2);
    $nick =~ s/\*//g;
    if (!$nick) {
      $host =~ s/\*//g;
    if ($host =~ /(.*)\@twitter/) {
      $nick = $1;
    }
  }

  if ($target =~ /^\#/) {
    if ($mode eq 'b') {
      $kernel->yield('server_reply',368,$target,'End of channel ban list');
      return;
    }
    if ($target eq '#twitter') {
      if ($mode eq '+b' && $target eq '#twitter') {
        my $user = eval { $heap->{'twitter'}->create_block($nick) };
        my $error = $@;
        if ($user) {
          $kernel->yield('user_msg','MODE',$heap->{'username'},$target,$mode,$opts);
        } else {
          if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
            $kernel->call($_[SESSION],'twitter_api_error','Unable to block user.',$error);
          } else {
            $kernel->yield('server_reply',401,$nick,'No such nick/channel');
          }
        }
        return;        
      } elsif ($mode eq '-b' && $target eq '#twitter') {
        my $user = eval { $heap->{'twitter'}->destroy_block($nick) };
        my $error = $@;
        if ($user) {
          $kernel->yield('user_msg','MODE',$heap->{'username'},$target,$mode,$opts);
        } else {
          if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
            $kernel->call($_[SESSION],'twitter_api_error','Unable to unblock user.',$error);
          } else {
            $kernel->yield('server_reply',401,$nick,'No such nick/channel');
          }
        }
        return;
      }
    }
    if (!$mode) {        
      $kernel->yield('server_reply',324,$target,"+t");
    }
    return;
  }
  
  $kernel->yield('user_msg','MODE',$heap->{'username'},$target,'+i');
}

sub irc_who {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  if ($target =~ /^\#/) {
    if (exists $heap->{'channels'}->{$target}) {
      foreach my $name (keys %{$heap->{'channels'}->{$target}->{'names'}}) {
        if (my $friend = $kernel->call($_[SESSION],'getfriend',$name)) {
          $kernel->yield('server_reply',352,$target,$name,'twitter','tircd',$name,'G'.$heap->{'channels'}->{$target}->{'names'}->{$name},"0 $friend->{'name'}");
        }
      }      
    }
  } else { #only support a ghetto version of /who right now, /who ** and what not won't work
    if (my $friend = $kernel->call($_[SESSION],'getfriend',$target)) {
        $kernel->yield('server_reply',352,'*',$friend->{'screen_name'},'twitter','tircd',$friend->{'screen_name'}, "G","0 $friend->{'name'}");
    }
  }
  $kernel->yield('server_reply',315,$target,'End of /WHO list'); 
}


sub irc_whois {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  
  my $friend = $kernel->call($_[SESSION],'getfriend',$target);
  my $isfriend = 1;
  my $error;
  
  if (!$friend) {#if we don't have their info already try to get it from twitter, and track it for the end of this function
    $friend = eval { $heap->{'twitter'}->show_user($target) };
    $error = $@;
    $isfriend = 0;
  }

  if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() == 404) {
    $kernel->yield('server_reply',402,$target,'No such server');
    return;
  }

  if (!$friend && ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get user information.',$error);
    return;
  }        

  if ($friend) {
    $kernel->post('logger','log',"Received user information for $target from Twitter.",$heap->{'username'});
    $kernel->yield('server_reply',311,$target,$target,'twitter','*',$friend->{'name'});
    
    #send a bunch of 301s to convey all the twitter info, not sure if this is totally legit, but the clients I tested with seem ok with it
    if ($friend->{'location'}) {
      $kernel->yield('server_reply',301,$target,"Location: $friend->{'location'}");
    }

    if ($friend->{'url'}) {
      $kernel->yield('server_reply',301,$target,"Web: $friend->{'url'}");
    }

    if ($friend->{'description'}) {
      $kernel->yield('server_reply',301,$target,"Bio: $friend->{'description'}");
    }

    if ($friend->{'status'}->{'text'}) {
      $kernel->yield('server_reply',301,$target,"Last Update: ".$friend->{'status'}->{'text'});
    }

    if ($target eq $heap->{'username'}) { #if it's us, then add the rate limit info to
      my $rate = eval { $heap->{'twitter'}->rate_limit_status() };
      $kernel->yield('server_reply',301,$target,'API Usage: '.($rate->{'hourly_limit'}-$rate->{'remaining_hits'})." of $rate->{'hourly_limit'} calls used.");
      $kernel->post('logger','log','Current API usage: '.($rate->{'hourly_limit'}-$rate->{'remaining_hits'})." of $rate->{'hourly_limit'}",$heap->{'username'});
    }

    #treat their twitter client as the server
    my $server; my $info;
    if ($friend->{'status'}->{'source'} =~ /\<a href="(.*)"\>(.*)\<\/a\>/) { #not sure this regex will work in all cases
      $server = $2;
      $info = $1;
    } else {
      $server = 'web';
      $info = 'http://www.twitter.com/';
    }
    $kernel->yield('server_reply',312,$target,$server,$info);
    
    #set their idle time, to the time since last message (if we have one, the api won't return the most recent message for users who haven't updated in a long time)
    my $diff = 0;
    my %mon2num = qw(Jan 0 Feb 1 Mar 2 Apr 3 May 4 Jun 5 Jul 6 Aug 7 Sep 8 Oct 9 Nov 10 Dec 11);
    if ($friend->{'status'}->{'created_at'} =~ /\w+ (\w+) (\d+) (\d+):(\d+):(\d+) [+|-]\d+ (\d+)/) {
        my $date = timegm($5,$4,$3,$2,$mon2num{$1},$6);
        $diff = time()-$date;
    }
    $kernel->yield('server_reply',317,$target,$diff,'seconds idle');

    my $all_chans = '';
    foreach my $chan (keys %{$heap->{'channels'}}) {
      if (exists $heap->{'channels'}->{$chan}->{'names'}->{$friend->{'screen_name'}}) {
        $all_chans .= $heap->{'channels'}->{$chan}->{'names'}->{$friend->{'screen_name'}}."$chan ";
      }
    }
    if ($all_chans ne '') {
      $kernel->yield('server_reply',319,$target,$all_chans);
    }
  }

  $kernel->yield('server_reply',318,$target,'End of /WHOIS list'); 
}

sub irc_stats {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $key = $data->{'params'}[0];
  my $val = $data->{'params'}[1];  
  
  $key = '--' if (!$key || $key eq 'm');
  if ($key eq '--') {
    $kernel->yield('server_reply',212,$key,"Current config settings:");
    foreach my $k (sort keys %{$heap->{'config'}}) {
      $kernel->yield('server_reply',212,$key,"  $k: ".$heap->{'config'}->{$k});  
    }
    $kernel->yield('server_reply',212,$key,"Use '/stats <key> <value>' to change a setting.");
    $kernel->yield('server_reply',212,$key,"Example: /stats join_silent 1");
   } else {
    if (exists $heap->{'config'}->{$key}) {
      $heap->{'config'}->{$key} = $val;
      $kernel->yield('server_reply',212,$key,"set to $val");
    } 
  }
  $kernel->yield('server_reply',219,$key,'End of /STATS request');
}

sub irc_privmsg {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  
  my $target = $data->{'params'}[0];
  my $msg  = $data->{'params'}[1];
  
  #handle /me or ACTION requests properly
  #this begins the slipperly slope of manipulating user input
  $msg =~ s/\001ACTION (.*)\001/\*$1\*/;
  

  if ($heap->{'config'}->{'long_messages'} eq 'split' && length($msg) > 140) {
    my @parts = $msg =~ /(.{1,140})/g;
    if (length($parts[$#parts]) < $heap->{'config'}->{'min_length'}) {
      $kernel->yield('server_reply',404,$target,"The last message would only be ".length($parts[$#parts]).' characters long.  Your message was not sent.');
      return;
    }
    
    #if we got this far, recue the split messages
    foreach my $part (@parts) {
      $data->{'params'}[1] = $part;
      $kernel->call($_[SESSION],'PRIVMSG',$data);
    }

    return;
  }

  if ($target =~ /^#/) {
    if (!exists $heap->{'channels'}->{$target}) {
      $kernel->yield('server_reply',404,$target,'Cannot send to channel');
      return;
    } else {
      $target = '#twitter'; #we want to force all topic changes and what not into twitter for now
    }

    #shorten the URL
    if (eval("require URI::Find;") && $heap->{'config'}->{'shorten_urls'}) {
      my $finder = URI::Find->new(sub {
        my $uriobj = shift;
        my $uri = shift;
        
        if ($uri !~ /^http:/) {
          return $uri;
        }

        # Do not shorten twice - heuristics!
        if (length($uri) < 30) {
          return $uri;
        }

        
        my $res = $heap->{'ua'}->get("http://tinyurl.com/api-create.php?url=$uri");
        if ($res->is_success) {
          return $res->content;
        } else {
          return $uri;
        }
      });
      $finder->find(\$msg);
    }
    
    #Tweak the @replies
    if ($msg =~ /^(\w+)\: / && $heap->{'config'}->{'convert_irc_replies'}) {
      # @Olatho - changing ALL first-words that end with : to @, not only nicks on #Twitter
      # - I sometimes reply to people that I do not follow, and want them converted as well
      $msg =~ s/^(\w+)\: /\@$1 /;
    }

    #warn if asked and the message is too long after fucking with it
    if ($heap->{'config'}->{'long_messages'} eq 'warn' && length($msg) > 140) {
      $kernel->yield('server_reply',404,$target,'Your message is '.length($msg).' characters long.  Your message was not sent.');
      return;
    }  
    
    #in a channel, this an update
    my $update = eval { $heap->{'twitter'}->update($msg) };
    my $error = $@;
    if (!$update && ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update status.',$error);
      return;
    } 

    $msg = $update->{'text'};
    
    #update our own friend record
    my $me = $kernel->call($_[SESSION],'getfriend',$heap->{'username'});
    $me = $update->{'user'};
    $me->{'status'} = $update;
    $kernel->call($_[SESSION],'updatefriend',$me);
    
    #keep the topic updated with our latest tweet  
    $kernel->yield('user_msg','TOPIC',$heap->{'username'},$target,"$heap->{'username'}'s last update: $msg");
    $kernel->post('logger','log','Updated status.',$heap->{'username'});
  } else { 
    #private message, it's a dm
    my $dm = eval { $heap->{'twitter'}->new_direct_message({user => $target, text => $msg}) };
    if (!$dm) {
      $kernel->yield('server_reply',401,$target,"Unable to send direct message.  Perhaps $target isn't following you?");
      $kernel->post('logger','log',"Unable to send direct message to $target",$heap->{'username'});
    } else {
      $kernel->post('logger','log',"Sent direct message to $target",$heap->{'username'});
    }
  }    
}

#allow the user to follow new users by adding them to the channel
sub irc_invite {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  my $chan = $data->{'params'}[1];

  if (!$heap->{'channels'}->{$chan}->{'joined'}) {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
    return;
  }

  if (exists $heap->{'channels'}->{$chan}->{'names'}->{$target}) {
    $kernel->yield('server_reply',443,$target,$chan,'is already on channel');
    return;
  }

  if ($chan ne '#twitter') { #if it's not our main channel, just fake the user in, if we already follow them
    if (exists $heap->{'channels'}->{'#twitter'}->{'names'}->{$target}) {
      $heap->{'channels'}->{$chan}->{'names'}->{$target} = $heap->{'channels'}->{'#twitter'}->{'names'}->{$target};
      $kernel->yield('server_reply',341,$target,$chan);
      $kernel->yield('user_msg','JOIN',$target,$chan);
      if ($heap->{'channels'}->{$chan}->{'names'}->{$target} ne '') {
        $kernel->yield('server_reply','MODE',$chan,'+v',$target);
      }
    } else {
      $kernel->yield('server_reply',481,"You must invite the user to the #twitter channel first.");    
    }
    return;      
  }

  #if it's the main channel, we'll start following them on twitter
  my $user = eval { $heap->{'twitter'}->create_friend({id => $target}) };
  my $error = $@;
  if ($user) {
    if (!$user->{'protected'}) {
      #if the user isn't protected, and we are following them now, then have 'em 'JOIN' the channel
      push(@{$heap->{'friends'}},$user);
      $kernel->yield('server_reply',341,$user->{'screen_name'},$chan);
      $kernel->yield('user_msg','JOIN',$user->{'screen_name'},$chan);
      $kernel->post('logger','log',"Started following $target",$heap->{'username'});
      if ($kernel->call($_[SESSION],'getfollower',$user->{'screen_name'})) {
        $heap->{'channels'}->{$chan}->{'names'}->{$target} = '+';
        $kernel->yield('server_reply','MODE',$chan,'+v',$target);        
      } else {
        $heap->{'channels'}->{$chan}->{'names'}->{$target} = '';
      }
    } else {
      #show a note if they are protected and we are waiting 
      #this should technically be a 482, but some clients were exiting the channel for some reason
      $kernel->yield('server_reply',481,"$target\'s updates are protected.  Request to follow has been sent.");
      $kernel->post('logger','log',"Sent request to follow $target",$heap->{'username'});      
    }
  } else {
    if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400 && $error->code() != 403) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to follow user.',$error);    
    } else {
      $kernel->yield('server_reply',401,$target,'No such nick/channel');
      $kernel->post('logger','log',"Attempted to follow non-existant user $target",$heap->{'username'});      
    }      
  }
}

#allow a user to unfollow/leave a user by kicking them from the channel
sub irc_kick {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  my $chan = $data->{'params'}[0];  
  my $target = $data->{'params'}[1];

  if (!$heap->{'channels'}->{$chan}->{'joined'}) {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
    return;
  }
  
  if (!exists $heap->{'channels'}->{$chan}->{'names'}->{$target}) {
    $kernel->yield('server_reply',441,$target,$chan,"They aren't on that channel");
    return;
  }
  
  if ($chan ne '#twitter') {
    delete $heap->{'channels'}->{$chan}->{'names'}->{$target};
    $kernel->yield('user_msg','KICK',$heap->{'username'},$chan,$target,$target);
    return;
  }
  
  my $result = eval { $heap->{'twitter'}->destroy_friend($target) };
  my $error = $@;
  if ($result) {
    $kernel->call($_[SESSION],'remfriend',$target);
    delete $heap->{'channels'}->{$chan}->{'names'}->{$target};
    $kernel->yield('user_msg','KICK',$heap->{'username'},$chan,$target,$target);
    $kernel->post('logger','log',"Stoped following $target",$heap->{'username'});
  } else {
    if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to unfollow user.',$error);    
    } else {
      $kernel->yield('server_reply',441,$target,$chan,"They aren't on that channel");  
      $kernel->post('logger','log',"Attempted to unfollow user ($target) we weren't following",$heap->{'username'});
    }
  }  

}

sub irc_ping {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  
  $kernel->yield('server_reply','PONG',$target);
}

sub irc_away {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  
  if ($data->{'params'}[0]) {
    $kernel->yield('server_reply',306,'You have been marked as being away');
  } else {
    $kernel->yield('server_reply',305,'You are no longer marked as being away');  
  }
}

sub irc_topic {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $chan = $data->{'params'}[0];
  my $topic = $data->{'params'}[1];
  
  return if $chan eq '#twitter';

  if (!$heap->{'channels'}->{$chan}->{'joined'}) {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
    return;
  }
  
  $heap->{'channels'}->{$chan}->{'topic'} = $topic;
  $heap->{'channels'}->{$chan}->{'search_since_id'} = 0;

  $kernel->yield('user_msg','TOPIC',$heap->{'username'},$chan,$topic);  
  $kernel->yield('twitter_search',$chan);  
}

#shutdown the socket when the user quits
sub irc_quit {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  $kernel->yield('shutdown');
}

########### IRC 'SPECIAL CHANNELS'

sub channel_twitter {
  my ($kernel,$heap,$chan) = @_[KERNEL, HEAP, ARG0];

  #add our channel to the list  
  $heap->{'channels'}->{$chan} = {};
  $heap->{'channels'}->{$chan}->{'joined'} = 1;

  #get list of friends
  my @friends = ();
  my $cursor = -1;
  my $error;
  while (my $f = eval { $heap->{'twitter'}->friends({'cursor' => $cursor})}) {
    $cursor = $f->{'next_cursor'};
    foreach my $user ($f->{'users'}) {
      foreach my $u (@{$user}) {
        push(@friends, $u);
      }
    }
    last if $cursor == 0;
  }
  my $error = $@;

  #if we have no data, there was an error, or the user is a loser with no friends, eject 'em
  if ($cursor == -1 && ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get friends list.',$error);
    return;
  } 

  #get list of followers
  my @followers = ();
  $cursor = -1;
  while (my $f = eval { $heap->{'twitter'}->followers({'cursor' => $cursor}) }) {
    $cursor = $f->{'next_cursor'};
    foreach my $user ($f->{'users'}) {
      foreach my $u (@{$user}) {
        push(@followers, $u);
      }
    }
    last if $cursor == 0;
  }
  $error = $@;

  #alert this error, but don't end 'em
  if ($cursor == -1 && ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get followers list.',$error);
  } 

  #cache our friends and followers
  $heap->{'friends'} = \@friends;
  $heap->{'followers'} = \@followers;
  $kernel->post('logger','log','Received friends list from Twitter, caching '.@{$heap->{'friends'}}.' friends.',$heap->{'username'});
  $kernel->post('logger','log','Received followers list from Twitter, caching '.@{$heap->{'followers'}}.' followers.',$heap->{'username'});

  #spoof the channel join
  $kernel->yield('user_msg','JOIN',$heap->{'username'},$chan);	
  $kernel->yield('server_reply',332,$chan,"$heap->{'username'}'s twitter");
  $kernel->yield('server_reply',333,$chan,'tircd!tircd@tircd',time());
  
  #the the list of our users for /NAMES
  my $lastmsg = '';
  foreach my $user (@{$heap->{'friends'}}) {
    my $ov ='';
    if ($user->{'screen_name'} eq $heap->{'username'}) {
      $lastmsg = $user->{'status'}->{'text'};
      $ov = '@';
    } elsif ($kernel->call($_[SESSION],'getfollower',$user->{'screen_name'})) {
      $ov='+';
    }
    #keep a copy of who is in this channel
    $heap->{'channels'}->{$chan}->{'names'}->{$user->{'screen_name'}} = $ov;
  }
  
  if (!$lastmsg) { #if we aren't already in the list, add us to the list for NAMES - AND go grab one tweet to put us in the array
    $heap->{'channels'}->{$chan}->{'names'}->{$heap->{'username'}} = '@';
    my $data = eval { $heap->{'twitter'}->user_timeline({count => 1}) };
    if ($data && @$data > 0) {
      $kernel->post('logger','log','Received user timeline from Twitter.',$heap->{'username'});
      my $tmp = $$data[0]->{'user'};
      $tmp->{'status'} = $$data[0];
      $lastmsg = $tmp->{'status'}->{'text'};
      push(@{$heap->{'friends'}},$tmp);
    }
  }  

  #send the /NAMES info
  my $all_users = '';
  foreach my $name (keys %{$heap->{'channels'}->{$chan}->{'names'}}) {
    $all_users .= $heap->{'channels'}->{$chan}->{'names'}->{$name} . $name .' ';
  }
  $kernel->yield('server_reply',353,'=',$chan,$all_users);
  $kernel->yield('server_reply',366,$chan,'End of /NAMES list');

  $kernel->yield('user_msg','TOPIC',$heap->{'username'},$chan,"$heap->{'username'}'s last update: $lastmsg");

  #start our twitter even loop, grab the timeline, replies and direct messages
  $kernel->yield('twitter_timeline',$heap->{'config'}->{'join_silent'}); 
  $kernel->yield('twitter_direct_messages',$heap->{'config'}->{'join_silent'}); 
  
  return 1;
}

########### TWITTER EVENT/ALARM FUNCTIONS

sub twitter_timeline {
  my ($kernel, $heap, $silent) = @_[KERNEL, HEAP, ARG0];

  #get updated messages
  my $timeline;
  my $error;
  if ($heap->{'timeline_since_id'}) {
    $timeline = eval { $heap->{'twitter'}->friends_timeline({count => $heap->{'config'}->{'timeline_count'}, since_id => $heap->{'timeline_since_id'}}) };
    $error = $@;
  } else {
    $timeline = eval { $heap->{'twitter'}->friends_timeline({count => $heap->{'config'}->{'timeline_count'}}) };
    $error = $@;
  }

  #sometimes the twitter API returns undef, so we gotta check here
  if (!$timeline || @$timeline == 0 || @{$timeline}[0]->{'id'} < $heap->{'timeline_since_id'} ) {
    $timeline = [];
    if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update timeline.',$error);   
    }
  } else {
    #if we got new data save our position
    $heap->{'timeline_since_id'} = @{$timeline}[0]->{'id'};
    $kernel->post('logger','log','Received '.@$timeline.' timeline updates from Twitter.',$heap->{'username'});
  }

  #get updated @replies too
  my $replies;
  if ($heap->{'replies_since_id'}) {
    $replies = eval { $heap->{'twitter'}->replies({since_id => $heap->{'replies_since_id'}}) };
    $error = $@;
  } else {
    $replies = eval { $heap->{'twitter'}->replies({page =>1}) }; #avoid a bug in Net::Twitter
    $error = $@;
  }

  if (!$replies || @$replies == 0) {
    $replies = [];
    if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update @replies.',$error);   
    }
  } else {  
    $heap->{'replies_since_id'} = @{$replies}[0]->{'id'};
    $kernel->post('logger','log','Received '.@$replies.' @replies from Twitter.',$heap->{'username'});
  }
  
  #weave the two arrays together into one stream, removing duplicates
  my @tmpdata = (@{$timeline},@{$replies});
  my %tmphash = ();
  foreach my $item (@tmpdata) {
    $tmphash{$item->{'id'}} = $item;
  }

  #loop through each message
  foreach my $item (sort {$a->{'id'} <=> $b->{'id'}} values %tmphash) {
    my $tmp = $item->{'user'};
    $tmp->{'status'} = $item;
    
    if (my $friend = $kernel->call($_[SESSION],'getfriend',$item->{'user'}->{'screen_name'})) { #if we've seen 'em before just update our cache
      $kernel->call($_[SESSION],'updatefriend',$tmp);
    } else { #if it's a new user, add 'em to the cache / and join 'em
      push(@{$heap->{'friends'}},$tmp);
      
      #removed the fake join tempoarily while, I figure out the better way to handle this.  I think the best is to leave it like this and treat the channels as if they are -n
      #$kernel->yield('user_msg','JOIN',$item->{'user'}->{'screen_name'},'#twitter');
      #if ($kernel->call($_[SESSION],'getfollower',$item->{'user'}->{'screen_name'})) {
      #  $heap->{'channels'}->{'#twitter'}->{'names'}->{$item->{'user'}->{'screen_name'}} = '+';
      #  $kernel->yield('server_reply','MODE','#twitter','+v',$item->{'user'}->{'screen_name'});
      #} else {
      #  $heap->{'channels'}->{'#twitter'}->{'names'}->{$item->{'user'}->{'screen_name'}} = '';
      #}
    }
    
    #filter out our own messages / don't display if not in silent mode
    if (($item->{'user'}->{'screen_name'} ne lc($heap->{'username'}) || !$heap->{'config'}->{'filter_self'})) {
      if (!$silent) {
        foreach my $chan (keys %{$heap->{'channels'}}) {
          if ($chan eq '#twitter' || exists $heap->{'channels'}->{$chan}->{'names'}->{$item->{'user'}->{'screen_name'}}) {
            $kernel->yield('user_msg','PRIVMSG',$item->{'user'}->{'screen_name'},$chan,$item->{'text'});
          }
          if ($item->{'user'}->{'screen_name'} eq $heap->{'username'}) {
            $kernel->yield('user_msg','TOPIC',$heap->{'username'},$chan,"$heap->{'username'}'s last update: ".$item->{'text'});
          }            
        }          
      }        
    }
  }

  $kernel->delay('twitter_timeline',$heap->{'config'}->{'update_timeline'});
}

#same as above, but for direct messages, show 'em as PRIVMSGs from the user
sub twitter_direct_messages {
  my ($kernel, $heap, $silent) = @_[KERNEL, HEAP, ARG0];

  my $data;
  my $error;
  if ($heap->{'direct_since_id'}) {
    $data = eval { $heap->{'twitter'}->direct_messages({since_id => $heap->{'direct_since_id'}}) };
    $error = $@;
  } else {
    $data = eval { $heap->{'twitter'}->direct_messages() };
    $error = $@;
  }

  if (!$data || @$data == 0 || @{$data}[0]->{'id'} < $heap->{'direct_since_id'}) {
    $data = [];
    if (ref $error && $error->isa("Net::Twitter::Lite::Error") && $error->code() >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update direct messages.',$error);   
    }
  } else {
    $heap->{'direct_since_id'} = @{$data}[0]->{'id'};
    $kernel->post('logger','log','Received '.@$data.' direct messages from Twitter.',$heap->{'username'});
  }

  foreach my $item (sort {$a->{'id'} <=> $b->{'id'}} @{$data}) {
    if (!$kernel->call($_[SESSION],'getfriend',$item->{'sender'}->{'screen_name'})) {
      my $tmp = $item->{'sender'};
      $tmp->{'status'} = $item;
      $tmp->{'status'}->{'text'} = '(dm) '.$tmp->{'status'}->{'text'};
      push(@{$heap->{'friends'}},$tmp);
      $kernel->yield('user_msg','JOIN',$item->{'sender'}->{'screen_name'},'#twitter');
      if ($kernel->call($_[SESSION],'getfollower',$item->{'user'}->{'screen_name'})) {
        $heap->{'channels'}->{'#twitter'}->{'names'}->{$item->{'user'}->{'screen_name'}} = '+';
        $kernel->yield('server_reply','MODE','#twiter','+v',$item->{'user'}->{'screen_name'});        
      } else {
        $heap->{'channels'}->{'#twitter'}->{'names'}->{$item->{'user'}->{'screen_name'}} = '';
      }
 
    }
    
    if (!$silent) {
      $kernel->yield('user_msg','PRIVMSG',$item->{'sender'}->{'screen_name'},$heap->{'username'},$item->{'text'});
    }      
  }

  $kernel->delay('twitter_direct_messages',$heap->{'config'}->{'update_directs'});
}

sub twitter_search {
  my ($kernel, $heap, $chan) = @_[KERNEL, HEAP, ARG0];

  if (!$heap->{'channels'}->{$chan}->{'joined'} || !$heap->{'channels'}->{$chan}->{'topic'}) {
    #if we aren't in the channel, don't od anythning, this will keep us from restarting timers for channels we are no longer in
    return;
  }
  
  my $data;
  my $error;
  if ($heap->{'channels'}->{$chan}->{'search_since_id'}) {
    $data = eval {$heap->{'twitter'}->search({q => $heap->{'channels'}->{$chan}->{'topic'}, rpp => 100, since_id => $heap->{'channels'}->{$chan}->{'search_since_id'}});};
    $error = $@;
  } else {   
    $data = eval {$heap->{'twitter'}->search({q => $heap->{'channels'}->{$chan}->{'topic'}, rpp => 100});};
    $error = $@;
  }

  if (!$data || $data->{'max_id'} < $heap->{'channels'}->{$chan}->{'search_since_id'} ) {
    $data = {results => []};
    $kernel->call($_[SESSION],'twitter_api_error','Unable to update search results.',$error);   
  } else {
    $heap->{'channels'}->{$chan}->{'search_since_id'} = $data->{'max_id'};
    if (@{$data->{'results'}} > 0) {
      $kernel->post('logger','log','Received '.@{$data->{'results'}}.' search results from Twitter.',$heap->{'username'});
    }      
  }

  foreach my $result (sort {$a->{'id'} <=> $b->{'id'}} @{$data->{'results'}}) {
    if ($result->{'from_user'} ne $heap->{'username'}) {
      $kernel->yield('user_msg','PRIVMSG',$result->{'from_user'},$chan,$result->{'text'});
    }
  }

  $kernel->delay_add('twitter_search',30,$chan);    
}

__END__

=head1 Documentation moved

Please see tircd.pod which should have been included with this script

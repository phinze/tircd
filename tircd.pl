#!/usr/bin/perl
# tircd - An ircd proxy to the Twitter API
# perldoc this file for more information.

use strict;
use JSON::Any;
use Net::Twitter;
use Time::Local;
use File::Glob ':glob';
use IO::File;
use LWP::UserAgent;
use POE qw(Component::Server::TCP Filter::Stackable Filter::Map Filter::IRCD);

my $VERSION = 0.6;

#Do some sanity checks on the environment and warn if not what we want
if ($Net::Twitter::VERSION < 1.23) {
  print "Warning: Your system has an old version of Net::Twitter.  Please upgrade to the current version.\n";
}

my $j = JSON::Any->new;
if ($j->handlerType eq 'JSON::Syck') {
  print "Warning: Your system is using JSON::Syck. This will cause problems with character encoding.   Please install JSON::PP or JSON::XS.\n";
}

#load and parse our own very simple config file
#didn't want to introduce another module requirement to parse XML or a YAML file
my $config_file = $ARGV[0] ? $ARGV[0] :
  -e 'tircd.cfg' ? 'tircd.cfg' : bsd_glob('~',GLOB_TILDE | GLOB_ERR).'/.tircd';

open(C,$config_file) || die("$0: Unable to load config file ($config_file): $!\n");
my %config = ();
while (<C>) {
  chomp;
  next if /^#/ || /^$/;
  my ($key,$value) = split(/\s/,$_,2);
  $config{$key} = $value;
}
close(C);

#storage for connected users
my %users;

#setup our filter to process the IRC messages, jacked from the Filter::IRCD docs
my $filter = POE::Filter::Stackable->new();
$filter->push( POE::Filter::Line->new( InputRegexp => '\015?\012', OutputLiteral => "\015\012" ));
#twitter's json feed escapes < and >, let's fix that
$filter->push( POE::Filter::Map->new(Code => sub {
  local $_ = shift;
  s/\&lt\;/\</;
  s/\&gt\;/\>/;
  return $_;
}));
if ($config{'debug'} > 1) {
  $filter->push(POE::Filter::IRCD->new(debug => 1));
} else {
  $filter->push(POE::Filter::IRCD->new(debug => 0));
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
    INVITE => \&irc_invite,
    KICK => \&irc_kick,
    QUIT => \&irc_quit,
    PING => \&irc_ping,
    AWAY => \&irc_away,
    
    server_reply => \&irc_reply,
    user_msg	 => \&irc_user_msg,

    twitter_api_error => \&twitter_api_error,    
    twitter_timeline => \&twitter_timeline,
    twitter_direct_messages => \&twitter_direct_messages,
    
    login => \&tircd_login,
    getfriend => \&tircd_getfriend,
    remfriend => \&tircd_remfriend,
    updatefriend => \&tircd_updatefriend,
    getfollower => \&tircd_getfollower
    
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
    $heap->{'file'} = POE::Wheel::ReadWrite->new(
      Handle => $handle,
    );
  }
}

########## 'INTERNAL' UTILITY FUNCTIONS
#log a message
sub logger_log {
  my ($heap, $msg, $from) = @_[HEAP, ARG0, ARG1];
  return if ! $heap->{'file'};
  
  $from = "[$from] " if defined $from;
  my $stamp = '['.localtime().'] ';
  $heap->{'file'}->put("$stamp$from$msg");
}

#trap twitter api errors
sub twitter_api_error {
  my ($kernel,$heap, $msg) = @_[KERNEL, HEAP, ARG0];
  
  if ($config{'debug'}) {
    $kernel->post('logger','log',$heap->{'twitter'}->http_message.' '.$heap->{'twitter'}->http_code.' '.$heap->{'twitter'}->get_error,'debug/twitter_api_error');
  }

  $kernel->post('logger','log',$msg.' ('.$heap->{'twitter'}->http_code .' from Twitter API).',$heap->{'username'});  

  if ($heap->{'twitter'}->http_code == 400) {
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

  #start up the twitter interface, and see if we can connect with the given NICK/PASS INFO
  my $twitter = Net::Twitter->new(username => $heap->{'username'}, password => $heap->{'password'}, source => 'tircd');
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
  
  $kernel->yield('shutdown');
}


########## 'INTERNAL' IRC I/O FUNCTIONS
#called everytime we get a line from an irc server
#trigger an event and move on, the ones we care about will get trapped
sub irc_line {
  my  ($kernel, $data) = @_[KERNEL, ARG0];
  if ($config{'debug'}) {
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

  if ($code ne 'PONG' && $code != 436) {
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

  my $chan = $data->{'params'}[0];

  if ($chan ne '#twitter') { #only support the twitter channel right now
    $kernel->yield('server_reply',403,$chan,'No such channel');
    return;
  }

  #keep track of the channels they are in, kinda silly right now, but if we add multiple channel support in the future, it'll be good to have  
  $heap->{'channels'}{$chan} = 1;

  #get list of friends
  my @friends = ();
  my $page = 1;  
  while (my $f = eval { $heap->{'twitter'}->friends({page => $page}) }) {
    last if @$f == 0;    
    push(@friends,@$f);
    $page++;
  }

  #if we have no data, there was an error, or the user is a loser with no friends, eject 'em
  if ($page == 1 && $heap->{'twitter'}->http_code >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get friends list.');
    return;
  } 

  #get list of friends
  my @followers = ();
  my $page = 1;  
  while (my $f = eval { $heap->{'twitter'}->followers({page => $page}) }) {
    last if @$f == 0;    
    push(@followers,@$f);
    $page++;
  }

  #alert this error, but don't end 'em
  if ($page == 1 && $heap->{'twitter'}->http_code >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get followers list.');
  } 

  #cache our friends and followers
  $heap->{'friends'} = \@friends;
  $heap->{'followers'} = \@followers;
  $kernel->post('logger','log','Received friends list from Twitter, caching '.@{$heap->{'friends'}}.' friends.',$heap->{'username'});
  $kernel->post('logger','log','Received followers list from Twitter, caching '.@{$heap->{'followers'}}.' followers.',$heap->{'username'});

  #spoof the channel join
  $kernel->yield('user_msg','JOIN',$heap->{'username'},$chan);	
  $kernel->yield('server_reply',332,$chan,"$heap->{'username'}'s twiter");
  $kernel->yield('server_reply',333,$chan,'tircd!tircd@tircd',time());
  
  #the the list of our users for /NAMES
  my @users; my $lastmsg = '';
  foreach my $user (@{$heap->{'friends'}}) {
    my $ov ='';
    if ($user->{'screen_name'} eq $heap->{'username'}) {
      $lastmsg = $user->{'status'}->{'text'};
      $ov = '@';
    } elsif ($kernel->call($_[SESSION],'getfollower',$user->{'screen_name'})) {
      $ov='+';
    }
    push(@users,$ov.$user->{'screen_name'});
  }
  
  if (!$lastmsg) { #if we aren't already in the list, add us to the list for NAMES - AND go grab one tweet to put us in the array
    unshift(@users, '@'.$heap->{'username'});
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
  my $all_users = join(' ',@users);
  $kernel->yield('server_reply',353,'=',$chan,$all_users);
  $kernel->yield('server_reply',366,$chan,'End of /NAMES list');

  $kernel->yield('user_msg','TOPIC',$heap->{'username'},$chan,"$heap->{'username'}'s last update: $lastmsg");

  #start our twitter even loop, grab the timeline, replies and direct messages
  $kernel->yield('twitter_timeline',$config{'join_silent'}); 
  $kernel->yield('twitter_direct_messages',$config{'join_silent'}); 
}

sub irc_part {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $chan = $data->{'params'}[0];
  
  if (exists $heap->{'channels'}{$chan}) {
    delete $heap->{'channels'}{$chan};
    delete $heap->{'friends'};
    delete $heap->{'followers'};
    $kernel->yield('user_msg','PART',$heap->{'username'},$chan);
  } else {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
  }
}

sub irc_mode { #ignore all mode requests (send back the appropriate message to keep the client happy)
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
    } elsif ($mode eq '+b') {
      my $user = eval { $heap->{'twitter'}->create_block($nick) };
      if ($user) {
        $kernel->yield('user_msg','MODE',$heap->{'username'},$target,$mode,$opts);
      } else {
        if ($heap->{'twitter'}->http_code >= 400) {
          $kernel->call($_[SESSION],'twitter_api_error','Unable to block user.');
        } else {
          $kernel->yield('server_reply',401,$nick,'No such nick/channel');
        }
      }        
    } elsif ($mode eq '-b') {
      my $user = eval { $heap->{'twitter'}->destroy_block($nick) };
      if ($user) {
        $kernel->yield('user_msg','MODE',$heap->{'username'},$target,$mode,$opts);
      } else {
        if ($heap->{'twitter'}->http_code >= 400) {
          $kernel->call($_[SESSION],'twitter_api_error','Unable to unblock user.');
        } else {
          $kernel->yield('server_reply',401,$nick,'No such nick/channel');
        }
      }        
    } else {
      $kernel->yield('server_reply',324,$target,"+t");
    }
  } else {
    $kernel->yield('user_msg','MODE',$heap->{'username'},$target,'+i');
  }
}

sub irc_who {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  if ($target =~ /^\#/) {
    if ($target eq '#twitter') {
      foreach my $friend (@{$heap->{'friends'}}) {
        my $ov = '';
        if ($friend->{'screen_name'} eq $heap->{'username'}) {
          $ov='@';
        } elsif ($kernel->call($_[SESSION],'getfollower',$friend->{'screen_name'})) {
          $ov='+';
        }
        $kernel->yield('server_reply',352,$target,$friend->{'screen_name'},'twitter','tircd',$friend->{'screen_name'},"G$ov","0 $friend->{'name'}");
      }
    }      
  } else { #only support a ghetto version of /who right now, /who ** and what not won't work
    if (my $friend = $kernel->call($_[SESSION],'getfriend',$target)) {
        my $ov = '';
        if ($target eq $heap->{'username'}) {
          $ov='@';
        } elsif ($kernel->call($_[SESSION],'getfollower',$friend->{'screen_name'})) {
          $ov='+';
        }
        $kernel->yield('server_reply',352,'*',$friend->{'screen_name'},'twitter','tircd',$friend->{'screen_name'}, "G$ov","0 $friend->{'name'}");
    }
  }
  $kernel->yield('server_reply',315,$target,'End of /WHO list'); 
}


sub irc_whois {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $target = $data->{'params'}[0];
  
  my $friend = $kernel->call($_[SESSION],'getfriend',$target);
  my $isfriend = 1;
  
  if (!$friend) {#if we don't have their info already try to get it from twitter, and track it for the end of this function
    $friend = eval { $heap->{'twitter'}->show_user($target) };
    $isfriend = 0;
  }

  if ($heap->{'twitter'}->http_code == 404) {
    $kernel->yield('server_reply',402,$target,'No such server');
    return;
  }

  if (!$friend && $heap->{'twitter'}->http_code >= 400) {
    $kernel->call($_[SESSION],'twitter_api_error','Unable to get user information.');
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

    if ($isfriend) {
      my $ov = '';
      if ($friend->{'screen_name'} eq $heap->{'username'}) {
        $ov='@';
      } elsif ($kernel->call($_[SESSION],'getfollower',$friend->{'screen_name'})) {
        $ov='+';
      }
      $kernel->yield('server_reply',319,$target,"$ov#twitter ");
    }
  }

  $kernel->yield('server_reply',318,$target,'End of /WHOIS list'); 
}

sub irc_privmsg {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  
  my $target = $data->{'params'}[0];
  my $msg  = $data->{'params'}[1];
  
  if ($config{'long_messages'} eq 'warn' && length($msg) > 140) {
      $kernel->yield('server_reply',404,$target,'Your message is '.length($msg).' characters long.  Your message was not sent.');
      return;
  }  

  if ($config{'long_messages'} eq 'split' && length($msg) > 140) {
    my @parts = $msg =~ /(.{1,140})/g;
    if (length($parts[$#parts]) < $config{'min_length'}) {
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
    }

    #in a channel, this an update
    my $update = eval { $heap->{'twitter'}->update($msg) };
    if (!$update && $heap->{'twitter'}->http_code >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update status.');
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

  if (!exists $heap->{'channels'}->{$chan}) {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
    return;
  }

  if ($kernel->call($_[SESSION],'getfriend',$target)) {
    $kernel->yield('server_reply',443,$target,$chan,'is already on channel');
    return;
  }

  my $user = eval { $heap->{'twitter'}->create_friend({id => $target}) };
  if ($user) {
    if (!$user->{'protected'}) {
      #if the user isn't protected, and we are following them now, then have 'em 'JOIN' the channel
      push(@{$heap->{'friends'}},$user);
      $kernel->yield('server_reply',341,$user->{'screen_name'},$chan);
      $kernel->yield('user_msg','JOIN',$user->{'screen_name'},$chan);
      $kernel->post('logger','log',"Started following $target",$heap->{'username'});
    } else {
      #show a note if they are protected and we are waiting 
      #this should technically be a 482, but some clients were exiting the channel for some reason
      $kernel->yield('server_reply',481,"$target\'s updates are protected.  Request to follow has been sent.");
      $kernel->post('logger','log',"Sent request to follow $target",$heap->{'username'});      
    }
  } else {
    if ($heap->{'twitter'}->http_code >= 400 && $heap->{'twitter'}->http_code != 403) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to follow user.');    
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

  if (!exists $heap->{'channels'}->{$chan}) {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
    return;
  }
  
  if (!$kernel->call($_[SESSION],'getfriend',$target)) {
    $kernel->yield('server_reply',441,$target,$chan,"They aren't on that channel");
    return;
  }

  my $result = eval { $heap->{'twitter'}->destroy_friend($target) };
  if ($result) {
    $kernel->call($_[SESSION],'remfriend',$target);
    $kernel->yield('user_msg','KICK',$heap->{'username'},$chan,$target,$target);
    $kernel->post('logger','log',"Stoped following $target",$heap->{'username'});
  } else {
    if ($heap->{'twitter'}->http_code >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to unfollow user.');    
    } else {
      $kernel->yield('server_reply',441,$target,'#twitter',"They aren't on that channel");  
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

#shutdown the socket when the user quits
sub irc_quit {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  $kernel->yield('shutdown');
}


########### TWITTER EVENT/ALARM FUNCTIONS

sub twitter_timeline {
  my ($kernel, $heap, $silent) = @_[KERNEL, HEAP, ARG0];

  #get updated messages
  my $timeline;
  if ($heap->{'timeline_since_id'}) {
    $timeline = eval { $heap->{'twitter'}->friends_timeline({since_id => $heap->{'timeline_since_id'}}) };
  } else {
    $timeline = eval { $heap->{'twitter'}->friends_timeline() };
  }

  #sometimes the twitter API returns undef, so we gotta check here
  if (!$timeline || @$timeline == 0) {
    $timeline = [];
    if ($heap->{'twitter'}->http_code >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update timeline.');   
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
  } else {
    $replies = eval { $heap->{'twitter'}->replies({page =>1}) }; #avoid a bug in Net::Twitter
  }

  if (!$replies || @$replies == 0) {
    $replies = [];
    if ($heap->{'twitter'}->http_code >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update @replies.');   
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
      $kernel->yield('user_msg','JOIN',$item->{'user'}->{'screen_name'},'#twitter');
    }
    
    #filter out our own messages / don't display if not in silent mode
    if ($item->{'user'}->{'screen_name'} ne $heap->{'username'}) {
      if (!$silent) {
        $kernel->yield('user_msg','PRIVMSG',$item->{'user'}->{'screen_name'},'#twitter',$item->{'text'});
      }        
    }
  }

  $kernel->delay('twitter_timeline',$config{'update_timeline'});
}

#same as above, but for direct messages, show 'em as PRIVMSGs from the user
sub twitter_direct_messages {
  my ($kernel, $heap, $silent) = @_[KERNEL, HEAP, ARG0];

  my $data;
  if ($heap->{'direct_since_id'}) {
    $data = eval { $heap->{'twitter'}->direct_messages({since_id => $heap->{'direct_since_id'}}) };
  } else {
    $data = eval { $heap->{'twitter'}->direct_messages() };
  }

  if (!$data || @$data == 0) {
    $data = [];
    if ($heap->{'twitter'}->http_code >= 400) {
      $kernel->call($_[SESSION],'twitter_api_error','Unable to update direct messages.');   
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
    }
    
    if (!$silent) {
      $kernel->yield('user_msg','PRIVMSG',$item->{'sender'}->{'screen_name'},$heap->{'username'},$item->{'text'});
    }      
  }

  $kernel->delay('twitter_direct_messages',$config{'update_directs'});
}

__END__

=head1 NAME

tircd  - An ircd proxy to the twitter API

=head1 DESCRIPTION

tircd presents twitter as an irc channel.  You can connect to tircd with any irc client, and twitter as if you were on irc

=head1 INSTALLATION

tircd requires a recent version of perl, and the following modules:

L<POE>

L<POE::Filter::IRCD>

L<Net::Twitter>

You can install them all by running:

C<cpan -i POE POE::Filter::IRCD Net::Twitter>

=head1 USAGE

=over

=item Running tircd

C<./tircd.pl [/path/to/tircd.cfg]>

When started, tircd will look for a configuration file named tircd.cfg (in the same directory as the program) or ~/.tircd. A sample configuration file is included with the program.
You can specify an alternate path to the configuration file on the commandline if you want to keep the configuration in another location.

=item Connecting

By default, tircd listens on localhost port 6667.

When connecting to tircd, you must ensure that your NICK is set to your twitter username, and that you send PASS with your twitter password.

With many irc clients you can do this by issuing the command /SERVER [hostname running tircd] 6667 <your twitter password> <your twitter username>.   Check your client's documentation for the appropirate syntax.

Once connected JOIN #twitter to get started.  The channel #twitter is where you will perform most opertions

=item Updating your status

To update your status on twitter, simply send a message to the #twitter channel.  The server will keep your most recent update in the topic at all times.

=item Getting your friend's status

When users you follow update their status, it will be sent to the channel as a message from them.

@replies are also sent to the channel as messages.

=item Listing the users you follow

Each user you follow will be in the #twitter channel.  If you follow a new user outside of tircd, that user will join the channel the first time they update their status.  People who follow you back are given voice (+v) to indicate that fact.


=item Direct Messages

Direct messages to you will show up as a private message from the user.

To send a direct message, simply send a private message to the user you want to dm.

=item Getting additional information on users

You can /who or /whois a user to view their Location / Bio / Website. Their last status update (and time sent) will also be returned.

Issuing a /whois on your own user name will also provide the number of API calls that have been used in the last hour.

=item Following new users

To begin following a new user, simply /invite them to #twitter.  The user will join the channel if the request to follow was successful.  If you attempt to invite a user who protects their updates, you will receive a notice that you have requested to follow them.  The user will join the channel if they accept your request and update their status.

=item Unfollowing / removing users

To stop following a user, /kick them from #twitter.

=item Blocking users 

To block a user /ban them.  
There is currently no way to get a list of users you've currently blocked via the API, so listing the bans in #twitter will only return users you've blocked in the current session.

=item Unblocking users

To unblock a user /unban them.

=back

=head1 AUTHOR

Chris Nelson <cnelson@crazybrain.org>

=head1 LICENSE

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

L<POE>

L<POE::Filter::IRCD>

L<Net::Twitter>

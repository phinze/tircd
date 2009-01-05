#!/usr/bin/perl
# tircd - An ircd proxy to the twitter API
# perldoc this file for more information.

use strict;
use Net::Twitter;
use Date::Manip;
use POE qw(Component::Server::TCP Filter::Stackable Filter::IRCD);
use Data::Dumper;

my $VERSION = 0.2;

#timing settings (how often we update the API) in seconds.  You want to ensure you don't end up with more than 100/hr calls to twitter
my $delay_twitter_timeline = 180; #how often we check for @replies and the timeline (2 calls)
my $delay_twitter_direct_messages = 180; #how often we check for new direct messages (1 call);


#setup our filter to process the IRC messages, jacked from the Filter:IRCD docs
my $filter = POE::Filter::Stackable->new();
$filter->push( POE::Filter::Line->new( InputRegexp => '\015?\012', OutputLiteral => "\015\012" ), POE::Filter::IRCD->new(debug => 0));

#setup our 'irc server'
POE::Component::Server::TCP->new(
  Alias			=> "tircd",              
  Port			=> 6667,
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

    server_reply => \&irc_reply,
    user_msg	 => \&irc_user_msg,
    
    twitter_timeline => \&twitter_timeline,
    twitter_direct_messages => \&twitter_direct_messages,
    
    startitup => \&tircd_startitup,
    getfriend => \&tircd_getfriend,
    updatefriend => \&tircd_updatefriend
    
  },
  ClientFilter		=> $filter, 
  ClientInput		=> \&irc_line,
);    

print "$0: version $VERSION started.\n";

$poe_kernel->run();                                                                
exit 0; 

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

#called once we have a user/pass
sub tircd_startitup {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  
  if ($heap->{'twitter'}) { #make sure we aren't called twice
    return;
  }

  #start up the twitter interface, and see if we can connect with the given NICK/PASS INFO
  my $twitter = Net::Twitter->new(username => $heap->{'username'}, password => $heap->{'password'});
  if (!$twitter->verify_credentials()) {
    $kernel->yield('server_reply',462,'Unable to login to twitter with the supplied credentials.');
    $kernel->yield('shutdown'); #disconnect 'em if we cant
    return;
  }

  #stash the twitter object for use in the session  
  $heap->{'twitter'} = $twitter;

  #some clients need this shit
  $kernel->yield('server_reply',001,"Welcome to tircd $heap->{'username'}");
  $kernel->yield('server_reply',002,"Your host is tircd running version $VERSION");
  $kernel->yield('server_reply',003,"This server was created just for you!");
  $kernel->yield('server_reply',004,"tircd $VERSION i int");

  #show 'em the motd
  $kernel->yield('MOTD');  
}

#called everytime we get a line from an irc server
#trigger an event and move on, the ones we care about will get trapped
sub irc_line {
  my  ($kernel, $data) = @_[KERNEL, ARG0];
  $kernel->yield($data->{'command'},$data); 
}

#send a message that looks like it came from a user
sub irc_user_msg {
  my ($heap, $code, $username, @params) = @_[HEAP, ARG0, ARG1, ARG2..$#_];

  $heap->{'client'}->put({
    command => $code,
    prefix => "$username!$username\@twitter",
    params => \@params
  });
}

#send a message that comes from the server
sub irc_reply {
  my ($heap, $code, @params) = @_[HEAP, ARG0, ARG1..$#_];
  
  unshift(@params,$heap->{'username'}); #prepend the target username to the message;

  $heap->{'client'}->put({
    command => $code,
    prefix => 'tircd', 
    params => \@params     
  }); 
}

#shutdown the socket when the user quits
sub irc_quit {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  $kernel->yield('shutdown');
}

#return the MOTD
sub irc_motd {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  $kernel->yield('server_reply',375,'- tircd Message of the Day -');

  $kernel->yield('server_reply',372,"- This code is uber alpha, if you got this far, consider your self lucky");
  $kernel->yield('server_reply',372,"- ");
  $kernel->yield('server_reply',372,"- /join #twitter to get started!");  
  $kernel->yield('server_reply',372,"- ");  
  $kernel->yield('server_reply',372,"- If you submit a bug report, please include your irc client and version");  
  $kernel->yield('server_reply',372,"- ");    
  $kernel->yield('server_reply',372,'- @cnelson <cnelson@crazybrain.org>');    

  $kernel->yield('server_reply',376,'End of /MOTD command.');
}

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
  $heap->{'username'} = $data->{'params'}[0]; #stash the username for later

  if ($heap->{'username'} && $heap->{'password'} && !$heap->{'twitter'}) {
    $kernel->yield('startitup');
  }
}

sub irc_user {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  if ($heap->{'username'} && $heap->{'password'} && !$heap->{'twitter'}) {
    $kernel->yield('startitup');
  }

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

  #spoof the channel join  
  $kernel->yield('user_msg','JOIN',$heap->{'username'},$chan);	
  $kernel->yield('server_reply',332,$chan,"$heap->{'username'}'s twiter");
  $kernel->yield('server_reply',333,$chan,'tircd!tircd@tircd',time());

  #get (and cache) the user's friends (i.e. the members of the channel)
  if (!$heap->{'friends'}) {
    my @friends = ();
    my $page = 1;  
    while (my $f = $heap->{'twitter'}->friends({page => $page})) {
      last if @$f == 0;    
      push(@friends,@$f);
      $page++;
    }
    $heap->{'friends'} = \@friends;
  }

  #the the list of our users for /NAMES
  my @users; my $lastmsg = '';
  foreach my $user (@{$heap->{'friends'}}) {
    if ($user->{'screen_name'} eq $heap->{'username'}) {
      $lastmsg = $user->{'status'}->{'text'};
    }
    push(@users,$user->{'screen_name'});
  }
  
  if (!$lastmsg) { #if we aren't already in the list, add us to the list for NAMES - AND go grab one tweet to put us in the array
    unshift(@users, $heap->{'username'});
    my $data = $heap->{'twitter'}->user_timeline({count => 1});
    if (@$data > 0) {
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
  $kernel->yield('twitter_timeline'); 
  $kernel->yield('twitter_direct_messages'); 
}

sub irc_part {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];
  my $chan = $data->{'params'}[0];
  
  if (exists $heap->{'channels'}{$chan}) {
    delete $heap->{'channels'}{$chan};
    $kernel->yield('user_msg','PART',$heap->{'username'},$chan);
  } else {
    $kernel->yield('server_reply',442,$chan,"You're not on that channel");
  }
}

sub irc_mode { #ignore all mode requests (send back the appropriate message to keep the client happy)
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  my $target = $data->{'params'}[0];
  if ($target =~ /^\#/) {
    if ($data->{'params'}[1] eq 'b') {
      $kernel->yield('server_reply',368,$target,'End of channel ban list');
    } else {
      $kernel->yield('server_reply',324,$target,"+tn");
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
        $kernel->yield('server_reply',352,$target,$friend->{'screen_name'},'twitter','tircd',$friend->{'screen_name'},'G',"0 $friend->{'name'}");
      }
    }      
  } else { #only support a ghetto version of /who right now, /who ** and what not won't work
    if (my $friend = $kernel->call($_[SESSION],'getfriend',$target)) {
        $kernel->yield('server_reply',352,'*',$friend->{'screen_name'},'twitter','tircd',$friend->{'screen_name'},'G',"0 $friend->{'name'}");
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
    $friend = $heap->{'twitter'}->show_user($target);
    $isfriend = 0;
  }
  
  if ($friend) {
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
     $kernel->yield('server_reply',301,$target,"Last Update: $friend->{'status'}->{'text'}");
    }

    if ($target eq $heap->{'username'}) { #if it's us, then add the rate limit info to
      my $rate = $heap->{'twitter'}->rate_limit_status();
      $kernel->yield('server_reply',301,$target,'API Usage: '.($rate->{'hourly_limit'}-$rate->{'remaining_hits'})." of $rate->{'hourly_limit'} calls used.");
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
    my $diff;
    if ($friend->{'status'}->{'created_at'}) {
      my $date = UnixDate(ParseDate($friend->{'status'}->{'created_at'}),'%s');
      $diff = time()-$date;
    } else {
      $diff = 0;
    }
    $kernel->yield('server_reply',317,$target,$diff,'seconds idle');

    if ($isfriend) {
      $kernel->yield('server_reply',319,$target,'#twitter ');
    }
  }

  $kernel->yield('server_reply',318,$target,'End of /WHOIS list'); 
}

sub irc_privmsg {
  my ($kernel, $heap, $data) = @_[KERNEL, HEAP, ARG0];

  my $target = $data->{'params'}[0];
  my $msg  = $data->{'params'}[1];

  if ($target =~ /^#/) {
    if (!exists $heap->{'channels'}->{$target}) {
      $kernel->yield('server_reply',404,$target,'Cannot send to channel');
      return;
    }

    #in a channel, this an update
    my $update = $heap->{'twitter'}->update($msg);
    $msg = $update->{'text'};
    
    #update our own friend record
    my $me = $kernel->call($_[SESSION],'getfriend',$heap->{'username'});
    $me = $update->{'user'};
    $me->{'status'} = $update;
    $kernel->call($_[SESSION],'updatefriend',$me);
    
    #keep the topic updated with our latest tweet  
    $kernel->yield('user_msg','TOPIC',$heap->{'username'},$target,"$heap->{'username'}'s last update: $msg");
  } else { 
    #private message, it's a dm
    my $dm = $heap->{'twitter'}->new_direct_message({user => $target, text => $msg});
    if (!$dm) {
      $kernel->yield('server_reply',401,$target,"Unable to send direct message.  Perhaps $target isn't following you?");
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

  my $user = $heap->{'twitter'}->create_friend({id => $target});
  if ($user) {
    if (!$user->{'protected'}) {
      #if the user isn't protected, and we are following them now, then have 'em 'JOIN' the channel
      push(@{$heap->{'friends'}},$user);
      $kernel->yield('server_reply',341,$user->{'screen_name'},$chan);
      $kernel->yield('user_msg','JOIN',$user->{'screen_name'},$chan);
    } else {
      #show a note if they are protected and we are waiting 
      #this should technically be a 482, but some clients were exiting the channel for some reason
      $kernel->yield('server_reply',481,"$target\'s updates are protected.  Request to follow has been sent.");
    }
  } else {
    $kernel->yield('server_reply',401,$target,'No such nick/channel');
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

  my $result = $heap->{'twitter'}->destroy_friend($target);
  if ($result) {
    $kernel->yield('user_msg','KICK',$heap->{'username'},$chan,$target,$target);
  } else {
    $kernel->yield('server_reply',441,$target,$chan,"They aren't on that channel");  
  }  

}

sub twitter_timeline {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  #get updated messages
  my $timeline;
  if ($heap->{'timeline_since_id'}) {
    $timeline = $heap->{'twitter'}->friends_timeline({since_id => $heap->{'timeline_since_id'}});
  } else {
    $timeline = $heap->{'twitter'}->friends_timeline();
  }

  #sometimes the twitter API returns undef, so we gotta check here
  if (!$timeline || @$timeline == 0) {
    $timeline = [];
  } else {
    #if we got new data save our position
    $heap->{'timeline_since_id'} = @{$timeline}[0]->{'id'};
  }

  #get updated @replies too
  my $replies;
  if ($heap->{'replies_since_id'}) {
    $replies = $heap->{'twitter'}->replies({since_id => $heap->{'replies_since_id'}});
  } else {
    $replies = $heap->{'twitter'}->replies({page =>1}); #avoid a bug in Net::Twitter
  }

  if (!$replies || @$replies == 0) {
    $replies = [];
  } else {  
    $heap->{'replies_since_id'} = @{$replies}[0]->{'id'};
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
    
    #filter out our own messages
    if ($item->{'user'}->{'screen_name'} ne $heap->{'username'}) {
      $kernel->yield('user_msg','PRIVMSG',$item->{'user'}->{'screen_name'},'#twitter',$item->{'text'});
    }
  }

  $kernel->delay('twitter_timeline',$delay_twitter_timeline);
}

#same as above, but for direct messages, show 'em as PRIVMSGs from the user
sub twitter_direct_messages {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my $data;
  if ($heap->{'direct_since_id'}) {
    $data = $heap->{'twitter'}->direct_messages({since_id => $heap->{'direct_since_id'}});
  } else {
    $data = $heap->{'twitter'}->direct_messages();
  }

  if (!$data || @$data == 0) {
    $data = [];
  } else {
    $heap->{'direct_since_id'} = @{$data}[0]->{'id'};
  }

  foreach my $item (sort {$a->{'id'} <=> $b->{'id'}} @{$data}) {
    if (!$kernel->call($_[SESSION],'getfriend',$item->{'sender'}->{'screen_name'})) {
      my $tmp = $item->{'sender'};
      $tmp->{'status'} = $item;
      $tmp->{'status'}->{'text'} = '(dm) '.$tmp->{'status'}->{'text'};
      push(@{$heap->{'friends'}},$tmp);
      $kernel->yield('user_msg','JOIN',$item->{'sender'}->{'screen_name'},'#twitter');
    }
    
    $kernel->yield('user_msg','PRIVMSG',$item->{'sender'}->{'screen_name'},$heap->{'username'},$item->{'text'});
  }

  $kernel->delay('twitter_direct_messages',$delay_twitter_direct_messages);
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

L<Date::Manip>

You can install them all by running:

C<cpan -i POE POE::Filter::IRCD Net::Twitter Date::Manip>

=head1 USAGE

=over

=item Connecting

tircd listens on port 6667.

When connecting to tircd, you must ensure that your NICK is set to your twitter username, and that you send PASS with your twitter password.

With may irc clients you can do this by issuing the command /SERVER [hostname running tircd] 6667 <your twitter password> <your twitter username>.   Check your client's documentation for the appropirate syntax.

Once connected JOIN #twitter to get started.  The channel #twitter is will you will perform most opertions

=item Updating your status

To update your status on twitter, simply send a message to the #twitter channel.  The server will keep your most recent update in the topic at all times.

=item Getting your friend's status

When users you follow update their status, it will be sent to the channel as a message from them.

@replies are also sent to the channel as messages.

=item Listing the users you follow

Each user you follow will be in the #twitter channel.  If you follow a new user outside of tircd, that user will join the channel the first time they update their status.

=item Direct Messages

Direct messages to you will show up as a private message from the user.

To send a direct message simple send a private message to the user you want to dm.

=item Getting additional information on users

You can /who or /whois a user to view their Location / Bio / Website. Their last status update (and time sent) will also be returned.

Issuing a /whois on your own user name will also provide the number of API calls that have been used in the last hour.

=item Following new users

To being following a new user, simply /invite them to #twitter.  The user will join the channel if the request to follow was successful.  If you attempt to invite a user who protects their updates, you will receive a notice that you have requested to follow them.  The user will join the channel if they accept your request and update their status.

=item Unfollowing / removing users

To stop following a user, /kick them from #twitter.

=back

=head1 AUTHOR

Chris Nelson <cnelson@crazybrain.org>

=head1 LICENSE

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=head1 SEE ALSO

L<POE>

L<POE::Filter::IRCD>

L<Net::Twitter>

L<Date::Manip>

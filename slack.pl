#!/usr/bin/perl
#
# Copyright 2014 Ted 'tedski' Strzalkowski <contact@tedski.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# The complete text of the GNU General Public License can be found
# on the World Wide Web: <http://www.gnu.org/licenses/gpl.html/>
#
# slack irssi plugin
# 
# A plugin to add functionality when dealing with Slack.
# See http://slack.com/ for details on what Slack is.
#
# usage:
#
# there are 2 settings available:
#
# /set slack_token team1:token1 team2:token2
#  - The api token from https://api.slack.com/docs/oauth-test-tokens
#
# /set slack_loglines <integer>
#  - the number of lines to grab from channel history
# 

use strict;

use Irssi;
use Irssi::TextUI;
use JSON;
use URI;
use LWP::UserAgent;
use HTML::Entities;
BEGIN {
  local $@;
  eval { require Mozilla::CA; };
  if ($@) {
    warn $@;
  }
}
use POSIX qw(strftime);

our $VERSION = "0.1.1";
our %IRSSI = (
  authors     => "Ted \'tedski\' Strzalkowski",
  contact     => "contact\@tedski.net",
  name	      => "slack",
  description => "Add functionality when connected to the Slack IRC Gateway.",
  license     => "GPL",
  url	      => "https://github.com/tedski/slack-irssi/",
 );

my $baseurl = "https://slack.com/api/";
my $svrre = qr/\.irc\.slack\.com/;
my $lastupdate = 0;
my %servertag;

sub init {
  my @servers = Irssi::servers();

  foreach my $server (@servers) {
    if ($server->{address} =~ /^(.*?)$svrre/) {
      $servertag{ $server->{tag} } = $1;
    }
  }
}

sub api_call {
  my ($tag, $method, $url) = @_;

  my $resp;
  my $payload;
  my $ua = LWP::UserAgent->new;
  $ua->agent("$IRSSI{name} irssi/$VERSION");
  $ua->timeout(3);
  $ua->env_proxy;

  my $token = get_token($tag);
  return unless $token;
  $url->query_form($url->query_form, 'token' => $token);

  $resp = $ua->$method($url);
  $payload = from_json($resp->decoded_content);
  if ($resp->is_success) {
    if (! $payload->{ok}) {
      Irssi::print("The Slack API returned the following error: $payload->{error}", MSGLEVEL_CLIENTERROR) unless $payload->{error} eq 'channel_not_found';
    }
    return $payload;
  }
  else {
    Irssi::print("Error calling the slack api: $resp->{code} $resp->{message}", MSGLEVEL_CLIENTERROR);
  }
}

sub sig_server_conn {
  my ($server) = @_;

  if ($server->{address} =~ /^(.*?)$svrre/) {
    $servertag{ $server->{tag} } = $1;

    get_users( $server->{tag} );
  }
}

sub sig_server_disc {
  my ($server) = @_;

  if ($servertag{ $server->{tag} }) {
    Irssi::signal_remove('channel joined', 'get_chanlog');
  }
}

my %USERS;
my %LAST_USERS_UPDATE;

sub get_token {
  my ($tag) = @_;
  my $str = Irssi::settings_get_str($IRSSI{'name'} . '_token');
  if ($str =~ /:/) {
    my %map = split /:|\s+/, $str;
    $map{ $servertag{ $tag } }
  } else {
    $str
  }
}

sub get_all_users {
  for my $tag (keys %servertag) {
    get_users($tag) if $servertag{ $tag };
  }
}

sub get_users {
  my ($tag) = @_;
  return unless get_token($tag);

  if (($LAST_USERS_UPDATE{$tag} + 4 * 60 * 60) < time()) {
    my $url = URI->new($baseurl . 'users.list');

    my $resp = api_call($tag, 'get', $url);

    if ($resp->{ok}) {
      my $slack_users = $resp->{members};
      foreach my $u (@{$slack_users}) {
        $USERS{$tag}{$u->{id}} = $u->{name};
      }
      $LAST_USERS_UPDATE{$tag} = time();
    }
  }
}

my %CHANNELS;
my %CHANNEL_TYPE;
my %LAST_CHANNELS_UPDATE;
sub chan_joined {
  my ($channel) = @_;
  my $tag = $channel->{server}{tag};
  if ($servertag{ $tag }) {
    $LAST_CHANNELS_UPDATE{ $tag } = 0;
  }
}
sub get_chanid {
  my ($tag, $channame, $force) = @_;

  if ($force || (($LAST_CHANNELS_UPDATE{$tag} + 4 * 60 * 60) < time())) {
    for my $resource (qw(channels groups)) {
      my $url = URI->new($baseurl . $resource . '.list');
      $url->query_form('exclude_archived' => 1);

      my $resp = api_call($tag, 'get', $url);

      if ($resp->{ok}) {
	foreach my $c (@{$resp->{$resource}}) {
	  $CHANNELS{$tag}{$c->{name}} = $c->{id};
	  $CHANNEL_TYPE{$tag}{$c->{name}} = $resource;
	}
	$LAST_CHANNELS_UPDATE{$tag} = time();
      }
    }
  }

  return $CHANNELS{$tag}{$channame};
}

sub get_query_log {
  &Irssi::signal_continue;
  my ($query) = @_;
  my $tag = $query->{server}{tag};
  if ($servertag{ $tag }) {
    get_users($tag);
    my $count = Irssi::settings_get_int($IRSSI{'name'} . '_loglines');
    my $url = URI->new($baseurl . 'im.list');
    my $resp = api_call($tag, 'get', $url);
    return unless $resp->{ok};
    for my $im (@{$resp->{ims}}) {
      if (lc $USERS{$tag}{$im->{user}} eq lc $query->{name}) {
	my $url = URI->new($baseurl . 'im.history');
	$url->query_form('channel' => $im->{id},
			 'count' => $count);
	my $resp = api_call($tag, 'get', $url);
	if ($resp->{ok}) {
	  print_history($resp, $query);
	}
      }
    }
  }
}

sub get_chanlog {
  my ($channel) = @_;
  my $tag = $channel->{server}{tag};
  if ($servertag{ $tag }) {

    get_users($tag);

    my $count = Irssi::settings_get_int($IRSSI{'name'} . '_loglines');
    $channel->{name} =~ s/^#//;
    my $url = URI->new($baseurl . 'channels.history');
    $url->query_form('channel' => get_chanid($tag, $channel->{name}),
		     'count' => $count);

    my $resp = api_call($tag, 'get', $url);

    if (!$resp->{ok}) {
      # First try failed, so maybe this chan is actually a private group
      #Irssi::print($channel->{name}. " appears to be a private group");
      $url = URI->new($baseurl . 'groups.history');
      my $groupid = get_chanid($tag, $channel->{name});
      $url->query_form('channel' => $groupid,
                       'count' => $count);
      $resp = api_call($tag, 'get', $url);
    }

    if ($resp->{ok}) {
      print_history($resp, $channel);
    }
  }
}

sub print_history {
  my ($resp, $channel) = @_;
  my $tag = $channel->{server}{tag};
  my $msgs = $resp->{messages};
  foreach my $m (reverse(@{$msgs})) {
    if ($m->{type} eq 'message') {
      if ($m->{subtype} eq 'message_changed') {
	$m->{text} = $m->{message}->{text};
	$m->{user} = $m->{message}->{user};
      }
      elsif ($m->{subtype}) {
	next;
      }
      $m->{text} =~ s{([<][@](U\w+)[>])}{\@@{[ $USERS{$tag}{$2} // $1]}}g;
      my $ts = strftime('%H:%M', localtime $m->{ts});
      $channel->printformat(MSGLEVEL_PUBLIC | MSGLEVEL_NO_ACT, "slackmsg", $USERS{$tag}{$m->{user}}, decode_entities($m->{text}), "+", $ts);
    }
  }
}

my %LAST_MARK_UPDATED;
sub update_slack_mark {
  my ($window) = @_;
  my $tag = $window->{active_server}{tag};
  return unless ($window->{active}->{type} eq 'CHANNEL' &&
		 $servertag{ $tag });
  return unless Irssi::settings_get_str($IRSSI{'name'} . '_token');

  # Leave $line set to the final visible line, not the one after.
  my $view = $window->view();
  my $line = $view->{startline};
  my $count = $view->get_line_cache($line)->{count};
  while ($count < $view->{height} && $line->next) {
    $line = $line->next;
    $count += $view->get_line_cache($line)->{count};
  }

  # Only update the Slack mark if the most recent visible line is newer.
  my($channel) = $window->{active}->{name} =~ /^#(.*)/;
  if ($LAST_MARK_UPDATED{$tag}{$channel} < $line->{info}->{time}) {
    my $url = URI->new($baseurl . $CHANNEL_TYPE{$tag}{$channel} . '.mark');
    $url->query_form('channel' => get_chanid($tag, $channel),
		     'ts' => $line->{info}->{time});

    api_call($tag, 'get', $url);
    $LAST_MARK_UPDATED{$tag}{$channel} = $line->{info}->{time};
  }
}

sub sig_window_changed {
  my ($new_window) = @_;
  if (Irssi::settings_get_bool($IRSSI{'name'} . '_automark')) {
    update_slack_mark($new_window);
  }
}

sub sig_message_public {
  my ($server, $msg, $nick, $address, $target) = @_;

  my $window = Irssi::active_win();
  if ($window->{active}->{type} eq 'CHANNEL' &&
      $window->{active}->{name} eq $target &&
      $window->{bottom}) {
    if (Irssi::settings_get_bool($IRSSI{'name'} . '_automark')) {
      update_slack_mark($window);
    }
  }
}

sub cmd_mark {
  my ($mark_windows) = @_;

  my(@windows) = Irssi::windows();
  my @mark_windows;
  foreach my $name (split(/\s+/, $mark_windows)) {
    if ($name eq 'ACTIVE') {
      push(@mark_windows, Irssi::active_win());
      next;
    }

    foreach my $window (@windows) {
      if ($window->{name} eq $name) {
        push(@mark_windows, $window);
      }
    }
  }
  foreach my $window (@mark_windows) {
    update_slack_mark($window);
  }
}

# setup
init();

# themes
Irssi::theme_register(['slackmsg', '{timestamp $3} {pubmsgnick $2 {pubnick $0}}$1%[-t]']);

# signals
Irssi::signal_add('server connected', 'sig_server_conn');
Irssi::signal_add('server disconnected', 'sig_server_disc');
Irssi::signal_add('setup changed', 'get_all_users');
Irssi::signal_add('channel joined', 'chan_joined');
Irssi::signal_add('channel joined', 'get_chanlog');
Irssi::signal_add('query created', 'get_query_log');
Irssi::signal_add('window changed', 'sig_window_changed');
Irssi::signal_add('message public', 'sig_message_public');

# renamed because it conflicts with trackbar's /mark
Irssi::command_bind('slackmark', 'cmd_mark');

# settings
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_token', '');
Irssi::settings_add_int('misc', $IRSSI{'name'} . '_loglines', 200);
Irssi::settings_add_bool('misc', $IRSSI{'name'} . '_automark', 1);

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
# /set slack_token <string>
#  - The api token from https://api.slack.com/
#
# /set slack_loglines <integer>
#  - the number of lines to grab from channel history
# 

use strict;

use Irssi;
use JSON;
use URI;
use LWP::UserAgent;
use Mozilla::CA;
use POSIX qw(strftime);
use vars qw($VERSION %IRSSI $token $servertag $forked);

our $VERSION = "0.1.1";
our %IRSSI = (
    authors => "Ted \'tedski\' Strzalkowski",
    contact => "contact\@tedski.net",
    name  => "slack",
    description => "Add functionality when connected to the Slack IRC Gateway.",
    license => "GPL",
    url   => "https://github.com/tedski/slack-irssi/",
    changed => "Wed, 13 Aug 2014 03:12:04 +0000"
);

my $baseurl = "https://slack.com/api/";
my $svrre = qr/^$IRSSI{'name'}\.irc\.slack\.com/;
my $lastupdate = 0;

sub init {
  my @servers = Irssi::servers();

  foreach my $server (@servers) {
    if ($server->{address} =~ /$svrre/) {
      $servertag = $server->{tag};
    }
  }
}

sub api_call {
  my ($method, $url) = @_;

  my $resp;
  my $payload;
  my $ua = LWP::UserAgent->new;
  $ua->agent("$IRSSI{name} irssi/$VERSION");
  $ua->timeout(3);
  $ua->env_proxy;

  $token = Irssi::settings_get_str($IRSSI{'name'} . '_token');
  $url->query_form($url->query_form, 'token' => $token);

  $resp = $ua->$method($url);
  $payload = from_json($resp->decoded_content);
  if ($resp->is_success) {
    if (! $payload->{ok}) {
      Irssi::print("The Slack API returned the following error: $payload->{error}", MSGLEVEL_CLIENTERROR);
    } else {
    return $payload;
    }
  } else {
    Irssi::print("Error calling the slack api: $resp->{code} $resp->{message}", MSGLEVEL_CLIENTERROR);
  }
}

sub sig_server_conn {
  my ($server) = @_;

  if ($server->{address} =~ /$svrre/) {
    $servertag = $server->{tag};

    Irssi::signal_add('channel joined', 'get_chanlog');

    get_users();
  }
}

sub sig_server_disc {
  my ($server) = @_;

  if ($server->{tag} eq $servertag) {
    Irssi::signal_remove('channel joined', 'get_chanlog');
  }
}

my %USERS;
my $LAST_USERS_UPDATE;
sub get_users {
  return unless Irssi::settings_get_str($IRSSI{'name'} . '_token');

  if (($LAST_USERS_UPDATE + 4 * 60 * 60) < time()) {
    my $url = URI->new($baseurl . 'users.list');

    my $resp = api_call('get', $url);

    if ($resp->{ok}) {
      my $slack_users = $resp->{members};
      foreach my $u (@{$slack_users}) {
        $USERS{$u->{id}} = $u->{name};
      }
      $LAST_USERS_UPDATE = time();
    }
  }
}

my %CHANNELS;
my $LAST_CHANNELS_UPDATE;
sub chan_joined {
  my ($channel) = @_;

  if ($channel->{server}->{tag} eq $servertag) {
    $LAST_CHANNELS_UPDATE = 0;
  }
}
sub get_chanid {
  my ($channame) = @_;

  if (($LAST_CHANNELS_UPDATE + 4 * 60 * 60) < time()) {
    my $url = URI->new($baseurl . 'channels.list');
    $url->query_form('exclude_archived' => 1);

    my $resp = api_call('get', $url);

    if ($resp->{ok}) {
      foreach my $c (@{$resp->{channels}}) {
        $CHANNELS{$c->{name}} = $c->{id};
      }
      $LAST_CHANNELS_UPDATE = time();
    }
  }

  return $CHANNELS{$channame};
}    

sub get_chanlog {
  my ($channel) = @_;

  if ($channel->{server}->{tag} eq $servertag) {

    get_users();

    my $count = Irssi::settings_get_int($IRSSI{'name'} . '_loglines');
    $channel->{name} =~ s/^#//;
    my $url = URI->new($baseurl . 'channels.history');
    $url->query_form('channel' => get_chanid($channel->{name}),
      'count' => $count);

    my $resp = api_call('get', $url);

    if ($resp->{ok}) {
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
          my $ts = strftime('%H:%M', localtime $m->{ts});
          $channel->printformat(MSGLEVEL_PUBLIC, "slackmsg", $USERS{$m->{user}}, $m->{text}, "+", $ts);
        }
      }
    }
  }
}

my %LAST_MARK_UPDATED;
sub update_slack_mark {
  my ($window) = @_;

  return unless ($window->{active}->{type} eq 'CHANNEL' &&
                 $window->{active_server}->{tag} eq $servertag);
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
  if ($LAST_MARK_UPDATED{$channel} < $line->{info}->{time}) {
    my $url = URI->new($baseurl . 'channels.mark');
    $url->query_form('channel' => get_chanid($channel),
      'ts' => $line->{info}->{time});

    api_call('get', $url);
    $LAST_MARK_UPDATED{$channel} = $line->{info}->{time};
  }
}

sub sig_window_changed {
  my ($new_window) = @_;
  update_slack_mark($new_window);
}

sub sig_message_public {
  my ($server, $msg, $nick, $address, $target) = @_;

  my $window = Irssi::active_win();
  if ($window->{active}->{type} eq 'CHANNEL' &&
      $window->{active}->{name} eq $target &&
      $window->{bottom}) {
    update_slack_mark($window);
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
Irssi::theme_register(['slackmsg', '{timestamp $3} {pubmsgnick $2 {pubnick $0}}$1']);

# signals
Irssi::signal_add('server connected', 'sig_server_conn');
Irssi::signal_add('server disconnected', 'sig_server_disc');
Irssi::signal_add('setup changed', 'get_users');
Irssi::signal_add('window changed', 'sig_window_changed');
Irssi::signal_add('message public', 'sig_message_public');

Irssi::command_bind('mark', 'cmd_mark');

# settings
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_token', '');
Irssi::settings_add_int('misc', $IRSSI{'name'} . '_loglines', 20);

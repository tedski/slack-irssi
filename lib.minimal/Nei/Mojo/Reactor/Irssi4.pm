package Nei::Mojo::Reactor::Irssi4;
BEGIN { $ENV{MOJO_REACTOR} ||= __PACKAGE__; }

use strict;
use warnings;
no warnings 'redefine';

use Irssi ();
use List::Util 'max';
use Carp 'carp';
use Scalar::Util 'weaken';
use Mojo::Util qw(steady_time md5_sum);

sub one_tick { carp "cannot tick" }
sub next_tick { shift->timer(0 => @_) and return undef }
sub start { carp "cannot start" }
sub stop { carp "cannot stop" unless caller eq 'Mojo::IOLoop' }
sub is_running { 1 }

sub again {
    shift->_dotime(shift());
    return;
}

sub recurring { shift->_timer(1, @_) }
sub timer { shift->_timer(0, @_) }

sub io {
    my ($self, $handle, $cb) = @_;
    $self->remove($handle);
    $self->{io}{fileno $handle} = {cb => $cb};
    return $self->watch($handle, 1, 1);
}

sub remove {
    my ($self, $remove) = @_;
    unless (ref $remove) {
	if (my $timer = delete $self->{timers}{$remove}) {
	    $self->irssi_timeout_remove(delete $timer->{tag}) if defined $timer->{tag};
	    return 1;
	}
	return 0;
    }
    if (my $io = delete $self->{io}{fileno $remove}) {
	$self->irssi_input_remove(delete $io->{tag}) if defined $io->{tag};
	return 1;
    }
    return 0;
}

sub reset {
    my $self = shift;
    for my $timer (values %{$self->{timers}//+{}}) {
	$self->irssi_timeout_remove(delete $timer->{tag}) if defined $timer->{tag};
    }
    for my $io (values %{$self->{io}//+{}}) {
	$self->irssi_input_remove(delete $io->{tag}) if defined $io->{tag};
    }
    delete @{$self}{'io', 'timers'};
    return;
}

sub _dispatch {
    my $self = shift;
    my $tag = shift;
    if (@_) {
	my $io = $self->{io}{$tag};
	weaken $io; # the read cb can nuke it
	$self->_sandbox('Read', $io->{cb}, 0) if $_[0];
	$self->_sandbox('Write', $io->{cb}, 1) if $_[1] && $io;
    }
    else {
	my $t = $self->{timers}{$tag};
	$self->_sandbox("Timer $tag", $t->{cb}) if $t->{cb};
    }
}

sub watch {
    my ($self, $handle, $read, $write) = @_;
    my $fn = fileno $handle;
    my $io = $self->{io}{$fn};
    my $oldtag = $io->{tag} // "x";
    $self->irssi_input_remove(delete $io->{tag}) if defined $io->{tag};
    my $mode;
    $mode |= Irssi::INPUT_READ if $read;
    $mode |= Irssi::INPUT_WRITE if $write;

    if (defined $mode && $io->{cb}) {
	weaken $self;
	$io->{tag} = $self->irssi_input_add($fn, $mode, sub {$self->_dispatch($fn,$read,$write)}, '');
    }

    return $self;
}

sub _sandbox {
    my ($self, $event, $cb) = (shift, shift, shift);
    eval { $self->$cb(@_); 1 } or $self->emit(error => "$event failed: $@");
}

sub _timer {
    my ($self, $recurring, $after, $cb) = @_;

    my $timers = $self->{timers} //= {};
    my $id;
    do { $id = md5_sum('t' . steady_time . rand 999) } while $timers->{$id};
    $timers->{$id}
	= {cb => $cb, after => $after, recurring => $recurring};

    my $tag = $self->_dotime($id);
    return $id;
}

sub _dotime {
    my $self = shift;
    my $id = shift;
    my $t = $self->{timers}{$id};
    $self->irssi_timeout_remove(delete $t->{tag}) if defined $t->{tag};
    if ($t->{recurring}) {
	weaken $self;
	$t->{tag} = $self->irssi_timeout_add(_itime($t->{after}), sub {$self->_dispatch($id)}, '')
    }
    else {
	weaken $self;
	$t->{tag} = $self->irssi_timeout_add_once(_itime($t->{after}), sub {$self->_dispatch($id)}, '')
    }
    return $t->{tag};
}

sub _itime { max(10, int($_[0] * 1000)) }

# Copied from the AnyEvent binding
sub bind {
    my $pkg = caller;
    our @ISA = $pkg;
    eval "package $pkg; " . <<'PERL';
# the Irssi Reactor binding script
use Mojo::Base 'Mojo::Reactor';

sub irssi_timeout_add_once { shift; &Irssi::timeout_add_once }
sub irssi_timeout_add      { shift; &Irssi::timeout_add      }
sub irssi_timeout_remove   { shift; &Irssi::timeout_remove   }
sub irssi_input_add        { shift; &Irssi::input_add        }
sub irssi_input_remove     { shift; &Irssi::input_remove     }

Irssi::signal_add_first "command script unload" => sub {
    (my $data = $_[0]) =~ s/\s+(.*)//;
    Irssi::signal_stop
	if __PACKAGE__ eq "Irssi::Script::\L$data" && (!$1 || '-force' ne "\L$1")
};

sub UNLOAD { Mojo::IOLoop->reset; return }

1;
PERL

    print __PACKAGE__." fatal compilation error: $@" if $@;
}

Irssi::command "script exec -permanent ".__PACKAGE__."::bind 'Mojo support'";

1;

=encoding utf8

=head1 NAME

Mojo::Reactor::Irssi - Low-level event reactor with Irssi support

=head1 DESCRIPTION

L<Mojo::Reactor::Poll> is a low-level event reactor based on L<Irssi>.

=head1 EVENTS

L<Mojo::Reactor::Irssi> inherits all events from L<Mojo::Reactor>.

=cut

package IO::Multiplex;
# event driven multiplex server.
# threading is so much easier but I don't have threads installed yet,
# and i don't feel like waiting.
# Wed Mar 10 23:41:15 IST 1999

use IO::Select;
use IO::Socket;
use vars qw($VERSION);

$VERSION = '0.1';

use strict;

# constructor.
sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = @_;

    my $self = {
	'loop_timeout' => 60,
        map {$_ => undef} ('localpath', 'localaddr', 'localport', 'proto'),
    };
    extract_args($self, \%args);

    $self->{'last_timeout'} = time;
    
    $self->{'proto'} ||= ($self->{'localpath'} ? 'unix' : 'tcp');
    if($self->{'proto'} eq 'unix') {
        unlink($self->{'localpath'});
        die "localpath missing" unless $self->{'localpath'};
        die "can't remove stale link" if -e $self->{'localpath'};
        umask 0;
        $self->{'socket'} = IO::Socket::UNIX->new
            ('Local' => $self->{'localpath'},
             'Listen' => $self->{'listen'} || 10);
        umask 022;
        
    } else {
        die "localport missing"
            unless($self->{'localport'}
                   || index($self->{'localpath'}, ':') != -1);
        $self->{'socket'} = IO::Socket::INET->new
            ('LocalAddr' => $self->{'localaddr'},
             'LocalPort' => $self->{'localport'},
             'Proto' => $self->{'proto'},
             'Listen' => $self->{'listen'} || 10,
             'Reuse' => 1);
    };
    die "can't create listen socket" unless $self->{'socket'};

    $self->{'select_obj'} = IO::Select->new($self->{'socket'});
    $self->{'handlers'} = init_handlers();
    
    bless($self, $class);
}

# destructor.
sub close
{
    my $self = shift;
    my $select = $self->{'select_obj'};
    my @handles = $select->handles;
    foreach my $handle (@handles) {
	$handle->close;
    }
}

# assign a handler to an event;
sub set_handler
{
    my ($self, $event, $handler) = @_;
    $self->{'handlers'}->{$event} = $handler;
}

# begin event driven main loop.
sub start
{
    my $self = shift;

    for(;;) 
    {
	if(time - $self->{'last_timeout'} > $self->{'loop_timeout'})
	{
	    $self->handler('loop_timeout')->();
	    $self->{'last_timeout'} = time;
	}

	my $select = $self->{'select_obj'};
	my @ready = $select->can_read($self->{'loop_timeout'});
	for my $fh (@ready)
	{
	    my $listen = $self->{'socket'};
	    if($fh == $listen)
	    {
		my $client = $listen->accept;
		$client->autoflush;

		if($self->handler('client_connected')->($client)) {
		    $select->add($client);
		} else {
		    $client->close;
		}
		next;
	    }

	    $self->handler('client_input')->($fh);
	}
    }
    # NOT REACHED
}

# disconnect a client.
sub disconnect
{
    my ($self, $client) = @_;
    $self->handler('client_disconnected')->($client);
    $self->{'select_obj'}->remove($client);
    $client->close;
}

######################################
# PRIVATE: TRESPASSERS WILL BE SHOT. #
######################################
sub init_handlers
{
    my $handlers;
    my @events = ('loop_timeout',
		  'client_connected', 'client_disconnected', 'client_input');

    foreach my $event (@events) { $handlers->{$event} = sub {} }
    return $handlers;
}

sub handler
{
    my ($self, $event) = @_;
    return $self->{'handlers'}->{$event};
}

# extract from caller's argument hash list to local argument hash list.
sub extract_args
{
    my ($local_args, $caller_args) = @_;
    foreach my $argument_key (keys %$caller_args)
    {
	next unless(exists $local_args->{lc $argument_key});
	$local_args->{lc $argument_key} = $caller_args->{$argument_key};
	delete $caller_args->{$argument_key};
    }
    return $local_args;
}

sub DESTROY
{
    my $self = shift;
    $self->close;
}

1;

__END__

=head1 NAME

IO::Multiplex - Object interface to multiplex-style server implementations.

=head1 SYNOPSIS

use IO::Multiplex;

=head1 DESCRIPTION

IO::Multiplex is an object interface to classic multiplex server designs.

Alarmed by the time I was wasting re-implementing a fairly straightforward
multiplexing server design, I decided it was time I abstracted the problem into
an object for re-use. If the term 'multiplexing' preplexes you, read
L<select(2)>, or read a good book on socket communications, I'm pretty sure
most of them cover the subject.

This implementation is based on an event model. Users (programmers)
control server behaviour by assigning handlers to certain server events
(client connected, disconnected, input from client, server timeout).

=head1 CONSTRUCTOR

=over 4
    
=item IO::Multiplex->new( %options );        

Server construction arguments are supplied in a hash format.

IO::Multiplex->new(arg1 => 'val1', arg2 => 'val2' ...)

=head2 ARGUMENTS

Arguments define how the server will communicate with it's clients.

=item 'loop_timeout'

Users may sometime find it useful to schedule a handler to be re-executed
periodicly within the server's main event loop every defined number of
seconds. Setting this argument will define the time interval between
executions of the 'timeout' event.

=item 'proto'

Optional. Setting this argument will define the server's
communication layer with it's clients. Common values are 'unix' and 'tcp'.
Other values ('udp' ?) are passed on to the IO::Socket::INET object.

If left undefined, IO::Multiplex will determine the server's transport
layer by looking at some of the other arguments. 

example: ('proto' => 'tcp', ...)

=item 'localpath'

Passed on to the IO::Socket::UNIX object constructor,
as the 'Local' options.

B<Warnings>: we remove stale sockets by unlinking 'localpath' for you,
any other file that happens to be there is removed with B<no> warning.

Sockets are created with full world read-write permissions.
This means any local user with execute permissions on
the target directory can talk to the server.

B<Restrictions>: Please realize you do need ordinary file write permissions
to create a socket in a directory of choice.

=item 'localaddr'

Optional. Passed on to the IO::Socket::INET object constructor,
as the 'LocalAddr' option.

Setting this argument will define the server's local
bind address, which is necessary in the case of multiple local network
interfaces (routers, firewalls, proxies).

If left undefined, IO::Socket::INET will assume 'localhost'.

example: ('localaddr' => 'localhost', ...)

=item 'localport'

Passed on to the IO::socket::INET object constructor.
Setting this argument will define the server's local bind port.

B<Restrictions>: If your running unix, binding to port numbers
below 1024 is only allowed by root.

example: ('localport' => 6666, ...)

=back

=head1 METHODS

=over 4

=item set_handler($event, \&handler)

Set a handler for an event. See B<EVENTS> further in this manual.

=item start()

Start main (infinite) event loop. Don't expect the program to return
over execution after starting the B<start> method.

B<Snippet>:

$server->start()
# NOT REACHED

=item disconnect($client_filehandle)

Disconnect a client_filehandle, envoking the $client_filehandle->close method
and calling the 'client_disconnected' method. It is very important for users
to understand that the server will never call this method on it's own.

When users decide a client should go, this is the only proper way to
disconnect it (removing it from the server's internal 'select' object).

=back

=head1 EVENTS

A brief reference discription of the server's events. With 'loop_timeout'
being the exception, all events will be called with one argument:

($client_filehandle).

Event handlers should B<*never*> block, or the server will (obviously, since
we're under a single process model) deadlock for the duration of the execution
misbehaving handler.

=over 4

=item 'loop_timeout' ()

Define a handler for 'loop_timeout'. A time-based event called in repeated
intervals of every 'loop_timeout' seconds. Useful when a server needs
to wake up in an inconditional interval and get something done.

Don't forget to assign supply a value for the 'loop_timeout' argument
in the server's constructor method.

=item 'client_input' ($client_filehandle)

The select object decided a client has something to say, and handler
should read from $client_filehandle and handle input.

Note if input is null, client has most likely disconnected and
$server->disconnect should be invoked.

=item 'client_connected' ($client_filehandle)

Called when a new client connects, handler should handle
the joyfull event, (print a banner, log connection).

B<RETURN VALUE>: Return true if we keep the connection, false to drop it.

=item 'client_disconnected' ($client_filehandle)

Called (by the B<IO::Multiplex::disconnect> method) when a client disconnects.

=back

=head1 AUTHOR

Liraz Siri <liraz_siri@usa.net>, Ariel, Israel.

=head1 COPYRIGHT

Copyright 1999 (c) Liraz Siri <liraz_siri@usa.net>, Ariel, Israel,
                   All rights reserved.

=cut    

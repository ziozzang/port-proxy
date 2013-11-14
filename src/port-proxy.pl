#!/usr/bin/perl
##############################################################################
#
# Port-Proxy, V 0.95 (C) 2004 Accordata GmbH,  Ralf Amandi
# Port-Proxy is Perl script to forward ports from the local system to another system.
# Ralf.Amandi@accordata.net
#
# patched by ziozzang
#  - fixed for network disconnect testing
#    (Freezing session which looks like network cable is disconnected)
##############################################################################
use strict;
use IO::Socket;
use IO::Select;
use Getopt::Std;
use POSIX 'setsid';
#use Win32::Daemon;

#---- Configuration
my $configFile= './port-proxy.conf';
my $Version="0.95-p1";
my $debug=0; #0,1,2
my $detach=0; # detach (unix only)

#-- options --
my %opts;
getopt('d:c:D',\%opts);
if (exists $opts{'d'}) { $debug=1; }
if (exists $opts{'c'}) { $configFile=$opts{'c'}; }
if (exists $opts{'D'}) { $detach=1; }

#---- Global Vars ---
my @allow_proxy_to=();
my $sock_list = new IO::Select(); # A list of sockets for the "select" function
my $socknr=0; # Counts socket
my %sock_params=();
my $lastsig;
# For each socket this hash contains an hash reference with socket parameters
# Params: type, remote_addr, proxy_addr, corresponding_sock, state

my $spin_lock = 0;

Main();
exit 0;

#---- Main  ----
# Read Config
# Check known sockets for aktion and handles Read/Connect requests
sub Main
{
    my (@ready,@canwrite,@haserror,$sock,$type,$state, $param,$val,$buff,$bufflen,$ok);

    #---- Banner ----
    print "Accordata GmbH - Port-Proxy V $Version\n";
    print "----------------------------------\n\n";

    #---- Setup Listen Ports; read config file ----
    ReadConfig();
    print "\n";

    $SIG{'HUP'}=\&sigHandler;	# ReRead Config File
    $SIG{'TERM'}=\&sigHandler;
    $SIG{'KILL'}=\&sigHandler;
    $SIG{'INT'}=\&sigHandler;

    if ($detach) { daemonize(); }

    #---- Listen loop ----
    while(1) {
	while($lastsig eq '') {
	if ($spin_lock eq 1) {
                select(undef, undef, undef, 0.001);
                #print "spin lock status\n";
                next;
        }

	    #-- write? (not used) --
#	    @canwrite = $sock_list->can_write(1);
#	    foreach $sock (@canwrite) {
#		$param=$sock_params{$sock};
#		if ($param->{'type'} ne 'L') { print "W ".$param->{'type'}." $sock\n"; 	}
#	    }
	    #-- read --
	    @ready = $sock_list->can_read(0.25);
	    foreach $sock (@ready) {
		$param=$sock_params{$sock};
		$type=$param->{'type'};
		$state=$param->{'state'};
		if ($debug) { print "R $type ".$param->{'id'}." $state $sock\n"; }
		if ($type eq 'L') {	# Listen Socket
		    NewConnect($sock);
		} elsif ($state eq 'forward') { # Forward Data; used for type C,D,P
		    $bufflen=sysread($sock,$buff,4096);
		    if ($debug>=2) { print "[".length($buff)."]$buff\n"; }
		    if ($bufflen==0) {
			CloseSocket($sock);
		    } else {
			my $l=syswrite($param->{'corresponding_sock'},$buff);
			if ($l != $bufflen) { die "can't write all data\n"; }
		    }
		} else { # Read from socket an check Data
		    $bufflen=sysread($sock,$buff,4096);
		    if ($debug>=2) { print "[".length($buff)."]$buff\n"; }
		    if ($bufflen==0) {
			CloseSocket($sock);
			next;
		    }
		    $ok=0; $val=$buff;
		    # We asume, that all we need is in one read. This is a little bit dirty, but works for now.
		    if ($state eq 'readDestAddr') { # Except CONNECT xx.xx.xx.xx:yy..[CR/LF][CR/LF]
			if ($buff =~ /^CONNECT\s+(.+?)\r?\n\r?\n(.*)$/s) { # read to first cr/lf
			    $val=$1; $buff=$2; $val=~s/\s.*//g;
			    print "PROXY CONNECT TO: $val\n";
			    if (! check_dest_allowed($val) ) {
				syswrite($sock,"403 FORBIDDEN\n\n");
			    } elsif (remote_connect($sock,$val,1)) {
				syswrite($sock,"HTTP/1.0 200 OK\n\n");
				$ok=1; $state='forward';
			    }
			}
		    } elsif ($state  eq 'readProxyResponse') {
			if ($buff =~ /^(.*?)\r?\n\r?\n(.*)$/s) { # read to double cr/lf
			    $val=$1; $buff=$2;
			    if ($val =~ / 200 /) {
				$ok=1;
				if ($param->{'remote_addr'} ne '') { # now send the address to the 2nd proxy
				    syswrite($sock,"CONNECT ".$param->{'remote_addr'}." HTTP/1.0\n\n");
				    $param->{'remote_addr'}='';
				} else {
				    $state='forward';
				}
			    }
			}
		    }
		    if ($ok) {
			$param->{'state'}=$state; # set new state
			if (length($buff)>0) { syswrite($param->{'corresponding_sock'},$buff); } # forward rest of data
		    } else {
			print "ERR: $val\n";
			CloseSocket($sock);
		    }
		}
	    }
	    #-- errors? --
#	    @haserror = $sock_list->has_exception(0); # has_exception not supported on older perl version
#	    foreach $sock (@haserror) {
#		CloseSocket($sock);
#	    }
	}
	#-- Check sig --
	if ($lastsig eq 'HUP') {
	    print "Caught a SIG$lastsig\, restart\n";
	    foreach $sock ($sock_list->handles()) {
		if ($sock_params{$sock}->{'type'} eq 'L') { CloseSocket($sock); } # CLose listening socket
	    }
	    ReadConfig();
	    # On my Linux I detected problems, since the ports seems to be blocked after closing
	} else {
	    print "Caught a SIG$lastsig\, shutting down\n";
	    foreach $sock ($sock_list->handles()) {
		CloseSocket($sock);
	    }
	    exit(0);
	}
	$lastsig='';
    }
}

sub ReadConfig()
{
    my ($val, $line,@aval,$param);	
    @allow_proxy_to=();
    open(F,"<$configFile") || die "can't open file $configFile\n";
    while(<F>) {
	$line=$_;
	$line=~s/#.*$//g; # remove comments
	if ($debug) { print "Conf>$line"; }
	if ( $line=~/^\s*(.+?)=(.*?)\s*$/) {
	    $param=$1; $val=$2;
	    if ($param eq 'forward') {
		@aval=split(/ *, */,$val);
		CreateListenSock($aval[0],$aval[1],$aval[2],$aval[3]);
	    } elsif($param eq 'allow_proxy_to') {
		push(@allow_proxy_to,$val)
	    }
	}
    }
    close(F);
}

#---
# Handle some (unix) signals; HUP: restart with reading config; TERM/KILL: shut down
sub sigHandler($) # sigHandler(signame)
{
    my($sig) = @_;
    my ($sock,$param);
    if ($sig eq 'KILL') {
	die "Caught a SIG$sig, stop immediatly\n";
    } elsif ($sig eq 'INT') {
	#print "Caught a SIGINT. sleep 1000sec & die";
	#sleep (10000);
	#die "Sleep 1000sec done. die.";
	# -- (ziozzang) patched. for disconnect testing.
	print "Toggle SpinLock statement";
	if ($spin_lock eq 0){
		print " - On\n";
		$spin_lock = 1;
	}
	else {
		print " - Off\n";
		$spin_lock = 0;
	}
    } elsif ($sig eq $lastsig && $sig ne 'HUP') {
	die "Caught a SIG$$sig twice, stop immediatly\n";
    } else {
	$lastsig=$sig;
    }
}
##############################################################################
# Socket Funktion 
##############################################################################
# Add a open socket to our structures ($sock_list,$sock_params); gives back params hash
sub AddSockList($$) # AddSockList($sock,$type):paramHashRef
{
    my ($sock,$type)=@_;
    my %params=('type',$type,'id',++$socknr);
    $sock_params{$sock}=\%params;
    $sock_list->add($sock);
    return \%params
}

#---
# Creates an Socket for listening and add it with all needed params to our structures
sub CreateListenSock ($$$) # CreateListeSock($local_addr,$remote_addr,$proxy_addr) :paramHashRef
{
    my($local_addr,$remote_addr,$proxy_addr,$proxy2_addr)=@_;
    my ($new_sock,$param);
    if ($local_addr =~ /:/) {
	$new_sock=new IO::Socket::INET(Listen => 5, LocalAddr => $local_addr, Proto => 'tcp');
    } else {
	$new_sock=new IO::Socket::INET(Listen => 5, LocalPort => $local_addr, Proto => 'tcp');
    }
    if (!$new_sock) { die "Error listening on port $local_addr\n"; }
    $param=AddSockList($new_sock,'L');
    $param->{'remote_addr'}=$remote_addr; # host:port
    $param->{'proxy_addr'}=$proxy_addr; # host:port
    $param->{'proxy2_addr'}=$proxy2_addr; # host:port
    if ($proxy2_addr ne '') {
	print "Listen on $local_addr; forward via $proxy_addr via $proxy2_addr to $remote_addr\n";
    } elsif ($proxy_addr ne '') {
	print "Listen on $local_addr; forward via proxy $proxy_addr to $remote_addr\n";
    } else {
	print "Listen on $local_addr; forward to $remote_addr\n";
    }
    return $param;
}

#---
# Close this and any corresponding socket; remove from sock_list and sock_params
sub CloseSocket($) # CloseSocket($sock):bool;
{
    my ($sock)=@_;
    if (! $sock) { return; }
    #-- Remove from sock_params and sock_list--
    my $param=$sock_params{$sock};
    if (! $param) { return; } # already closed
    if ($param->{'type'} eq 'C') {
	print "Closing connection from ".$sock->peerhost().':'.$sock->peerport().' to '.$sock->sockhost ().':'.$sock->sockport()."\n";
    }
    $sock_params{$sock}=undef;
    $sock_list->remove($sock);
    $sock->close();
    if ($debug) { print " close ".$param->{'type'}.' '.$param->{'id'}." $sock\n"; }
    #-- Close corresponding sockets --
    CloseSocket($param->{'corresponding_sock'});
    return 1;
}

#---
# Start an new connection established on ListenSock
sub NewConnect($) # NewConnect($ListenSock): Start an new Connection
{
    my ($listen_sock)=@_;
    my ($sock,$param);
    if (! $listen_sock) { return; }
    my $listen_param=$sock_params{$listen_sock};

    #-- Create New Socket; copy params --
    $sock=$listen_sock->accept;
    $param=AddSockList($sock,'C');
    $param->{'proxy_addr'}=$listen_param->{'proxy_addr'};
    $param->{'proxy2_addr'}=$listen_param->{'proxy2_addr'};
    print "New connection from ".$sock->peerhost().':'.$sock->peerport().' to '.$sock->sockhost ().':'.$sock->sockport()."\n";

    #-- Connect to remote --
    if ($listen_param->{'remote_addr'} eq '[PROXY]') { # Read destination from sock (act as proxy)
	$param->{'state'}='readDestAddr';
	return 1;
    } elsif (remote_connect($sock,$listen_param->{'remote_addr'},0)) { # Connect direct or via proxy
	$param->{'state'}='forward';
	print "  established\n";
	return 1;
    } else {
	CloseSocket($sock);
	print "  aborted\n";
	return undef;
    }
}

#---
# Check if we proxy to the given address (The Address is send by the client if the Config Entry is [PROXY])
sub check_dest_allowed($)
{
    my ($addr)=@_;	
    my ($cmp);
    foreach $cmp (@allow_proxy_to) {
	if ($addr =~/^$cmp$/) {
		return 1;
	}
    }
    return 0;
}
#---
# connect directly to remote or via proxy; Called after connect (with CheckAddr=0) or after the client sends the destination (checkaddr=1)
sub remote_connect($$$) # (src_sock,addr,checkaddr):bool
{
    my ($src_sock,$addr,$checkaddr)=@_;
    my $src_param=$sock_params{$src_sock};
    my ($corresponding_sock,$corresponding_param);
    if ($src_param->{'proxy2_addr'} ne '') {
	($corresponding_sock,$corresponding_param)=dest_connect($src_param->{'proxy_addr'},'P',$src_sock);
	if ($corresponding_sock) {
	    syswrite($corresponding_sock,"CONNECT ".$src_param->{'proxy2_addr'}." HTTP/1.0\n\n");
	    $corresponding_param->{'state'}='readProxyResponse';
	    $corresponding_param->{'remote_addr'}=$addr;
	}
    } elsif ($src_param->{'proxy_addr'} ne '') {
	($corresponding_sock,$corresponding_param)=dest_connect($src_param->{'proxy_addr'},'P',$src_sock);
	if ($corresponding_sock) {
	    print "  proxy connection established ask for connection to $addr\n";
	    syswrite($corresponding_sock,"CONNECT $addr HTTP/1.0\n\n");
	    $corresponding_param->{'state'}='readProxyResponse';
	}
    } else { #-- direct connection --
	($corresponding_sock,$corresponding_param)=dest_connect($addr,'D',$src_sock);
	$corresponding_param->{'state'}='forward';
    }
    #-- Return ok/nok
    return ($corresponding_sock != undef);
}
#---
# Connect to Destination or Proxy; Add Sock to our known socks with $type;
# Set Link Param (corresponding_sock) for  Destionation an Source socket
sub dest_connect($$$) # dest_connect($addr,$type,$src_sock) returns ($sock,$params)
{
    my ($addr,$type,$src_sock)=@_;
    my $sock=IO::Socket::INET->new(PeerAddr=>$addr,proto=>'tcp');
    if (! $sock) { return undef; }
    my $param=AddSockList($sock,$type); # 'P'=Proxy', 'D'=Dest
    if ($src_sock) {
	$param->{'corresponding_sock'}=$src_sock;
	$sock_params{$src_sock}->{'corresponding_sock'}=$sock;
    }
    return ($sock,$param)
}

##############################################################################
# other funtions
##############################################################################

# Detach as daemon (function copied from perl doc)
sub daemonize {
#        chdir '/'               or die "Can't chdir to /: $!";
	open STDIN, '/dev/null' or die "Can't read /dev/null: $!";
	open STDOUT, '>/dev/null' or die "Can't write to /dev/null: $!";
	defined(my $pid = fork) or die "Can't fork: $!";
	exit if $pid;
        setsid                  or die "Can't start a new session: $!";
        open STDERR, '>&STDOUT' or die "Can't dup stdout: $!";
}


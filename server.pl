#!/usr/bin/env perl

# Copyright (c) 2013 Sean Malloy. All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
#    - Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    - Redistributions in binary form must reproduce the above
#      copyright notice, this list of conditions and the following
#      disclaimer in the documentation and/or other materials provided
#      with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
# FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# ABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use English qw( -no_match_vars );
use IO::Socket;
use NetFlow::Parser;
use Getopt::Long;
use SPM::Daemon qw( init_server_user log_die log_notice log_warn );
use DBI;
use Config::Simple;
use Pod::Usage;

# Signal Handlers
$SIG{'INT'}  = 'exit_handler';
$SIG{'TERM'} = 'exit_handler';

# TODO: Add to command line options
# --listen-address
# --log-level

my ($Config_File, $Database_File, $Group, $Help, $Man_Page, $Pid_File, $Port, $User);
if (!GetOptions('config-file=s' => \$Config_File,
                'database=s'    => \$Database_File,
                'group=s'       => \$Group,
                'help'          => \$Help,
                'manpage'       => \$Man_Page,
                'pid-file=s'    => \$Pid_File,
                'port=i'        => \$Port,
                'user=s'        => \$User, )) {
    pod2usage(-exitval => 1,
              -verbose => 1, 
    );
}

if ($Help) {
    pod2usage(-exitval => 0,
              -verbose => 1,
    );
}

if ($Man_Page) {
    pod2usage(-exitval => 0,
              -verbose => 2,
    );
}

# TODO: handle this better? different error message?
if (!defined $Config_File) {
    my $error_message = "--config-file option missing";
    pod2usage(-exitval => 1,
              -msg     => $error_message,
              -verbose => 1,
    );
}

# Parse Config File
# TODO: Add to config file
# --listen-address
# --log-level
my $Config = new Config::Simple($Config_File);

if (!defined $Database_File) {
    $Database_File = $Config->param('database.file');
}

if (!defined $User) {
    $User = $Config->param('general.user');
}
if (!defined $Group) {
    $Group = $Config->param('general.group');
}

if (!defined $Pid_File) {
    $Pid_File = $Config->param('general.pid-file');
}

if (!defined $Port) {
    $Port = $Config->param('network.port');
}

# Set Defaults
if (!defined $Port) {
    $Port = 1234;
}
if (!defined $Pid_File) {
    $Pid_File = '/var/run/server.pid';
} 

init_server_user($Pid_File, $User, $Group);

my $Database_Handle = create_database($Database_File);
my $Exit = 0;

my ($Maximum_Length, $Data);
# Maximum packet size for Netflow v5.
# 24 + (30 * 48) = 1464 bytes
# Header: 24 bytes
# Each Flow: 48 bytes (can be 1 to 30 flows per packet)
my $parser = NetFlow::Parser->new();
$Maximum_Length = 1464;
my $Packet;

my $Header_Statement_Handle = $Database_Handle->prepare("INSERT INTO headers(version, count, system_uptime, unix_seconds, unix_nano_seconds, flow_sequence, engine_type, engine_id, sampling_mode, sampling_interval) VALUES (?,?,?,?,?,?,?,?,?,?)");
my $Flow_Statement_Handle   = $Database_Handle->prepare("INSERT INTO flows(source_ip_address, destination_ip_address, next_hop_ip_address, snmp_input_index, snmp_output_index, packets, bytes, start_system_uptime, end_system_uptime, source_port, destination_port, tcp_flags, ip_protocol, type_of_service, source_system_number, destination_system_number, source_mask, destination_mask, header_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");

my $Header_Primary_Key;
my $Sock;
MAIN:
while (!$Exit) {
    if (!defined $Sock) {
        $Sock = new IO::Socket::INET( LocalPort => $Port, Proto => 'udp' )
            or die "socket: $EVAL_ERROR";
        log_notice("listening on port $Port", "\n");
    }

    
    if (!$Sock->recv($Data, $Maximum_Length)) {
        $Sock->close();
        undef $Sock;
        log_warn("UDP packet receive error: $OS_ERROR", "\n");
        next MAIN;
    }

    my ($port, $ip) = sockaddr_in($Sock->peername);
    my $client = gethostbyaddr($ip, AF_INET);
    $Packet = $parser->parse($Data);
    log_notice("inserting into headers table", "\n");
    $Header_Statement_Handle->execute( $Packet->version(), $Packet->count(), $Packet->sys_uptime(), $Packet->unix_secs(), $Packet->unix_nsecs(), $Packet->flow_sequence(), $Packet->engine_type(), $Packet->engine_id, $Packet->sampling_mode, $Packet->sampling_interval() );
    $Header_Primary_Key = $Database_Handle->last_insert_id("", "", "", "");
    for my $flow (@{$Packet->flows()}) {
        log_notice("inserting into flows table", "\n");
        $Flow_Statement_Handle->execute( $flow->srcaddr(), $flow->dstaddr(), $flow->nexthop(), $flow->input(), $flow->output(), $flow->packets(), $flow->bytes(), $flow->first(), $flow->last(), $flow->srcport(), $flow->dstport(), $flow->tcpflags(), $flow->protocol(), $flow->tos(), $flow->srcas(), $flow->dstas(), $flow->srcmask(), $flow->dstmask(), $Header_Primary_Key );
    }
}
clean_up();
exit 0;

sub clean_up {
    log_notice("disconnecting from database $Database_File", "\n");
    $Database_Handle->disconnect;
}

# TODO: document this function
# Returns: DBI database handle
sub create_database {
    my $database_file = shift;
    if (!defined $database_file) {
        log_die("cannot connect to database: missing database connection informtion");
    }

    if (-f $database_file) {
        my $database_handle = DBI->connect("dbi:SQLite:dbname=$database_file", "", "", { AutoCommit => 1, RaiseError => 1 } );
        if (!defined $database_handle) {
            log_die("cannot connect to database $database_file: $DBI::errstr");
        }

        # Exit if headers table does not exist.
        if (scalar($database_handle->tables(undef, undef, 'headers', 'TABLE')) != 1) {
            log_die("missing table 'headers' in database $database_file");
        }

        # Exit if flows table does not exist.
        if (scalar($database_handle->tables(undef, undef, 'flows' , 'TABLE')) != 1) {
            log_die("missing table 'flows' in database $database_file");
        }

        # Exit if view does not exist.
        if (scalar($database_handle->tables(undef, undef, 'headers_localtime' , 'VIEW')) != 1) {
            log_die("missing view 'headers_localtime' in database $database_file");
        }

        return $database_handle;
    }

    # Create Database Tables
    my $database_handle = DBI->connect("dbi:SQLite:dbname=$database_file", "", "", { AutoCommit => 1, RaiseError => 1 } );

    my $create_headers_table_sql = <<'END_SQL';
    -- Table for Netflow headers
    CREATE TABLE IF NOT EXISTS headers (
        header_id          INTEGER NOT NULL  PRIMARY KEY, -- Surrogate key
        version            INTEGER NOT NULL,              -- Netflow version number
        count              INTEGER NOT NULL,              -- Flows associated with header
        system_uptime      INTEGER NOT NULL,              -- Milliseconds since the flow export device booted
        unix_seconds       INTEGER NOT NULL,              -- Seconds since 0000 UTC 1970
        unix_nano_seconds  INTEGER NOT NULL,              -- Residual nanoseconds since 0000 UTC 1970
        flow_sequence      INTEGER NOT NULL,              -- Sequence counter of total flows seen
        engine_type        INTEGER NOT NULL,              -- Type of flow-switching engine
        engine_id          INTEGER NOT NULL,              -- Slot number of the flow-switching engine
        sampling_mode      INTEGER NOT NULL,              -- Sampling mode
        sampling_interval  INTEGER NOT NULL               -- Sampling interval
    )
END_SQL
    $database_handle->do($create_headers_table_sql);

    my $create_flows_table_sql = <<'END_SQL';
    -- Table for Netfow flows
    CREATE TABLE IF NOT EXISTS flows (
        flow_id                   INTEGER  NOT NULL  PRIMARY KEY,       -- Surrogate key
        source_ip_address         TEXT     NOT NULL,                    -- Source IP address
        destination_ip_address    TEXT     NOT NULL,                    -- Destination IP address
        next_hop_ip_address       TEXT     NOT NULL,                    -- IP address of next hop router
        snmp_input_index          INTEGER  NOT NULL,                    -- SNMP index of input interface
        snmp_output_index         INTEGER  NOT NULL,                    -- SNMP index of output interface
        packets                   INTEGER  NOT NULL,                    -- Packets in the flow
        bytes                     INTEGER  NOT NULL,                    -- Total number of Layer 3 bytes in the packets of the flow
        start_system_uptime       INTEGER  NOT NULL,                    -- System uptime at start of flow
        end_system_uptime         INTEGER  NOT NULL,                    -- System uptime at the time the last packet of the flow was receive
        source_port               INTEGER  NOT NULL,                    -- TCP/UDP source port number
        destination_port          INTEGER  NOT NULL,                    -- TCP/UDP destination port number
        tcp_flags                 INTEGER  NOT NULL,                    -- Cumulative OR of TCP flags
        ip_protocol               INTEGER  NOT NULL,                    -- IP protocol type (for example, TCP = 6; UDP = 17)
        type_of_service           INTEGER  NOT NULL,                    -- IP type of service (ToS)
        source_system_number      INTEGER  NOT NULL,                    -- Autonomous system number of the source, either origin or peer
        destination_system_number INTEGER  NOT NULL,                    -- Autonomous system number of the destination, either origin or pee
        source_mask               INTEGER  NOT NULL,                    -- Source address prefix mask bits
        destination_mask          INTEGER  NOT NULL,                    -- Destination address prefix mask bits
        header_id                 INTEGER  NOT NULL  REFERENCES headers -- Setup one to many relationship between flows and headers
    )
END_SQL
    $database_handle->do($create_flows_table_sql);

    # Create Database Views
    my $create_local_time_view_sql = <<'END_SQL';
    -- View for local time zone
    CREATE VIEW IF NOT EXISTS headers_localtime AS
    SELECT header_id,
           version,
           count,
           system_uptime,
           datetime(unix_seconds, 'unixepoch', 'localtime'),
           unix_nano_seconds,
           flow_sequence,
           engine_type,
           engine_id,
           sampling_mode,
           sampling_interval
    FROM headers
END_SQL
    $database_handle->do($create_local_time_view_sql);
    return $database_handle;
}

sub exit_handler {
    $Exit = 1;
}

__END__
=head1 NAME

server.pl - Netflow Collector Daemon

=head1 SYNOPSIS

    server.pl --config-file <FILE> [--database <DB>] [--group <GROUP>] [--pid-file <FILE>] [--port <PORT>] [--user <USER>]
    server.pl --help
    server.pl --manpage

=head1 DESCRIPTION

Netflow collector daemon. Only supports Netflow v5.

=head1 OPTIONS

=over

=item --config-file I<FILE>

Path to configuration file. This option is required.

=item --database I<DB>

Path to SQLite database file.

=item --group I<GROUP>

UNIX group to run as.

=item --help

Display help and exit.

=item --manpage

Display entire manual and exit.

=item --pid-file I<FILE>

Path to the PID file. Default is /var/run/server.pid.

=item --port I<PORT>

UDP port daemon listens on for Netflow data. Default is 1234.

=item --user I<USER>

Unix group to run as.

=back

=head1 CONFIGURATION AND ENVIRONMENT

Update with configuration file information
and/or environment variable information.

=head1 EXAMPLE USAGE

Document example usage here.

    ./template.pl --foo

=head1 BUGS AND LIMITATIONS

No known bugs at this time.

=head1 SEE ALSO

Netflow Export Datagram Format
    http://www.cisco.com/en/US/docs/net_mgmt/netflow_collection_engine/3.6/user/guide/format.html

=head1 AUTHOR

Sean Malloy, E<lt>spinelli85@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2013 Sean Malloy. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

   - Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.
   - Redistributions in binary form must reproduce the above
     copyright notice, this list of conditions and the following
     disclaimer in the documentation and/or other materials provided
     with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
ABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

=cut


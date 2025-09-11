#!/usr/bin/perl
use v5.36;
# ZChat/ParentID.pm
package ZChat::ParentID;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(get_parent_id get_parent_id_windows get_parent_id_linux);

# ---------- Public API ----------

sub get_parent_id {
    return ($^O eq 'MSWin32') ? get_parent_id_windows() : get_parent_id_linux();
}

# ---------- Linux / Unix (Linux-only as requested for /proc) ----------

sub get_parent_id_linux {
    my $ppid = getppid();

    my $stat = _read_proc_stat($ppid)
        or return "pp${ppid}.pp${ppid}"; # parent gone; short, but deterministic per call

    my $sid = $stat->{session};          # Linux session ID
    # On Linux, the session leader's PID == SID
    return "$sid.$sid";
}

# ---------- Windows ----------

sub get_parent_id_windows {
    my $ppid = getppid();

    # 1) Prefer the console window handle (stable per console)
    my $hwnd = eval {
        require Win32::API;
        my $GetConsoleWindow = Win32::API->new('kernel32', 'HWND GetConsoleWindow()')
            or die "no GetConsoleWindow";
        $GetConsoleWindow->Call() || 0;
    };
    if ($hwnd) {
        # Keep it short: hex without leading 0x, paired with parent pid
        my $h = sprintf("%x", $hwnd);
        return "$h.$ppid";
    }

    # 2) Try Windows session ID (WTS Terminal Session), paired with parent pid
    my $sess_ok = 0;
    my $sess_id = eval {
        require Win32::API;
        my $ProcessIdToSessionId = Win32::API->new('kernel32',
            'BOOL ProcessIdToSessionId(DWORD, LPDWORD)') or die "no PIdToSessId";
        my $buf = pack('L', 0);
        if ($ProcessIdToSessionId->Call($ppid, $buf)) {
            $sess_ok = 1;
            unpack('L', $buf);
        } else {
            0;
        }
    };
    if ($sess_ok) {
        return "$sess_id.$ppid";
    }

    # 3) Fallback: parent PID + creation time (low dword), both short
    my $fallback = eval {
        require Win32::API;
        my $OpenProcess = Win32::API->new('kernel32',
            'HANDLE OpenProcess(DWORD, BOOL, DWORD)') or die "OpenProcess";
        my $GetProcessTimes = Win32::API->new('kernel32',
            'BOOL GetProcessTimes(HANDLE, PVOID, PVOID, PVOID, PVOID)') or die "GetProcessTimes";
        my $CloseHandle = Win32::API->new('kernel32', 'BOOL CloseHandle(HANDLE)');

        my $PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        my $PROCESS_QUERY_INFORMATION         = 0x0400;
        my $access = $PROCESS_QUERY_LIMITED_INFORMATION | $PROCESS_QUERY_INFORMATION;

        my $h = $OpenProcess->Call($access, 0, $ppid) or die "OpenProcess failed";
        my $buf = pack('Q<4', (0) x 4);
        $GetProcessTimes->Call($h, $buf, undef, undef, undef);
        $CloseHandle->Call($h);

        my ($creation_low) = unpack('V', $buf);      # low 32 bits
        my $c = sprintf("%x", $creation_low);        # hex keeps it compact
        "$ppid.$c"
    };
    return $fallback if $fallback;

    # 4) Last resort: just the parent pid twice (still "sid.sid_leader_pid" shape)
    return "$ppid.$ppid";
}

# ---------- Helpers (Linux) ----------

sub _read_proc_stat {
    my ($pid) = @_;
    open my $fh, "<", "/proc/$pid/stat" or return;
    my $line = <$fh>;
    close $fh;

    # Format: pid (comm) state ppid pgrp session ...
    my ($pid1, $comm, $state, $rest) = $line =~ /^\s*(\d+)\s+\((.*?)\)\s+(\S)\s+(.*)$/s
        or return;

    my @a = split ' ', $rest;
    # indices after state: [0]=ppid [1]=pgrp [2]=session ...
    my $session = $a[2];  # field 6 overall

    return {
        pid     => $pid1,
        comm    => $comm,
        state   => $state,
        session => $session,
    };
}

# say get_parent_id();

1;

__END__

=pod

=head1 NAME

ZChat::ParentID - Small, stable parent-shell identifier across platforms

=head1 SYNOPSIS

  use ZChat::ParentID qw(get_parent_id);
  my $id = get_parent_id();     # "sid.sid_leader_pid"-style, compact

=head1 DESCRIPTION

Linux: reads /proc to obtain the parent process's session ID (SID). The session
leader's PID equals SID, so the identifier is "SID.SID".

Windows: prefers the console window handle (hex) paired with parent PID; else
falls back to Windows SessionId + parent PID; else parent PID + creation time
(low dword, hex). All forms are short and suitable for filenames.

=head1 FUNCTIONS

=over 4

=item get_parent_id()

Returns a compact identifier string for the current process's parent shell/session.

=item get_parent_id_linux()

Linux-only implementation using /proc.

=item get_parent_id_windows()

Windows implementation using Win32 APIs.

=back

=cut


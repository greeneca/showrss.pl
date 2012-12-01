#!/usr/bin/perl
# vim: set expandtab ts=4 sw=4

use strict;
use XML::Simple;
use LWP::Simple;
use URI::Escape;
use Date::Parse;
use POSIX qw(strftime);
use YAML qw(LoadFile DumpFile);

my $DATA_DIR    = $ENV{HOME} . '/.showrss/';
my $CONFIG_FILE = $DATA_DIR . 'config.yml';
my $FEED_FILE   = $DATA_DIR . 'feed.xml';
my $LOGFILE     = $DATA_DIR . 'log';
my $PIDFILE     = '/var/run/showrss.pid';
my $CONFIG;

main:
{
    if ($#ARGV > -1)
    {
        if ($ARGV[0] eq "-c")
        {
            config_mode();
            exit 0;
        }
        if ($ARGV[0] eq "-l")
        {
            print "Log path: " . $LOGFILE . "\n";
            exit 0;
        }
    }
    else
    {
        load_config();
        start_daemon();
    }
}

sub config_mode
{
    # Start from a blank slate..
    $CONFIG = undef;

    print "Enter full RSS feed URL: ";
    $CONFIG->{'RSS_URL'} = <STDIN>;
    chomp($CONFIG->{'RSS_URL'});

    print "Enter torrent download dir (full path): ";
    $CONFIG->{'DOWNLOAD_DIR'} = <STDIN>;
    # Lop off trailing slashes unless we're in the root
    $CONFIG->{'DOWNLOAD_DIR'} =~ s/([^\/]+)[\/]*$/$1/;
    chomp($CONFIG->{'DOWNLOAD_DIR'});

    print "Would you like to download all torrents in feed? If no, only torrents released from now will be downloaded. Y/N: ";
    my $answer = <STDIN>;
    if ($answer =~ /[Yy].*/) { $CONFIG->{'LASTUPDATED'} = 0; } else { $CONFIG->{'LASTUPDATED'} = time(); }

    while ($CONFIG->{'DAEMONINTERVAL'} < 1)
    {
        print "Refresh interval in hours: ";
        $CONFIG->{'DAEMONINTERVAL'} = <STDIN>;
        chomp($CONFIG->{'DAEMONINTERVAL'});
    }

    save_config();
}

sub load_config
{
    eval
    {
        $CONFIG = LoadFile($CONFIG_FILE);
    };
    
    if ($@ || ! defined $CONFIG->{'RSS_URL'} || ! defined $CONFIG->{'DOWNLOAD_DIR'} || ! defined $CONFIG->{'LASTUPDATED'} || ! defined $CONFIG->{'DAEMONINTERVAL'})
    {
        print "Not properly configured! Please run with -c switch to configure\n";
        exit 1;
    }
}

sub save_config
{
	eval
	{
        # Make data dir if it doesn't exist
        if (! -d $DATA_DIR)
		{
			mkdir($DATA_DIR);
		}
	
		DumpFile($CONFIG_FILE, $CONFIG);
	};

	# Unable to write to user's home dir.
	if ($@)
	{
		print "Unable to write to $DATA_DIR, please create this directory if it does not exist and ensure permissions allow writing\n";
		exit 1;
	}
}

sub start_daemon
{
    my $pid = fork();

    if (! defined $pid) 
    {
        print "Failed to fork!\n";
        exit 1;
    } 
    elsif ($pid == 0) 
    {
        close(STDIN);
        close(STDOUT);
        close(STDERR);

        while (1)
        {
            open(LOGFILE, '>>', $LOGFILE);
            print LOGFILE '[' .  strftime("%d/%m/%Y %H:%M:%S", localtime) . '] ' . download_latest_torrents() . "\n";
            close(LOGFILE);

            sleep($CONFIG->{'DAEMONINTERVAL'} * 60 * 60);
        }
    }
    else 
    {
        open(PIDFILE, '>', $PIDFILE) or die $!;
        print PIDFILE $pid;
        close(PIDFILE) or die $!;
        print "Forked. PID: $pid\n";
        exit 0;
    }
}

sub download_latest_torrents
{
    my $xml = new XML::Simple;

    # Download feed 
    my $status = mirror($CONFIG->{'RSS_URL'}, $FEED_FILE);
    if ($status != 200) { return "Unable to download feed. Status code: " . status_message($status); }

    # Parse feed
    my $data = $xml->XMLin($FEED_FILE);
    if (! $data) { return "Unable to parse XML feed"; }

    # Stats
    my ($downloaded_torrents, $skipped_torrents, $failed_torrents) = (0, 0, 0);

    # For each item, download the torrent file, if we haven't already
    foreach my $item (@{$data->{channel}->{item}})
    {
        # Get download URL and filename
        my $url = uri_unescape($item->{link});
        $url =~ /\/([^\/]+)\.[^\/\$]+$/;
        my $filename = $1; 

        # Decide whether to download or skip based on pubDate
        my $pubDate = str2time($item->{pubDate});
        if ($pubDate <= $CONFIG->{'LASTUPDATED'}) { $skipped_torrents++; next; }
    
        # Download .torrent file
        my $status = getstore($url, $CONFIG->{'DOWNLOAD_DIR'} . "/" . $filename . ".torrent");
    
        if ($status == 200) { $downloaded_torrents++; }
        else { $failed_torrents++; }
    }

    $CONFIG->{'LASTUPDATED'} = time();
    save_config();

    return "Downloaded: $downloaded_torrents, Skipped: $skipped_torrents, Failed: $failed_torrents"
}

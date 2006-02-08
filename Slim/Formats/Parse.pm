package Slim::Formats::Parse;

# $Id$

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use File::Spec::Functions qw(:ALL);
use FileHandle;
use IO::Socket qw(:crlf);
use IO::String;
use Scalar::Util qw(blessed);
use XML::Simple;
use URI::Escape;

use Slim::Player::ProtocolHandlers;
use Slim::Music::Info;
use Slim::Utils::Misc;
use Slim::Utils::Unicode;

our %playlistInfo = ( 
	'm3u' => [\&readM3U, \&writeM3U, '.m3u'],
	'pls' => [\&readPLS, \&writePLS, '.pls'],
	'cue' => [\&readCUE, undef, undef],
	'wpl' => [\&readWPL, \&writeWPL, '.wpl'],
	'asx' => [\&readASX, undef, '.asx'],
	'wax' => [\&readASX, undef, '.wax'],
	'xml' => [\&readPodcast, undef, undef],
	'pod' => [\&readPodcast, undef, undef],
);

sub registerParser {
	my ($type, $readfunc, $writefunc, $suffix) = @_;

	$::d_parse && msg("Registering external parser for type $type\n");

	$playlistInfo{$type} = [$readfunc, $writefunc, $suffix];
}

sub parseList {
	my $list = shift;
	my $file = shift;
	my $base = shift;

	# Allow the caller to pass a content type
	my $type = shift || Slim::Music::Info::contentType($list);

	# We want the real type from a internal playlist.
	if ($type eq 'ssp') {
		$type = Slim::Music::Info::typeFromSuffix($list);
	}

	$::d_parse && msg("parseList (type: $type): $list\n");

	my $parser;
	my @items = ();

	if (exists $playlistInfo{$type} && ($parser = $playlistInfo{$type}->[0])) {
		return &$parser($file, $base, $list);
	}
}

sub writeList {
	my $listref = shift;
	my $playlistname = shift;
	my $fulldir = shift;
		
	my $type = Slim::Music::Info::typeFromSuffix($fulldir);
	my $writer;

	if (exists $playlistInfo{$type} && ($writer = $playlistInfo{$type}->[1])) {
		return &$writer($listref, $playlistname, Slim::Utils::Misc::pathFromFileURL($fulldir), 1);
	}
}

sub getPlaylistSuffix {
	my $filepath = shift;

	my $type = Slim::Music::Info::contentType($filepath);

	if (exists $playlistInfo{$type}) {
		return $playlistInfo{$type}->[2];
	}

	return undef;
}

sub _updateMetaData {
	my $entry = shift;
	my $title = shift;

	my $ds    = Slim::Music::Info::getCurrentDataStore();
	my $attributes = {};

	# Update title MetaData only if its not a local file with Title information already cached.
	if ($title && Slim::Music::Info::isRemoteURL($entry)) {

		my $track = $ds->objectForUrl($entry);

		if ((blessed($track) && $track->can('title') && (!$track->title || $track->title ne $title)) || 
			!blessed($track)) {

			$attributes->{'TITLE'} = $title;
		}
	}

	return $ds->updateOrCreate({
		'url'        => $entry,
		'attributes' => $attributes,
		'readTags'   => 1,
	});
}

sub readM3U {
	my $m3u    = shift;
	my $m3udir = shift;
	my $url    = shift;

	my @items  = ();
	my $title;
	my $foundBOM = 0;

	$::d_parse && msg("parsing M3U: $url\n");

	while (my $entry = <$m3u>) {

		chomp($entry);

		# strip carriage return from dos playlists
		$entry =~ s/\cM//g;  

		# strip whitespace from beginning and end
		$entry =~ s/^\s*//; 
		$entry =~ s/\s*$//; 

		# Guess the encoding of each line in the file. Bug 1876
		# includes a playlist that has latin1 titles, and utf8 paths.
		my $enc = Slim::Utils::Unicode::encodingFromString($entry);

		# Only strip the BOM off of UTF-8 encoded bytes. Encode will
		# handle UTF-16
		if (!$foundBOM && $enc eq 'utf8') {

			$entry = Slim::Utils::Unicode::stripBOM($entry);
			$foundBOM = 1;
		}

		$entry = Slim::Utils::Unicode::utf8decode_guess($entry, $enc);

		$::d_parse && msg("  entry from file: $entry\n");

		if ($entry =~ /^#EXTINF:.*?,(.*)$/) {
			$title = $1;	

			$::d_parse && msg("  found title: $title\n");
		}

		next if $entry =~ /^#/;
		next if $entry =~ /#CURTRACK/;
		next if $entry eq "";

		$entry =~ s|$LF||g;
		
		$entry = Slim::Utils::Misc::fixPath($entry, $m3udir);

		if (playlistEntryIsValid($entry, $url)) {

			$::d_parse && msg("    entry: $entry\n");

			push @items, _updateMetaData($entry, $title);

			# reset the title
			$title = undef;
		}
	}

	$::d_parse && msg("parsed " . scalar(@items) . " items in m3u playlist\n");

	close $m3u;

	return @items;
}

sub readCurTrackForM3U {
	my $path = shift;

	# do nothing to the index if we can't open the list
	open(FH, $path) || return 0;
		
	# retrieve comment with track number in it
	my $line = <FH>;

	close(FH);
 
	if ($line =~ /#CURTRACK (\d+)$/) {
		return $1;
	}

	return 0;
}

sub writeCurTrackForM3U {
	my $path  = shift;
	my $track = shift || 0;

	# do nothing to the index if we can't open the list
	open(IN, $path) || return 0;
	open(OUT, ">$path.tmp") || return 0;
		
	while (my $line = <IN>) {

		if ($line =~ /#CURTRACK (\d+)$/) {

			$line =~ s/(#CURTRACK) (\d+)$/$1 $track/;
		}

		print OUT $line;
	}

	close(IN);
	close(OUT);

	if (-w $path) {

		rename("$path.tmp", $path);
	}
}

sub readPLS {
	my $pls    = shift;
	my $plsdir = shift;
	my $url    = shift;

	my @urls   = ();
	my @titles = ();
	my @items  = ();
	my $foundBOM = 0;
	
	$::d_parse && msg("Parsing playlist: $url \n");
	
	while (my $line = <$pls>) {

		chomp($line);

		$::d_parse && msg("Parsing line: $line\n");

		# strip carriage return from dos playlists
		$line =~ s/\cM//g;

		# strip whitespace from end
		$line =~ s/\s*$//;

		# Guess the encoding of each line in the file. Bug 1876
		# includes a playlist that has latin1 titles, and utf8 paths.
		my $enc = Slim::Utils::Unicode::encodingFromString($line);

		# Only strip the BOM off of UTF-8 encoded bytes. Encode will
		# handle UTF-16
		if (!$foundBOM && $enc eq 'utf8') {

			$line = Slim::Utils::Unicode::stripBOM($line);
			$foundBOM = 1;
		}

		$line = Slim::Utils::Unicode::utf8decode_guess($line, $enc);

		if ($line =~ m|File(\d+)=(.*)|i) {
			$urls[$1] = $2;
			next;
		}

		if ($line =~ m|Title(\d+)=(.*)|i) {
			$titles[$1] = $2;
			next;
		}	
	}

	for (my $i = 1; $i <= $#urls; $i++) {

		next unless defined $urls[$i];

		my $entry = Slim::Utils::Misc::fixPath($urls[$i]);

		if (playlistEntryIsValid($entry, $url)) {

			push @items, _updateMetaData($entry, $titles[$i]);
		}
	}

	close $pls if (ref($pls) ne 'IO::String');

	return @items;
}

# This now just processes the cuesheet into tags. The calling process is
# responsible for adding the tracks into the datastore.
sub parseCUE {
	my $lines  = shift;
	my $cuedir = shift;
	my $embedded = shift || 0;

	my $artist;
	my $album;
	my $year;
	my $genre;
	my $comment;
	my $filename;
	my $currtrack;
	my $replaygain_track_peak;
	my $replaygain_track_gain;
	my $replaygain_album_peak;
	my $replaygain_album_gain;
	my $tracks = {};

	$::d_parse && msg("parseCUE: cuedir: [$cuedir]\n");

	if (!@$lines) {
		$::d_parse && msg("parseCUE skipping empty cuesheet.\n");
		return;
	}

	for my $line (@$lines) {

		my $enc = Slim::Utils::Unicode::encodingFromString($line);

		# Prefer UTF8 for CUE sheets.
		$line = Slim::Utils::Unicode::utf8decode_guess($line, 'utf8', $enc);

		# strip whitespace from end
		$line =~ s/\s*$//;

		if ($line =~ /^TITLE\s+\"(.*)\"/i) {
			$album = $1;

		} elsif ($line =~ /^PERFORMER\s+\"(.*)\"/i) {
			$artist = $1;

		} elsif ($line =~ /^(?:REM\s+)?YEAR\s+\"(.*)\"/i) {
			$year = $1;

		} elsif ($line =~ /^(?:REM\s+)?GENRE\s+\"(.*)\"/i) {
			$genre = $1;
			
		} elsif ($line =~ /^(?:REM\s+)?COMMENT\s+\"(.*)\"/i) {
			$comment = $1;

		} elsif ($line =~ /^(?:REM\s+)?REPLAYGAIN_ALBUM_GAIN\s+(.*)dB/i) {
			$replaygain_album_gain = $1;
		
		} elsif ($line =~ /^(?:REM\s+)?REPLAYGAIN_ALBUM_PEAK\s+(.*)/i) {
			$replaygain_album_peak = $1;
						
		} elsif ($line =~ /^FILE\s+\"(.*)\"/i) {
			$filename = $1;
			$filename = Slim::Utils::Misc::fixPath($filename, $cuedir);

		} elsif ($line =~ /^FILE\s+\"?(\S+)\"?/i) {
			# Some cue sheets may not have quotes. Allow that, but
			# the filenames can't have any spaces in them.
			$filename = $1;
			$filename = Slim::Utils::Misc::fixPath($filename, $cuedir);

		} elsif ($line =~ /^\s+TRACK\s+(\d+)\s+AUDIO/i) {
			$currtrack = int ($1);

		} elsif (defined $currtrack and $line =~ /^\s+PERFORMER\s+\"(.*)\"/i) {
			$tracks->{$currtrack}->{'ARTIST'} = $1;

		} elsif (defined $currtrack and $line =~ /^(?:\s+REM\s+)?REPLAYGAIN_TRACK_GAIN\s+(.*)dB/i) {
			$tracks->{$currtrack}->{'REPLAYGAIN_TRACK_GAIN'} = $1;

		} elsif (defined $currtrack and $line =~ /^(?:\s+REM\s+)?REPLAYGAIN_TRACK_PEAK\s+(.*)/i) {
			$tracks->{$currtrack}->{'REPLAYGAIN_TRACK_PEAK'} = $1;
			
		} elsif (defined $currtrack and
			 $line =~ /^(?:\s+REM)?\s+(TITLE|YEAR|GENRE|COMMENT|COMPOSER|CONDUCTOR|BAND|DISC|DISCC)\s+\"(.*)\"/i) {

			$tracks->{$currtrack}->{uc $1} = $2;

		} elsif (defined $currtrack and $line =~ /^\s+INDEX\s+00\s+(\d+):(\d+):(\d+)/i) {

			$tracks->{$currtrack}->{'PREGAP'} = ($1 * 60) + $2 + ($3 / 75);

		} elsif (defined $currtrack and $line =~ /^\s+INDEX\s+01\s+(\d+):(\d+):(\d+)/i) {

			$tracks->{$currtrack}->{'START'} = ($1 * 60) + $2 + ($3 / 75);

		} elsif (defined $currtrack and $line =~ /^\s*REM\s+END\s+(\d+):(\d+):(\d+)/i) {
			$tracks->{$currtrack}->{'END'} = ($1 * 60) + $2 + ($3 / 75);			

		} elsif (defined $currtrack and defined $filename) {
			# Each track in a cue sheet can have a different
			# filename. See Bug 2126 &
			# http://www.hydrogenaudio.org/forums/index.php?act=ST&f=20&t=4586
			$tracks->{$currtrack}->{'FILENAME'} = $filename;
		}
	}

	# Check to make sure that the files are actually on disk - so we don't
	# create bogus database entries.
	for my $key (sort {$b <=> $a} keys %$tracks) {

		my $filepath = Slim::Utils::Misc::pathFromFileURL(($tracks->{$key}->{'FILENAME'} || $filename));

		if (!$embedded && defined $filepath && !-r $filepath) {

			errorMsg("parseCUE: Couldn't find referenced FILE: [$filepath] on disk! Skipping!\n");

			delete $tracks->{$key};
		}
	}

	if (scalar keys %$tracks == 0 || (!$currtrack || $currtrack < 1 || !$filename)) {
		$::d_parse && msg("parseCUE unable to extract tracks from cuesheet\n");
		return {};
	}

	# calc song ending times from start of next song from end to beginning.
	my $lastpos = $tracks->{$currtrack}->{'END'};

	# If we can't get $lastpos from the cuesheet, try and read it from the original file.
	if (!$lastpos && $filename) {

		$::d_parse && msg("Reading tags to get ending time of $filename\n");

		my $ds = Slim::Music::Info::getCurrentDataStore();
		my $track = $ds->updateOrCreate({
			'url'        => $filename,
			'readTags'   => 1,
		});

		$lastpos = $track->secs();
	}

	errorMsg("parseCUE: Couldn't get duration of $filename\n") unless $lastpos;

	for my $key (sort {$b <=> $a} keys %$tracks) {

		my $track = $tracks->{$key};

		if (!defined $track->{'END'}) {
			$track->{'END'} = $lastpos;
		}

		#defer pregap handling until we have continuous play through consecutive tracks
		#$lastpos = (exists $track->{'PREGAP'}) ? $track->{'PREGAP'} : $track->{'START'};
		$lastpos = $track->{'START'};
	}

	for my $key (sort {$a <=> $b} keys %$tracks) {

		my $track = $tracks->{$key};

		# Each track can have it's own FILE
		if (!defined $track->{'FILENAME'}) {

			$track->{'FILENAME'} = $filename;
		}

		my $file = $track->{'FILENAME'};
	
		if (!defined $track->{'START'} || !defined $track->{'END'} || !defined $file ) {

			next;
		}

		# Don't use $track->{'URL'} or the db will break
		$track->{'URI'} = "$file#".$track->{'START'}."-".$track->{'END'};

		$::d_parse && msg("    URL: " . $track->{'URI'} . "\n");

		# Ensure that we have a CONTENT_TYPE
		if (!defined $track->{'CONTENT_TYPE'}) {
			$track->{'CONTENT_TYPE'} = Slim::Music::Info::typeFromPath($file, 'mp3');
		}

		$track->{'TRACKNUM'} = $key;
		$::d_parse && msg("    TRACKNUM: " . $track->{'TRACKNUM'} . "\n");

		for my $attribute (qw(TITLE ARTIST ALBUM CONDUCTOR COMPOSER BAND YEAR 
			GENRE REPLAYGAIN_TRACK_PEAK REPLAYGAIN_TRACK_GAIN)) {

			if (exists $track->{$attribute}) {
				$::d_parse && msg("    $attribute: " . $track->{$attribute} . "\n");
			}
		}

		# Merge in file level attributes
		if (!exists $track->{'ARTIST'} && defined $artist) {
			$track->{'ARTIST'} = $artist;
			$::d_parse && msg("    ARTIST: " . $track->{'ARTIST'} . "\n");
		}

		if (!exists $track->{'ALBUM'} && defined $album) {
			$track->{'ALBUM'} = $album;
			$::d_parse && msg("    ALBUM: " . $track->{'ALBUM'} . "\n");
		}

		if (!exists $track->{'YEAR'} && defined $year) {
			$track->{'YEAR'} = $year;
			$::d_parse && msg("    YEAR: " . $track->{'YEAR'} . "\n");
		}

		if (!exists $track->{'GENRE'} && defined $genre) {
			$track->{'GENRE'} = $genre;
			$::d_parse && msg("    GENRE: " . $track->{'GENRE'} . "\n");
		}

		if (!exists $track->{'COMMENT'} && defined $comment) {
			$track->{'COMMENT'} = $comment;
			$::d_parse && msg("    COMMENT: " . $track->{'COMMENT'} . "\n");
		}
		
		if (!exists $track->{'REPLAYGAIN_ALBUM_GAIN'} && defined $replaygain_album_gain) {
			$track->{'REPLAYGAIN_ALBUM_GAIN'} = $replaygain_album_gain;
			$::d_parse && msg("    REPLAYGAIN_ALBUM_GAIN: " . $track->{'REPLAYGAIN_ALBUM_GAIN'} . "\n");
		}

		if (!exists $track->{'REPLAYGAIN_ALBUM_PEAK'} && defined $replaygain_album_peak) {
			$track->{'REPLAYGAIN_ALBUM_PEAK'} = $replaygain_album_peak;
			$::d_parse && msg("    REPLAYGAIN_ALBUM_PEAK: " . $track->{'REPLAYGAIN_ALBUM_PEAK'} . "\n");
		}
			
		# Everything in a cue sheet should be marked as audio.
		$track->{'AUDIO'} = 1;
	}

	return $tracks;
}

sub readCUE {
	my $cuefile = shift;
	my $cuedir  = shift;
	my $url     = shift;

	$::d_parse && msg("Parsing cue: $url \n");

	my $ds = Slim::Music::Info::getCurrentDataStore();

	my @lines = ();
	my @items = ();

	while (my $line = <$cuefile>) {

		chomp($line);
		$line =~ s/\cM//g;  
		next if ($line =~ /^\s*$/);

		push @lines, $line;
	}

	close $cuefile;

	my $tracks = (parseCUE([@lines], $cuedir));

	return @items unless defined $tracks && keys %$tracks > 0;

	#
	my $basetrack = undef;

	# Process through the individual tracks
	for my $key (sort { $a <=> $b } keys %$tracks) {

		my $track = $tracks->{$key};

		if (!defined $track->{'URI'} || !defined $track->{'FILENAME'}) {
			$::d_parse && msg("Skipping track without url or filename\n");
			next;
		}

		# We may or may not have run updateOrCreate on the base filename
		# during parseCUE, depending on the cuesheet contents.
		# Run it here just to be sure.
		# Set the content type on the base file to hide it from listings.
		# Grab data from the base file to pass on to our individual tracks.
		if (!defined $basetrack || $basetrack->url ne $track->{'FILENAME'}) {

			$::d_parse && msg("Creating new track for: $track->{'FILENAME'}\n");

			$basetrack = $ds->updateOrCreate({
				'url'        => $track->{'FILENAME'},
				'attributes' => {
					'CONTENT_TYPE'    => 'cur',
					'AUDIO' => 0
				},
				'readTags'   => 1,
			});

			# Remove entries from other sources. This cuesheet takes precedence.
			my $find = {'url', $track->{'FILENAME'} . "#*" };

			my @oldtracks = $ds->find({
				'field' => 'url',
				'find'  => $find,
			});

			for my $oldtrack (@oldtracks) {
				$::d_parse && msg("Deleting previous entry for $oldtrack\n");
				$ds->delete($oldtrack);
			}
		}

		push @items, $track->{'URI'}; #url;
		
		# Bug 1855: force track size metadata from basetrack into indexed track.
		# this forces the basetrack object expansion as well, so other metadata
		$track->{'SIZE'} = $basetrack->audio_size;

		# our tracks won't be visible if we don't include some data from the base file
		for my $attribute (keys %$basetrack) {
			next if $attribute eq 'id';
			next if $attribute eq 'url';
			next if $attribute =~ /^_/;
			next unless exists $basetrack->{$attribute};
			
			$track->{uc $attribute} = $basetrack->{$attribute} unless exists $track->{uc $attribute};
		}

		processAnchor($track);

		# Do the actual data store
		# Skip readTags since we'd just be reading the same file over and over
		$ds->updateOrCreate({
			'url'        => $track->{'URI'},
			'attributes' => $track,
			'readTags'   => 0,  # no need to read tags, since we did it for the base file
		});
	}

	$::d_parse && msg("    returning: " . scalar(@items) . " items\n");	

	return @items;
}

sub processAnchor {
	my $attributesHash = shift;

	my ($start, $end) = Slim::Music::Info::isFragment($attributesHash->{'URI'});

	# rewrite the size, offset and duration if it's just a fragment
	# This is mostly (always?) for cue sheets.
	if (!defined $start && !defined $end) {
		$::d_parse && msg("parse: Couldn't process anchored file fragment for " . $attributesHash->{'URI'} . "\n");
		return 0;
	}

	my $duration = $end - $start;

	# Don't divide by 0
	if (!defined $attributesHash->{'SECS'} && $duration) {

		$attributesHash->{'SECS'} = $duration;

	} elsif (!$attributesHash->{'SECS'}) {

		$::d_parse && msg("parse: Couldn't process undef or 0 SECS fragment for " . $attributesHash->{'URI'} . "\n");

		return 0;
	}

	my $byterate   = $attributesHash->{'SIZE'} / $attributesHash->{'SECS'};
	my $header     = $attributesHash->{'AUDIO_OFFSET'} || 0;
	my $startbytes = int($byterate * $start);
	my $endbytes   = int($byterate * $end);
			
	$startbytes -= $startbytes % $attributesHash->{'BLOCK_ALIGNMENT'} if $attributesHash->{'BLOCK_ALIGNMENT'};
	$endbytes   -= $endbytes % $attributesHash->{'BLOCK_ALIGNMENT'} if $attributesHash->{'BLOCK_ALIGNMENT'};
			
	$attributesHash->{'AUDIO_OFFSET'} = $header + $startbytes;
	$attributesHash->{'SIZE'} = $endbytes - $startbytes;
	$attributesHash->{'SECS'} = $duration;

	if ($::d_parse) {
		msg("parse: calculating duration for anchor: $duration\n");
		msg("parse: calculating header $header, startbytes $startbytes and endbytes $endbytes\n");
	}		
}

sub writePLS {
	my $listref = shift;
	my $playlistname = shift || "SlimServer " . Slim::Utils::Strings::string("PLAYLIST");
	my $filename = shift;

	my $string = '';
	my $output = _filehandleFromNameOrString($filename, \$string) || return;

	print $output "[playlist]\nPlaylistName=$playlistname\n";

	my $itemnum = 0;
	my $ds      = Slim::Music::Info::getCurrentDataStore();

	for my $item (@{$listref}) {

		$itemnum++;

		my $track = $ds->objectForUrl($item);

		if (!blessed($track) || !$track->can('title')) {

			errorMsg("writePLS: Couldn't fetch track object for: [$item]\n");

			next;
		}

		printf($output "File%d=%s\n", $itemnum, _pathForItem($item));

		my $title = $track->title();

		if ($title) {
			printf($output "Title%d=%s\n", $itemnum, $title);
		}

		printf($output "Length%d=%s\n", $itemnum, ($track->duration() || -1));
	}

	print $output "NumberOfItems=$itemnum\nVersion=2\n";

	close $output if $filename;
	return $string;
}

sub writeM3U {
	my $listref = shift;
	my $playlistname = shift;
	my $filename = shift;
	my $addTitles = shift;
	my $resumetrack = shift;

	my $string = '';
	my $output = _filehandleFromNameOrString($filename, \$string) || return;

	print $output "#CURTRACK $resumetrack\n" if defined($resumetrack);
	print $output "#EXTM3U\n" if $addTitles;

	my $ds = Slim::Music::Info::getCurrentDataStore();

	for my $item (@{$listref}) {

		if ($addTitles && Slim::Music::Info::isURL($item)) {

			my $track = $ds->objectForUrl($item);

			if (!blessed($track) || !$track->can('title')) {

				errorMsg("writeM3U: Couldn't retrieve objectForUrl: [$item] - skipping!\n");
				next;
			};
			
			my $title = Slim::Utils::Unicode::utf8decode( $track->title );

			if ($title) {
				print $output "#EXTINF:-1,$title\n";
			}
		}

		# XXX - we still have a problem where there can be decomposed
		# unicode characters. I don't know how this happens - it's
		# coming from the filesystem.
		my $path = Slim::Utils::Unicode::utf8decode( _pathForItem($item, 1) );

		print $output "$path\n";
	}

	close $output if $filename;

	return $string;
}

sub readWPL {
	my $wplfile = shift;
	my $wpldir  = shift;
	my $url     = shift;

	my @items  = ();

	# Handles version 1.0 WPL Windows Medial Playlist files...
	my $wpl_playlist = {};

	eval {
		$wpl_playlist = XMLin($wplfile);
	};

	$::d_parse && msg("parsing WPL: $wplfile url: [$url]\n");

	if (exists($wpl_playlist->{body}->{seq}->{media})) {
		
		my @media;
		if (ref $wpl_playlist->{body}->{seq}->{media} ne 'ARRAY') {
			push @media, $wpl_playlist->{body}->{seq}->{media};
		} else {
			@media = @{$wpl_playlist->{body}->{seq}->{media}};
		}
		
		for my $entry_info (@media) {

			my $entry=$entry_info->{src};

			$::d_parse && msg("  entry from file: $entry\n");
		
			$entry = Slim::Utils::Misc::fixPath($entry, $wpldir);

			if (playlistEntryIsValid($entry, $url)) {

				$::d_parse && msg("    entry: $entry\n");

				push @items, _updateMetaData($entry, undef);
			}
		}
	}

	$::d_parse && msg("parsed " . scalar(@items) . " items in wpl playlist\n");

	return @items;
}

sub writeWPL {
	my $listref = shift;
	my $playlistname = shift || "SlimServer " . Slim::Utils::Strings::string("PLAYLIST");
	my $filename = shift;

	# Handles version 1.0 WPL Windows Medial Playlist files...

	# Load the original if it exists (so we don't lose all of the extra crazy info in the playlist...
	my $wpl_playlist = {};

	eval {
		$wpl_playlist = XMLin($filename, KeepRoot => 1, ForceArray => 1);
	};

	if($wpl_playlist) {
		# Clear out the current playlist entries...
		$wpl_playlist->{smil}->[0]->{body}->[0]->{seq}->[0]->{media} = [];

	} else {
		# Create a skeleton of the structure we'll need to output a compatible WPL file...
		$wpl_playlist={
			smil => [{
				body => [{
					seq => [{
						media => [
						]
					}]
				}],
				head => [{
					title => [''],
					author => [''],
					meta => {
						Generator => {
							content => '',
						}
					}
				}]
			}]
		};
	}

	for my $item (@{$listref}) {

		if (Slim::Music::Info::isURL($item)) {
			my $url=uri_unescape($item);
			$url=~s/^file:[\/\\]+//;
			push(@{$wpl_playlist->{smil}->[0]->{body}->[0]->{seq}->[0]->{media}},{src => $url});
		}
	}

	# XXX - Windows Media Player 9 has problems with directories,
	# and files that have an &amp; in them...

	# Generate our XML for output...
	# (the ForceArray option when we do "XMLin" makes the hash messy,
	# but ensures that we get the same style of XML layout back on
	# "XMLout")
	my $wplfile = XMLout($wpl_playlist, XMLDecl => '<?wpl version="1.0"?>', RootName => undef);

	my $string;

	my $output = _filehandleFromNameOrString($filename, \$string) || return;
	print $output $wplfile;
	close $output if $filename;

	return $string;
}

sub readASX {
	my $asxfile = shift;
	my $asxdir  = shift;
	my $url     = shift;

	my @items  = ();

	my $asx_playlist={};
	my $asxstr = '';
	while (<$asxfile>) {
		$asxstr .= $_;
	}
	close $asxfile;

	# First try for version 3.0 ASX
	if ($asxstr =~ /<ASX/i) {
		# Deal with the common parsing problem of unescaped ampersands
		# found in many ASX files on the web.
		$asxstr =~ s/&(?!(#|amp;|quot;|lt;|gt;|apos;))/&amp;/g;

		# Convert all tags to upper case as ASX allows mixed case tags, XML does not!
		$asxstr =~ s{(<[^\s>]+)}{\U$1\E}mg;

		eval {
			# We need to send a ProtocolEncoding option to XML::Parser,
			# but XML::Simple carps at it. Unfortunately, we don't 
			# have a choice - we can't change the XML, as the
			# XML::Simple warning suggests.
			no warnings;
			$asx_playlist = XMLin(\$asxstr, ForceArray => ['ENTRY', 'REF'], ParserOpts => [ ProtocolEncoding => 'ISO-8859-1' ]);
		};
		
		$::d_parse && msg("parsing ASX: $asxfile url: [$url]\n");

		my $entries = $asx_playlist->{ENTRY} || $asx_playlist->{REPEAT}->{ENTRY};

		if (defined($entries)) {

			for my $entry (@$entries) {
				
				my $title = $entry->{TITLE};

				$::d_parse && msg("Found an entry title: $title\n");

				my $path;
				my $refs = $entry->{REF};

				if (defined($refs)) {

					for my $ref (@$refs) {

						my $href = $ref->{href} || $ref->{Href} || $ref->{HREF};
						
						# We've found URLs in ASX files that should be
						# escaped to be legal - specifically, they contain
						# spaces. For now, deal with this specific case.
						# If this seems to happen in other ways, maybe we
						# should URL escape before continuing.
						$href =~ s/ /%20/;

						my $url = URI->new($href);

						$::d_parse && msg("Checking if we can handle the url: $url\n");
						
						my $scheme = $url->scheme();

						if ($scheme =~ s/^mms(.?)/mms/) {
							$url->scheme($scheme);
							$href = $url->as_string();
						}

						if (Slim::Player::ProtocolHandlers->loadHandler(lc $scheme)) {

							$::d_parse && msg("Found a handler for: $url\n");
							$path = $href;
							last;
						}
					}
				}
				
				if (defined($path)) {

					$path = Slim::Utils::Misc::fixPath($path, $asxdir);

					if (playlistEntryIsValid($path, $url)) {

						push @items, _updateMetaData($path, $title);
					}
				}
			}
		}
	}

	# Next is version 2.0 ASX
	elsif ($asxstr =~ /[Reference]/) {
		while ($asxstr =~ /^Ref(\d+)=(.*)$/gm) {

			my $entry = URI->new($2);

			# XXX We've found that ASX 2.0 refers to http: URLs, when it
			# really means mms: URLs. Wouldn't it be nice if there were
			# a real spec?
			if ($entry->scheme eq 'http') {
				$entry->scheme('mms');
			}

			if (playlistEntryIsValid($entry->as_string, $url)) {

				push @items, _updateMetaData($entry->as_string);
			}
		}
	}

	# And finally version 1.0 ASX
	else {
		while ($asxstr =~ /^(.*)$/gm) {

			my $entry = $1;

			if (playlistEntryIsValid($entry, $url)) {

				push @items, _updateMetaData($entry);
			}
		}
	}

	$::d_parse && msg("parsed " . scalar(@items) . " items in asx playlist\n");

	return @items;
}

sub readPodcast {
	my $in = shift;

	#$::d_parse && msg("Parsing podcast...\n");

	my @urls = ();

	# async http request succeeded.  Parse XML
	# forcearray to treat items as array,
	# keyattr => [] prevents id attrs from overriding
	my $xml = eval { XMLin(\$in, forcearray => ["item"], keyattr => []) };

	if ($@) {
		$::d_parse && msg("Parse: failed to parse podcast because:\n$@\n");
		# TODO: how can we get error message to client?
		return undef;
	}

	# some feeds (slashdot) have items at same level as channel
	my $items;
	if ($xml->{item}) {
		$items = $xml->{item};
	} else {
		$items = $xml->{channel}->{item};
	}

	for my $item (@$items) {
		my $enclosure = $item->{enclosure};

		if (ref $enclosure eq 'ARRAY') {
			$enclosure = $enclosure->[0];
		}

		if ($enclosure) {
			if ($enclosure->{type} =~ /audio/) {
				push @urls, $enclosure->{url};
				if ($item->{title}) {
					# associate a title with the url
					# XXX calling routine beginning with "_"
					Slim::Formats::Parse::_updateMetaData($enclosure->{url}, $item->{title});
				}
			}
		}
	}

	# it seems like the caller of this sub should be the one to close,
	# since they openned it.  But I'm copying other read routines
	# which call close at the end.
	close $in;

	return @urls;
}

sub _pathForItem {
	my $item = shift;

	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		return Slim::Utils::Misc::pathFromFileURL($item);
	}

	return $item;
}

sub _filehandleFromNameOrString {
	my $filename  = shift;
	my $outstring = shift;

	my $output;

	if ($filename) {

		$output = FileHandle->new($filename, "w") || do {
			msg("Could not open $filename for writing.\n");
			return undef;
		};

		# Always write out in UTF-8 with a BOM.
		if ($] > 5.007) {

			binmode($output, ":raw");

			print $output $File::BOM::enc2bom{'utf8'};

			binmode($output, ":encoding(utf8)");
		}

	} else {

		$output = IO::String->new($$outstring);
	}

	return $output;
}

sub playlistEntryIsValid {
	my ($entry, $url) = @_;

	my $caller = (caller(1))[3];

	if (Slim::Music::Info::isRemoteURL($entry) || Slim::Music::Info::isRemoteURL($url)) {

		return 1;
	}

	# Be verbose to the user - this will let them fix their files / playlists.
	if ($entry eq $url) {

		msg("$caller:\nWARNING:\n\tFound self-referencing playlist in:\n\t$entry == $url\n\t - skipping!\n\n");
		return 0;
	}

	if (!Slim::Music::Info::isFile($entry)) {

		msg("$caller:\nWARNING:\n\t$entry found in playlist:\n\t$url doesn't exist on disk - skipping!\n\n");
		return 0;
	}

	return 1;
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:

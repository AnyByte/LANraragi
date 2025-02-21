package LANraragi::Utils::Database;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(decode_json);
use Encode;
use File::Basename;
use Redis;
use Cwd;

use LANraragi::Model::Config;
use LANraragi::Model::Plugins;

# Functions for interacting with the DB Model.

#add_archive_to_redis($id,$file,$redis)
#Parses the name of a file for metadata, and matches that metadata to the SHA-1 hash of the file in our Redis database.
#This function doesn't actually require the file to exist at its given location.
sub add_archive_to_redis {
    my ( $id, $file, $redis ) = @_;
    my $logger =
      LANraragi::Utils::Generic::get_logger( "Archive", "lanraragi" );
    my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );

    #jam this shit in redis
    $logger->debug("Pushing to redis on ID $id:");
    $logger->debug("File Name: $name");
    $logger->debug("Filesystem Path: $file");

    my $title = $name;
    my $tags  = "";

    $redis->hset( $id, "name", encode_utf8($name) );

    #Don't encode filenames.
    $redis->hset( $id, "file", $file );

    #New file in collection, so this flag is set.
    $redis->hset( $id, "isnew", "block" );

    #Use the mythical regex to get title and tags
    #Except if the matching pref is off
    if ( LANraragi::Model::Config->get_tagregex eq "1" ) {
        ( $title, $tags ) = parse_name($name);
        $logger->debug("Parsed Title: $title");
        $logger->debug("Parsed Tags: $tags");
    }

    $redis->hset( $id, "title", encode_utf8($title) );
    $redis->hset( $id, "tags",  encode_utf8($tags) );

    return ( $name, $title, $tags, "block" );
}

#add_tags($id, $tags)
#add the $tags to the archive with id $id.
sub add_tags {

    my ( $id, $newtags ) = @_;

    my $redis = LANraragi::Model::Config::get_redis;
    my $oldtags = $redis->hget( $id, "tags" );
    $oldtags = LANraragi::Utils::Database::redis_decode($oldtags);

    if ( length $newtags ) {

        if ( $oldtags ne "" ) {
            $newtags = $oldtags . "," . $newtags;
        }

        $redis->hset( $id, "tags", encode_utf8($newtags) );
    }
}

sub set_title {

    my ( $id, $newtitle ) = @_;
    my $redis = LANraragi::Model::Config::get_redis;

    if ( $newtitle ne "" ) {
        $redis->hset( $id, "title", encode_utf8($newtitle) );
    }

}

#parse_name(name)
#parses an archive name with the regex specified in the configuration file(get_regex and select_from_regex subs) to find metadata.
sub parse_name {

    my ( $event, $artist, $title, $series, $language );
    $event = $artist = $title = $series = $language = "";

    #Replace underscores with spaces
    $_[0] =~ s/_/ /g;

    #Use the regex on our file, and pipe it to the regexsel sub.
    $_[0] =~ LANraragi::Model::Config->get_regex;

    #Take variables from the regex selection
    if ( defined $2 ) { $event    = $2; }
    if ( defined $4 ) { $artist   = $4; }
    if ( defined $5 ) { $title    = $5; }
    if ( defined $7 ) { $series   = $7; }
    if ( defined $9 ) { $language = $9; }

    my @tags = ();

    if ( $event ne "" ) {
        push @tags, "event:$event";
    }

    if ( $artist ne "" ) {

     #Special case for circle/artist sets:
     #If the string contains parenthesis, what's inside those is the artist name
     #the rest is the circle.
        if ( $artist =~ /(.*) \((.*)\)/ ) {
            push @tags, "group:$1";
            push @tags, "artist:$2";
        }
        else {
            push @tags, "artist:$artist";
        }
    }

    if ( $series ne "" ) {
        push @tags, "series:$series";
    }

    if ( $language ne "" ) {
        push @tags, "language:$language";
    }

    my $tagstring = join( ", ", @tags );

    return ( $title, $tagstring );
}

#This function is used for all ID computation in LRR.
#Takes the path to the file as an argument.
sub compute_id {

    my $file = $_[0];

    #Read the first 500 KBs only (allows for faster disk speeds )
    open( my $handle, '<', $file ) or die "Couldn't open $file :" . $!;
    my $data;
    my $len = read $handle, $data, 512000;
    close $handle;

    #Compute a SHA-1 hash of this data
    my $ctx = Digest::SHA->new(1);
    $ctx->add($data);
    my $digest = $ctx->hexdigest;

    return $digest;

}

#Final Solution to the Unicode glitches -- Eval'd double-decode for data obtained from Redis.
#This should be a one size fits-all function.
sub redis_decode {

    my $data = $_[0];

#Setting FB_CROAK tells encode to die instantly if it encounters any errors.
#Without this setting, it typically tries to replace characters... which might already be valid UTF8!
    eval { $data = decode_utf8( $data, Encode::FB_CROAK ) };

    #Do another UTF-8 decode just in case the data was double-encoded
    eval { $data = decode_utf8( $data, Encode::FB_CROAK ) };

    return $data;
}

#Touch the Shinobu nudge file. This will invalidate the currently cached JSON.
sub invalidate_cache {
    utime( undef, undef, cwd . "/.shinobu-nudge" )
      or warn "Couldn't touch .shinobu-nudge: $!";
}

# Return a list of archive IDs that have no tags.
# Tags added automatically by the autotagger are ignored.
sub find_untagged_archives {

    my $redis   = LANraragi::Model::Config::get_redis;
    my @keys    = $redis->keys('????????????????????????????????????????');
    my @untagged;

    #Parse the archive list.
    foreach my $id (@keys) {
        my $zipfile = $redis->hget( $id, "file" );
        if ( -e $zipfile ) {

            my $title = $redis->hget( $id, "title" );
            $title = LANraragi::Utils::Database::redis_decode($title);

            my $tagstr = $redis->hget($id, "tags");
            $tagstr = LANraragi::Utils::Database::redis_decode($tagstr);
            my @tags = split(/,\s?/, $tagstr);
            my $nondefaulttags = 0;
            
            foreach my $t (@tags) {
                LANraragi::Utils::Generic::remove_spaces($t);
                LANraragi::Utils::Generic::remove_newlines($t);
                
                # the following are the only namespaces that LANraragi::Utils::Database::parse_name adds
                $nondefaulttags += 1 unless $t =~ /(artist|parody|series|language|event|group):.*/
            }
            
            #If the archive has no tags, or the tags namespaces are only from
            #filename parsing (probably), add it to the list.
            if (!@tags || $nondefaulttags == 0) {
                push @untagged, $id;
            }
        }
    }
    return @untagged;
}

1;

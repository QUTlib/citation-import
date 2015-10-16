package EPrints::Plugin::Import::CitationService::GScholar;
###############################################################################
#
# Google Scholar citation ingest.
#
# This plug-in will retrieve citation data from Google Scholar and store it in
# the "gscholar" dataset. This plug-in is closely based on the Export::GScholar
# plug-in provided in the core EPrints distribution.
#
###############################################################################
#
# Copyright 2011 Queensland University of Technology. All Rights Reserved.
#
#  This file is part of the Citation Count Dataset and Import Plug-ins for GNU
#  EPrints 3.
#
#  Copyright (c) 2011 Queensland University of Technology, Queensland, Australia
#
#  The plug-ins are free software; you can redistribute them and/or modify
#  them under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The plug-ins are distributed in the hope that they will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with EPrints 3; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
######################################################################

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

#
# Create a new plug-in object.
#
sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = "Google Scholar Citation Ingest";

    # check that the plug-in has a usable configuration
    if( $self->{session}->can_call( "gscholar", "search_cites" ) && $self->{session}->can_call( "gscholar", "search_title" ) )
    {
	# create an instance of WWW::Mechanize::Sleepy
	if( EPrints::Utils::require_if_exists( "WWW::Mechanize::Sleepy" ) )
	{
	    $self->{mech} = WWW::Mechanize::Sleepy->new( sleep=>'5..15',
							 autocheck=>1,
						       );
	    $self->{mech}->agent_alias( "Linux Mozilla" );    # Engage cloaking device!
	}
	else
	{
	    $self->{error}   = 'Unable to load required module WWW::Mechanize::Sleepy';
	    $self->{disable} = 1;
	}
    }
    else
    {
	$self->{error}   = 'Not configured.';
	$self->{disable} = 1;
    }

    return $self;
}

#
# Test whether or not this plug-in can hope to retrieve data for a given eprint.
#
sub can_process
{
    my( $plugin, $eprint ) = @_;

    if( $eprint->is_set( "gscholar_cluster" ) )
    {
	# do not process eprints with cluster ID set to "-"
	return 0 if $eprint->get_value( "gscholar_cluster" ) eq "-";

	# otherwise, we can use the existing cluster ID to retrieve data
	return 1;
    }

    # otherwise, we can (try to) retrieve data if this eprint has a title and authors
    return $eprint->is_set( "title" ) && $eprint->is_set( "creators_name" );
}

#
# Get the response from Google for a given eprint. This actually returns
# the unique instance of WWW::Mechanize::Sleepy, connected to the first page
# of Google's search results.
#
sub get_response
{
    my( $plugin, $eprint ) = @_;

    my $quri;
    if( $eprint->is_set( "gscholar_cluster" ) )
    {
	# build a query using the known cluster ID
	$quri = $eprint->repository->call( [ "gscholar", "search_cites" ], $eprint );
    }
    else
    {
	# build a query using the eprint's title and author
	$quri = $eprint->repository->call( [ "gscholar", "search_title" ], $eprint );
    }

    # send the query to Google Scholar
    my $response;
    eval {
	$response = $plugin->{mech}->get( $quri );
	1;
      }
      or do
    {
	$plugin->warning( "Could not connect to Google Scholar: " . $@ );
	return undef;
    };

    if( $response->is_success )
    {
	return $plugin->{mech};
    }
    else
    {
	$plugin->warning( "Unable to search Google Scholar. The response was: " . $response->status_line . "\n" );
	return undef;
    }

}

#
# Convert the response from Google into an "epdata" hash.
#
sub response_to_epdata
{
    my( $plugin, $eprint, $response ) = @_;

    if( $eprint->is_set( "gscholar_cluster" ) )
    {
	# query was ?cites=ID
	return response_to_epdata_with_id( $plugin, $eprint, $response );
    }
    else
    {
	# query was ?q=author:NAME+intitle:TITLE
	return response_to_epdata_no_id( $plugin, $eprint, $response );
    }
}

#
# Convert a response to a cluster ID query into an "epdata" hash
#
sub response_to_epdata_with_id
{
    my( $plugin, $eprint, $response ) = @_;

    my $cluster_id = $eprint->get_value( "gscholar_cluster" );
    my $body       = $response->content;
    if( $body =~ /Results <b>\d+<\/b>\s-\s<b>\d+<\/b>\sof\s(about\s)?<b>([\d,]+)<\/b>/ )
    {
	# extract the citation count from "Results <b>1</b> - <b>9</b> of <b>COUNT</b>"
	my $cites = $2;
	$cites =~ s/,//;

	return { cluster=>$cluster_id,
		 impact=>$cites,
	       };
    }
    elsif( $body =~ /Your search did not match any articles/ )
    {
	# no citations
	return { cluster=>$cluster_id,
		 impact=>0
	       };
    }
    else
    {
	# not a page that we recognise
	$plugin->warning( "Could not extract citation count for EPrint ID " . $eprint->get_id . "\n" );
	return {};
    }

}

#
# Convert a response to a title/author search into an "epdata" hash.
#
sub response_to_epdata_no_id
{
    my( $plugin, $eprint, $response ) = @_;

    my $cluster_id;

    # get links that match the eprint's URL
    my $eprint_link = $eprint->get_url;
    $eprint_link =~ s/(\d+\/)/(?:archive\/0+)?$1/;
    my $by_url = $response->find_link( url_regex=>qr/^$eprint_link/ );

    # get links that match the eprint's title
    my $title = $eprint->get_value( "title" );
    $title =~ s/^(.{30,}?):\s.*$/$1/;    # strip sub-titles
    my $title_re = $title;
    while( length( $title_re ) > 70 )
    {
	last unless $title_re =~ s/\s*\S+$//;
    }
    $title_re =~ s/[^\w\s]/\.?/g;
    $title_re =~ s/\s+/(?:\\s|(?:<\\\/?b>))+/g;
    my $by_title = $response->find_link( text_regex=>qr/^(?:<b>)?$title_re/i );

    # search the links for the citation count and cluster ID
    for( grep { defined $_ } $by_url, $by_title )
    {
	# find the link to the eprint
	my @links = $response->links;
	my $i;
	for( $i = 0 ; $i < @links ; ++$i )
	{
	    last if $links[ $i ]->url eq $_->url;
	}

	# continue to the informational links
	for( ; $i < @links ; ++$i )
	{
	    if( $links[ $i ]->text =~ /^All \d+ versions/ )
	    {
		# extract the cluster ID from the "all x versions" link
		$cluster_id = { $links[ $i ]->URI->query_form }->{"cluster"};
		last;
	    }
	    if( $links[ $i ]->text =~ /^Cited by \d+/ )
	    {
		# extract the cluster ID from the "cited by x" link
		$cluster_id = { $links[ $i ]->URI->query_form }->{"cites"};
		last;
	    }
	    if( $links[ $i ]->text =~ /Cached/ )
	    {
		# no "cited by" link - give up
		last;
	    }
	}
    }

    unless( $cluster_id )
    {
	# didn't find anything we could use
	$plugin->warning( "No match for EPrint ID " . $eprint->get_id . "\n" );
	return {};
    }

    # extract the citation count from the "cited by x" link (if no link, assume zero citations)
    my $cites = 0;
    my $cites_link = $response->find_link( text_regex=>qr/Cited by \d+/,
					   url_regex=>qr/\b$cluster_id\b/
					 );
    if( $cites_link )
    {
	$cites_link->text =~ /(\d+)/;
	$cites = $1;
    }

    return { cluster=>$cluster_id,
	     impact=>$cites,
	   };
}

1;

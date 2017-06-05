package EPrints::Plugin::Import::CitationService::Scopus;

###############################################################################
#
# Scopus Search API citation ingest.
#
# This plug-in will retrieve citation data from Scopus. This data should be
# stored in the "scopus" dataset.
#
###############################################################################
#
# Copyright 2017 Queensland University of Technology. All Rights Reserved.
#
#  This file is part of the Citation Count Dataset and Import Plug-ins for GNU
#  EPrints 3.
#
#  Copyright (c) 2017 Queensland University of Technology, Queensland, Australia
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
#
# June 2017 / Matty K:
#
# - handle API error responses better (#26)
#
######################################################################
#
# October 2016 / Matty K:
#
# - improved query parameterisation, timeouts, etc.
#
######################################################################
#
# October 2015 / Matty K:
#
# - update to use new api.elsevier.com API endpoint (big change)
#
######################################################################
#
# May 2013 / sf2:
#
# - don't fail if an EPrint has no title
#
######################################################################
#
# May-June 2013 / gregson:
#
# - Added query fallbacks - EID to DOI to metadata - to improve match
#   success rate and handle Scopus changing EIDs
# - Revised and improved exception handling
# - Corrected encoding of multi-byte characters in the query
# - Added a call() method to handle HTTP requests with retry on
#   transport failure
# - Added a workaround for Scopus return malformed XML error responses
# - Refined metadata querystring generation to handle more special
#   characters
#
######################################################################

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

use LWP::UserAgent;
use Unicode::Normalize qw(NFKC);
use URI;

our $SEARCHAPI = URI->new( "http://api.elsevier.com/content/search/scopus" );

my $NS_CTO        = 'http://www.elsevier.com/xml/cto/dtd';
my $NS_ATOM       = 'http://www.w3.org/2005/Atom';
my $NS_PRISM      = 'http://prismstandard.org/namespaces/basic/2.0/';
my $NS_OPENSEARCH = 'http://a9.com/-/spec/opensearch/1.1/';
my $NS_DC         = 'http://purl.org/dc/elements/1.1/';

#
# Create a new plug-in object.
#
sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = "Scopus Citation Ingest";

    # get the developer key
    $self->{dev_id} = $self->{session}->get_conf( "scapi", "developer_id" );
    if( !defined( $self->{dev_id} ) )
    {
	$self->{error}   = 'Unable to load the Scopus developer key.';
	$self->{disable} = 1;
	return $self;
    }

    # An ordered list of the methods for generating querystrings
    $self->{queries} = [
	qw{
	  _get_querystring_eid
	  _get_querystring_doi
	  _get_querystring_metadata
	  }
    ];
    $self->{current_query} = -1;

    return $self;
}

#
# Test whether or not this plug-in can hope to retrieve data for a given eprint.
#
sub can_process
{
    my( $plugin, $eprint ) = @_;

    if( $eprint->is_set( "scopus_cluster" ) )
    {
	# do not process eprints with EID set to "-"
	return 0 if $eprint->get_value( "scopus_cluster" ) eq "-";

	# otherwise, we can use the existing EID to retrieve data
	return 1;
    }

    # we can retrieve data if this eprint has a (usable) DOI
    return 1 if( $eprint->is_set( "id_number" ) && is_usable_doi( $eprint->get_value( "id_number" ) ) );

    # Scopus doesn't contain data for the following types
    my $type = $eprint->get_value( "type" );
    return 0 if $type eq "thesis";
    return 0 if $type eq "other";

    # otherwise, we can (try to) retrieve data if this eprint has a title and authors
    return $eprint->is_set( "title" ) && $eprint->is_set( "creators_name" );
}

#
# Returns an epdata hashref for a citation datum for $eprint or undef
# if no matches were found in the citation service.
#
# Croaks if there are problems receiving or parsing responses from the
# citation service, or if the citation service returns an error
# response.
#
sub get_epdata
{
    my( $plugin, $eprint ) = @_;

    my $eprintid = $eprint->get_id();

    # Repeatedly query the citation service until a matching record is
    # found or all query methods have been tried without success.
    my $response_xml;
    my $found_a_match = 0;
    $plugin->_reset_query_methods();
  QUERY_METHOD: while( !$found_a_match && defined $plugin->_next_query_method() )
    {
	my $search = $plugin->_get_query( $eprint );
	next QUERY_METHOD if( !defined $search );

	# build the URL from which we can download the data
	my $quri = $plugin->_get_query_uri( $search );

	# Repeatedly query the citation service until a response is
	# received or max allowed network requests has been reached.
	my $response = $plugin->_call( $quri, $plugin->{net_retry}->{max}, $plugin->{net_retry}->{interval} );

	if( !defined( $response ) )
	{
	    # Out of quota. Give up!
	    die( "Aborting Scopus citation imports." );
	}

	my $body = $response->content;
	my $code = $response->code;
	if( !$body )
	{
	    $plugin->warning( "No or empty response from Scopus for EPrint ID $eprintid [$code]" );
	    next QUERY_METHOD;
	}

	# Got a response, now try to parse it
	my $xml_parser = $plugin->{session}->xml;

	my $status_code;
	my $status_detail;

	eval {
	    $response_xml = $xml_parser->parse_string( $body );
	    1;
	}
	or do
	{
	    # Workaround for malformed XML error responses --
	    # parse out the status code and detail using regexes
	    $plugin->warning( "Received malformed XML error response {$@}" );
	    if( $body =~ m/<statusCode[^>]*>(.+?)<\/statusCode>/g )
	    {
		$status_code = $1;
	    }
	    if( $body =~ m/<statusText[^>]*>(.+?)<\/statusText>/g )
	    {
		$status_detail = $1;
	    }
	    if( $status_code || $status_detail )
	    {
		$status_code   ||= '-';
		$status_detail ||= '-';
		$plugin->error( "Scopus responded with error condition for EPrint ID $eprintid: [$code] $status_code, $status_detail, Request URL: " . $quri->as_string );
	    }
	    else
	    {
		$plugin->warning( "Unable to parse response XML for EPrint ID $eprintid: [$code] Request URL: ". $quri->as_string . "\n$body" );
	    }
	    next QUERY_METHOD;
	};

	if( $code != 200 )
	{
	    # Don't die on errors because these may be caused by data
	    # specific to a given eprint and dying would prevent
	    # updates for the remaining eprints
	    ( $status_code, $status_detail ) = $plugin->get_response_status( $response_xml );
	    if( $status_code || $status_detail )
	    {
		$status_code   ||= '-';
		$status_detail ||= '-';
		$plugin->error( "Scopus responded with error condition for EPrint ID $eprintid: [$code] $status_code, $status_detail, Request URL: " . $quri->as_string );
	    }
	    else
	    {
		$plugin->error( "Scopus responded with unknown error condition for EPrint ID $eprintid: [$code] Request URL: " .
				$quri->as_string . "\n" . $response_xml->toString );
	    }
	    next QUERY_METHOD;
	}

	$found_a_match = ( $plugin->get_number_matches( $response_xml ) > 0 );

    }    # End QUERY_METHOD

    return undef if( !$found_a_match );

    return $plugin->response_to_epdata( $response_xml, $eprint->get_value( "scopus_cluster" ) );
}

#
# Select the next query method. Returns the
# zero-based index thereof, or undef if all query options are
# exhausted.
#
# By default these return undef, so concrete plugins don't need to
# override.
#
sub _next_query_method
{
    my( $plugin ) = @_;
    if( $plugin->{current_query} >= ( scalar @{ $plugin->{queries} } - 1 ) )
    {
	$plugin->{current_query} = undef;
	return undef;
    }
    return $plugin->{current_query}++;
}

#
# Start iterating through the list of query methods again.
#
# next_query_method() must be called before the next query after a
# call to this.
#
sub _reset_query_methods
{
    my( $plugin ) = @_;
    $plugin->{current_query} = -1;
    return;
}

#
# Return the query string from the current query method or undef if it
# can't be created, e.g., if the eprint doesn't have the required
# metadata for that query.
#
sub _get_query
{
    my( $plugin, $eprint ) = @_;
    my $query_generator_fname = $plugin->{queries}->[ $plugin->{current_query} ];
    return $plugin->$query_generator_fname( $eprint );
}

#
# Query methods return a valid query string or undef if the string
# couldn't be generated.
#

sub _get_quoted_param
{
    my( $plugin, $string, $exact ) = @_;

    # Decompose ligatures into component characters - Scopus doesn't
    # match ligatures. Note, this is a compatibility normalisation
    # that changes characters and potentially this could change the
    # string sufficiently so that Scopus won't find a match.
    $string = NFKC( $string ) // '';

    # If there are any "unsimple" characters, wrap the whole deal
    # in quotes.  Just in case.
    if( $string =~ /[^A-Z0-9\/.-]/i )
    {
	# Experimentation shows that percent signs cause a GENERAL_SYSTEM_ERROR
	# in the server.  In that case, return a best-effort (non-exact) query
	# that strips them as punctuation.
	#
	# Similary, ampersands seem to be unsearchable, and are handled explicitly
	# when creating a non-exact query (below).
	#
	if( $exact && $string !~ /{}%&/ )
	{
	    $string = '{' . $string . '}';
	}
	else
	{
	    # When searching for a loose or approximate phrase (using double-quotation
	    # marks) punctuation is ignored.
	    #   <http://api.elsevier.com/documentation/search/SCOPUSSearchTips.htm>
	    #
	    # Experimentation shows that ampersands are often replaced with the word
	    # 'and' in stored metadata, but in some cases (e.g. "S&P 500") they are an
	    # integral part of the token.  Our best effort in this case is to explode
	    # the string on all words-that-include-ampersands.
	    #   e.g: ("a x&y b & c") => ("a" "b c")

	    $string =~ s/[^\pL\pN&]+/ /g;        # strip all punctuation, except '&'

	    $string =~ s/(^| )&( |$)/ /g;        # isolated ampersands can be removed
	    $string =~ s/\S*&\S*/" "/g;          # explode tokens with ampersands in them
	    $string =~ s/^( ?"")? | ("" ?)?$//g; # clean up

	    $string = '"' . $string . '"';
	}
    }

    return $string;
}

sub _get_querystring_eid
{
    my( $plugin, $eprint ) = @_;
    return undef if(   !$eprint->is_set( 'scopus_cluster' )
		     || $eprint->get_value( 'scopus_cluster' ) eq '-' );
    return 'eid(' . $plugin->_get_quoted_param( $eprint->get_value( 'scopus_cluster' ), 1 ) . ')';
}

sub _get_querystring_doi
{
    my( $plugin, $eprint ) = @_;
    return undef if(    !$eprint->is_set( 'id_number' )
		     || !is_usable_doi( $eprint->get_value( 'id_number' ) ) );
    return 'doi(' . $plugin->_get_quoted_param( $eprint->get_value( 'id_number' ), 1 ) . ')';
}

sub _get_querystring_metadata
{
    my( $plugin, $eprint ) = @_;

    # search using title and first author

    my $query = 'title(' . $plugin->_get_quoted_param( $eprint->get_value( 'title' ) ) . ')';

    my @authors = @{ $eprint->value( 'creators_name' ) || [] };
    if( scalar( @authors ) > 0 )
    {
	my $authlastname = $authors[ 0 ]->{family};
	$query .= ' AND authlastname(' . $plugin->_get_quoted_param( $authlastname ) . ')';
    }

    if( $eprint->is_set( 'date' ) )
    {
	# limit by publication year
	my $pubyear = substr( $eprint->get_value( 'date' ), 0, 4 );
	$query .= " AND pubyear is $pubyear";
    }

    return $query;
}

#
# Return the content of the status/statusCode and status/statusText elements
# from an error response
#
sub get_response_status
{
    my( $plugin, $response_xml ) = @_;

    my $status = $response_xml->documentElement->getChildrenByTagName( 'status' )->[ 0 ];
    return ( $status->getChildrenByTagName( 'statusCode' )->[ 0 ]->textContent,
	     $status->getChildrenByTagName( 'statusText' )->[ 0 ]->textContent, );
}

#
# Return the number of records matched and returned in $response_xml
#
sub get_number_matches
{
    my( $plugin, $response_xml ) = @_;

    my $totalResults = $response_xml->getElementsByTagNameNS( $NS_OPENSEARCH, "totalResults" )->[ 0 ];

    return 0 if !defined $totalResults;
    return $totalResults->textContent + 0;
}

#
# Convert the response from Scopus into an "epdata" hash.
#
# Assumes that this is response returned a 200 OK response and
# there were matches to the query.
#
sub response_to_epdata
{
    my( $plugin, $response_xml, $fallback_cluster ) = @_;

    my $record = shift @{ $response_xml->getElementsByTagNameNS( $NS_ATOM, "entry" ) };

    my $eid = shift @{ $record->getElementsByLocalName( "eid" ) };
    if( !defined $eid )
    {
	$plugin->error( "Scopus responded with no 'eid' in entry, fallback='$fallback_cluster'. XML:\n" . $response_xml->toString );
    }

    my $cluster = $fallback_cluster;
    eval { $cluster = $eid->textContent };

    if( $fallback_cluster && $cluster ne $fallback_cluster )
    {
	# This is a fatal error -- either we have the wrong eid stored in the database,
	# or Scopus returned citation counts for the wrong record.  Either way, manual
	# intervention will be required.
	$plugin->error( "Scopus returned an 'eid' {$cluster} that doesn't match the existing one {$fallback_cluster}" );
	return undef;
    }

    my $citation_count = shift @{ $record->getElementsByLocalName( "citedby-count" ) };
    return { cluster => $cluster,
	     impact  => $citation_count->textContent
    };
}

sub _log_response
{
    my( $plugin, $uri, $response ) = @_;

    my $message = 'Unable to retrieve data from Scopus. ';

    # Set by LWP::UserAgent if the error happens client-side (e.g. while connecting)
    my $client_warning = $response->header('Client-Warning');
    if( $client_warning && $client_warning eq 'Internal response' )
    {
	$message .= 'Failed with status: ';
    }
    else
    {
	$message .= 'The response was: ';
    }

    # Always include the '400 Bad Request' line, or whatever it says
    $message .= $response->status_line;

    # Set by LWP::UserAgent if the callback die()ed.
    my $reason = $response->header('X-Died');
    if( $reason )
    {
	$message .= " ($reason)";
    }

    # Add the actual URI, for debugging purposes.
    $message .= " [$uri]";

    $plugin->warning( $message );
}

#
# Make an HTTP GET request to $uri and return the response. Will retry
# up to $max_retries times after $retry_delay in the event of a
# failure.
#
sub _call
{
    my( $plugin, $uri, $max_retries, $retry_delay ) = @_;

    my $ua = LWP::UserAgent->new( conn_cache => $plugin->{conn_cache} );
    $ua->env_proxy;
    $ua->timeout( 15 );

    my $response       = undef;
    my $net_tries_left = $max_retries + 1;
    while( !defined $response && $net_tries_left > 0 )
    {
	$response = $ua->get( $uri );

	# Quota exceeded - abort
	if( $response->code == 429 )
	{
	    $plugin->_log_response( $uri, $response );
	    return undef;
	}

	# Some other failure.  Log it, wait a bit, and try again.
	if( !$response->is_success )
	{
	    # TODO: explicitly handle responses
	    #   400 - invalid information (?)
	    #   401 - authentication error
	    #   403 - bad auth/entitlements
	    #   405 - invalid HTTP method !?
	    #   406 - invalid content-type !?
	    #   429 - (handled above)
	    #   500 - (probably transient) ??
	    $plugin->_log_response( $uri, $response );
	    $net_tries_left--;
	    if( $net_tries_left > 0 && $retry_delay > 0 )
	    {
		# go to sleep before trying again
		$plugin->warning( "Waiting $retry_delay seconds before trying again." );
		sleep( $retry_delay );
	    }
	}
    }
    return $response;
}

#
# Return 1 if a given DOI is usable for searching Scopus, or 0 if it is not.
#
# Ideally, we would be able to encode all DOIs in such a manner as to make them
# acceptable to Scopus. However, we do not have any documentation as to how
# problem characters might be encoded, or even any assurance that it is
# possible at all.
#
sub is_usable_doi
{
    my( $doi ) = @_;

    return 0 if( !EPrints::Utils::is_set( $doi ) );

    $doi =~ s!^https?://(dx\.)?doi\.org/!!i;
    $doi =~ s!^doi:!!i;

    return 0 if( $doi !~ m!^10\.[^/]+/! );

    return 1;
}

sub _get_query_uri
{
    my( $plugin, $search ) = @_;

    my $quri = $SEARCHAPI->clone;
    $quri->query_form( httpAccept => 'application/xml',
		       apiKey     => $plugin->{dev_id},
		       query      => $search,
    );
    return $quri;
}

1;

# vim: set ts=8 sts=4 sw=4 :

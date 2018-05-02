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
# Copyright 2018 Queensland University of Technology. All Rights Reserved.
#
#  This file is part of the Citation Count Dataset and Import Plug-ins for GNU
#  EPrints 3.
#
#  Copyright (c) 2018 Queensland University of Technology, Queensland, Australia
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
our @ISA = ( 'EPrints::Plugin::Import::CitationService' );

use LWP::UserAgent;
use Unicode::Normalize qw(NFKC);
use URI;

our $SEARCHAPI = URI->new( 'http://api.elsevier.com/content/search/scopus' );

my $NS_CTO        = 'http://www.elsevier.com/xml/cto/dtd';
my $NS_ATOM       = 'http://www.w3.org/2005/Atom';
my $NS_PRISM      = 'http://prismstandard.org/namespaces/basic/2.0/';
my $NS_OPENSEARCH = 'http://a9.com/-/spec/opensearch/1.1/';
my $NS_DC         = 'http://purl.org/dc/elements/1.1/';

##
# Create a new plug-in object.
#
sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = 'Scopus Citation Ingest';

    # Enable/Disable search by metadata?
    $self->{metadata_search} = $self->{session}->get_conf( 'scapi', 'metadata_search' ) // 1;

    # Types of records to not look up in Scopus.
    $self->{blacklist_types} = $self->{session}->get_conf( 'scapi', 'blacklist_types' );
    if( !defined( $self->{blacklist_types} ) )
    {
	$self->{blacklist_types} = [ qw[ thesis other ] ];
    }

    # get the developer key
    $self->{dev_id} = $self->{session}->get_conf( 'scapi', 'developer_id' );
    if( !defined( $self->{dev_id} ) )
    {
	$self->{error}   = 'Unable to load the Scopus developer key.';
	$self->{disable} = 1;
	return $self;
    }

    # Plugin-specific net_retry parameters (command line > config > default)
    my $default_net_retry = $self->{session}->get_conf( 'scapi', 'net_retry' );
    $default_net_retry->{max}      //= 4;
    $default_net_retry->{interval} //= 30;
    foreach my $k ( keys %{$default_net_retry} )
    {
	$self->{net_retry}->{$k} //= $default_net_retry->{$k};
    }

    # Other configurable parameters
    $self->{doi_field} = $self->{session}->get_conf( 'scapi', 'doi_field' ) || 'id_number';

    return $self;
}

##
# Test whether or not this plug-in can hope to retrieve data for a given eprint.
#
# @param $plugin this plugin object
# @param $eprint the EPrint data object to test
# @return ($) 0 or 1
#
sub can_process
{
    my( $plugin, $eprint ) = @_;
    return $plugin->_query_method_for( $eprint ) ? 1 : 0;
}

#------- BUILD QUERY

##
# Pick the query method for the given eprint.  There can be only one.
# Returns undef is there isn't one.
#
# @param $plugin this plugin object
# @param $eprint the EPrint data object for which to generate a query string
# @return ($)  the name of the best subroutine to use to generate a query
#              string for $eprint, or undef
#
sub _query_method_for
{
    my( $plugin, $eprint ) = @_;

    # Having a scopus cluster (EID) trumps all other considerations.
    if( $eprint->is_set( 'scopus_cluster' ) )
    {
	# do not process eprints with EID set to '-'
	return undef if $eprint->get_value( 'scopus_cluster' ) eq '-';

	# otherwise, we can use the existing EID to retrieve data
	return '_get_querystring_eid';
    }

    # Scopus doesn't contain data for these types, or we don't want
    # to look them up.
    my $type = $eprint->get_value( 'type' );
    return undef if grep { $type eq $_ } @{ $self->{blacklist_types} };

    # we can retrieve data if this eprint has a (usable) DOI
    return '_get_querystring_doi'
      if( $eprint->is_set( $plugin->{doi_field} ) && is_usable_doi( $eprint->get_value( $plugin->{doi_field} ) ) );

    # Don't do any metadata searches if not configured to do so.
    return undef unless $plugin->{metadata_search};

    # otherwise, we can (try to) retrieve data if this eprint has a title and authors
    return undef unless $eprint->is_set( 'title' ) && $eprint->is_set( 'creators_name' );
    return '_get_querystring_metadata';
}

##
# Generate query string for searching by EID.
#
sub _get_querystring_eid
{
    my( $plugin, $eprint ) = @_;
    return undef if(   !$eprint->is_set( 'scopus_cluster' )
		     || $eprint->get_value( 'scopus_cluster' ) eq '-' );
    return 'eid(' . $plugin->_get_quoted_param( $eprint->get_value( 'scopus_cluster' ), 1 ) . ')';
}

##
# Generate query string for searching by DOI.
#
sub _get_querystring_doi
{
    my( $plugin, $eprint ) = @_;
    return undef unless $eprint->is_set( $plugin->{doi_field} );

    my $doi = is_usable_doi( $eprint->get_value( $plugin->{doi_field} ) );
    return undef unless $doi;
    return 'doi(' . $plugin->_get_quoted_param( $doi, 1 ) . ')';
}

##
# Generate query string for searching by metadata.
# Uses title, creators_name (if present), date (if present).
#
# Can be disabled by setting `$c->{scapi}->{metadata_search} = 0;`
#
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

##
# Escape a query parameter so it will be more acceptable to Scopus.
#
# @param $plugin this plugin object
# @param $string the parameter to escape
# @param $exact  if given and true, attempt to quote $string literally
# @return ($) the quoted parameter string
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

	    $string =~ s/[^\pL\pN&]+/ /g;    # strip all punctuation, except '&'

	    $string =~ s/(^| )&( |$)/ /g;    # isolated ampersands can be removed
	    $string =~ s/\S*&\S*/" "/g;      # explode tokens with ampersands in them
	    $string = '"' . $string . '"';          # wrap in quotes
	    $string =~ s/^(" *" )+|( " *")+$//g;    # clean up leading/trailing empty quotes
	}
    }

    return $string;
}

##
# Given a candidate DOI string, return a sanitised version or undef.
#
# Ideally, we would be able to encode all DOIs in such a manner as to make them
# acceptable to Scopus. However, we do not have any documentation as to how
# problem characters might be encoded, or even any assurance that it is
# possible at all.
#
# @param $doi a candidate DOI string
# @return ($) the sanitised version of the DOI as a string, if it's valid;
#             otherwise undef
#
sub is_usable_doi
{
    my( $doi ) = @_;

    return undef if( !EPrints::Utils::is_set( $doi ) );

    if( eval { require EPrints::DOI; } )
    {
	$doi = EPrints::DOI->parse( $string );
	return $doi ? $doi->to_string( noprefix => 1 ) : undef;
    }
    else
    {
	# dodgy fallback

	$doi = "$doi";
	$doi =~ s!^https?://+(dx\.)?doi\.org/+!!i;
	$doi =~ s!^info:(doi/+)?!!i;
	$doi =~ s!^doi:!!i;

	return undef if( $doi !~ m!^10\.[^/]+/! );

	return $doi;
    }
}

##
# Build a URI object from the given search parameter.
# Uses global $SEARCHAPI, and the `dev_id` config param.
#
# @param $plugin this plugin object
# @param $search a search parameter (string)
# @return ($) a URI object
#
sub _get_query_uri
{
    my( $plugin, $search ) = @_;

    my $quri = $SEARCHAPI->clone;
    $quri->query_form(
		       httpAccept => 'application/xml',
		       apiKey     => $plugin->{dev_id},
		       query      => $search,
    );
    return $quri;
}

#------- Execute query

##
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

    # Which method do we use to fetch citation counts?
    my $method = $plugin->_query_method_for( $eprint );
    if( !$method )
    {
	$plugin->error( "Attempting to lookup EPrint $eprintid but I don't know how!" );
	return undef;
    }

    my $response_xml;
    my $search = $plugin->$method( $eprint );
    if( !$search )
    {
	$plugin->error( "Unable to generate query for EPrint $eprintid using $method" );
	return undef;
    }

    my $quri = $plugin->_get_query_uri( $search );

    # Repeatedly query the citation service until a response is
    # received or max allowed network requests has been reached.
    my $response = $plugin->_call( $quri, $plugin->{net_retry}->{max}, $plugin->{net_retry}->{interval} );

    if( !defined( $response ) )
    {
	# Out of quota. Give up!
	die( 'Aborting Scopus citation imports.' );
    }

    my $body = $response->content;
    my $code = $response->code;
    if( !$body )
    {
	$plugin->error( "No or empty response from Scopus for EPrint $eprintid [$code]" );
	return undef;
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
	    $plugin->warning( "Unable to parse response XML for EPrint ID $eprintid: [$code] Request URL: " . $quri->as_string . "\n$body" );
	}
	return undef;
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
	    $plugin->error( "Scopus responded with unknown error condition for EPrint ID $eprintid: [$code] Request URL: " . $quri->as_string . "\n" . $response_xml->toString );
	}
	return undef;
    }

    return $plugin->response_to_epdata( $response_xml, $eprint );
}

#------- Response handling

##
# Return the content of the status/statusCode and status/statusText elements
# from an error response
#
# @param $plugin this plugin object
# @param $response_xml the XML structure to interrogate
# @return ($,$) status code and description
#
sub get_response_status
{
    my( $plugin, $response_xml ) = @_;

    my $status = $response_xml->documentElement->getChildrenByTagName( 'status' )->[ 0 ];
    return ( $status->getChildrenByTagName( 'statusCode' )->[ 0 ]->textContent, $status->getChildrenByTagName( 'statusText' )->[ 0 ]->textContent, );
}

# ##
# # Return the number of records matched and returned in $response_xml
# #
# sub get_number_matches
# {
#     my( $plugin, $response_xml ) = @_;
#
#     my $totalResults = $response_xml->getElementsByTagNameNS( $NS_OPENSEARCH, "totalResults" )->[ 0 ];
#
#     return 0 if !defined $totalResults;
#     return $totalResults->textContent + 0;
# }

##
# Convert the response from Scopus into an "epdata" hash.
#
# Assumes that this is response returned a 200 OK response and
# there were matches to the query.
#
# @param $plugin this plugin object
# @param $response_xml the XML object to interrogate
# @param $eprint the EPrint data object the query was about
# @return {cluster=>$,impact=>$} the EID and citation count
#
sub response_to_epdata
{
    my( $plugin, $response_xml, $eprint ) = @_;

    my $eprintid         = $eprint->id;
    my $fallback_cluster = $eprint->get_value( 'scopus_cluster' );

    my $record = shift @{ $response_xml->getElementsByTagNameNS( $NS_ATOM, "entry" ) };

    my $cluster = $fallback_cluster;

    my $eid = shift @{ $record->getElementsByLocalName( "eid" ) };
    if( !defined $eid )
    {
	if( $fallback_cluster )
	{
	    $plugin->error( "Scopus responded with no 'eid' in entry for $eprintid, fallback='$fallback_cluster'. XML:\n" . $response_xml->toString );
	}
	else
	{
	    $plugin->error( "Scopus responded with no 'eid' in entry for $eprintid, and there is no fallback. XML:\n" . $response_xml->toString );
	    return undef;
	}
    }
    else
    {
	$cluster = $eid->textContent;
    }

    if( $fallback_cluster && $cluster ne $fallback_cluster )
    {
	# This is a fatal error -- either we have the wrong eid stored in the database,
	# or Scopus returned citation counts for the wrong record.  Either way, manual
	# intervention will be required.
	$plugin->error( "Scopus returned an 'eid' {$cluster} for $eprintid that doesn't match the existing one {$fallback_cluster}" );
	return undef;
    }

    my $citation_count = shift @{ $record->getElementsByLocalName( 'citedby-count' ) };
    return {
	     cluster => $cluster,
	     impact  => $citation_count->textContent
    };
}

sub _log_response
{
    my( $plugin, $uri, $response ) = @_;

    my $message = 'Unable to retrieve data from Scopus. ';

    # Set by LWP::UserAgent if the error happens client-side (e.g. while connecting)
    my $client_warning = $response->header( 'Client-Warning' );
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
    my $reason = $response->header( 'X-Died' );
    if( $reason )
    {
	$message .= " ($reason)";
    }

    # Add the actual URI, for debugging purposes.
    $message .= " [$uri]";

    $plugin->warning( $message );
}

sub _is_fatal
{
    my( $code ) = @_;

    # This treats buggy-looking responses (405,406,500)
    # as (probably) transient.

    # Documented response codes:
    #  400 - invalid information
    #  401 - authentication error
    #  403 - bad auth/entitlements
    #  405 - invalid HTTP method -- bug?
    #  406 - invalid content-type -- bug?
    #  429 - quota exceeded
    #  500 - bug
    return grep { $_ == $code } ( 400, 401, 403, 429 );
}

##
# Make an HTTP GET request to $uri and return the response. Will retry
# up to $max_retries times after $retry_delay in the event of a
# failure.
#
# @param $plugin this plugin object
# @param $uri    where to send the request
# @param $max_retries how many times to try again after a non-fatal error
# @param $retry_delay how long to wait (seconds) between retries
# @return ($) a HTTP::Response object, or undef if we ran out of quota
#
sub _call
{
    my( $plugin, $uri, $max_retries, $retry_delay ) = @_;

    my $ua = LWP::UserAgent->new( conn_cache => $plugin->{conn_cache} );
    $ua->env_proxy;
    $ua->timeout( 15 );
    $ua->default_header( 'X-ELS-APIKey' => $plugin->{dev_id} );
    $ua->default_header( 'Accept'       => 'application/xml' );

    my $response       = undef;
    my $net_tries_left = $max_retries + 1;
    while( !defined $response && $net_tries_left > 0 )
    {
	$response = $ua->get( $uri );

	# Quota exceeded -- abort
	if( $response->code == 429 )
	{
	    $plugin->_log_response( $uri, $response );
	    return undef;
	}

	# Some other failure.  Log it, wait a bit, and try again.
	if( !$response->is_success )
	{
	    $plugin->_log_response( $uri, $response );

	    # give up on this eprint if things are too weird
	    return $response if _is_fatal( $response->code );

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

1;

# vim: set ts=8 sts=4 sw=4 :

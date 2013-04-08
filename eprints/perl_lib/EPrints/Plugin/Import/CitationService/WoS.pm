package EPrints::Plugin::Import::CitationService::WoS;
###############################################################################
#
# Web of Science citation ingest.
#
# This plug-in will retrieve citation data from Web of Science Web Services
# Lite. This data should be stored in the "wos" dataset.
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
#
# December 2012 / sf2:
#
# - Added support for v3 of the WoK API
# - Added support for Lite or Premium accounts
# - Possibility to locally (re-)define the Editions to search
# - Added support for the maximum number of requests per second (2) and per session (10,000)
#
######################################################################


use strict;

use Data::Dumper;
use HTTP::Cookies;
use Text::Unidecode;

# un-comment if you need to debug the SOAP messages:
# use SOAP::Lite +'trace';

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

# service endpoints and namespaces - these can be locally defined (e.g. if you have a Premium account)
our $WOK_CONF = {
	'AUTHENTICATE_ENDPOINT' => 'http://search.webofknowledge.com/esti/wokmws/ws/WOKMWSAuthenticate',
	'AUTHENTICATE_NS' => 'http://auth.cxf.wokmws.thomsonreuters.com',
	'WOKSEARCH_ENDPOINT' => 'http://search.webofknowledge.com/esti/wokmws/ws/WokSearchLite',
	'WOKSEARCH_NS' => 'http://woksearch.cxf.wokmws.thomsonreuters.com',
	'SERVICE_TYPE' => 'woksearchlite',
};

# the database editions to search. These can be locally defined, see "sub new()".
our $EDITIONS = [qw/ SCI SSCI AHCI IC CCR ISTP ISSHP /];

# the SOAP structures - will be built at run-time
our $SOAP_EDITIONS = [];

#
# Create a new plug-in object.
#
sub new
{
	my ( $class, %params ) = @_;

	my $self = $class->SUPER::new( %params );

	# set some parameters
	$self->{name} = "Web of Science Citation Ingest";

	# load the necessary Perl libraries
	if( !EPrints::Utils::require_if_exists( "SOAP::Lite" ) )
	{
		$self->{error} = 'Unable to load required module SOAP::Lite';
		$self->{disable} = 1;
		return $self;
	}

	if( defined $self->{session} )
	{
		foreach my $confid ( keys %$WOK_CONF )
		{
			if( defined $self->{session}->config( 'wos', $confid ) )
			{
				# locally defined?
				$WOK_CONF->{$confid} = $self->{session}->config( 'wos', $confid );
			}
		}

		# Editions
		my $local_editions = $self->{session}->config( 'wos', 'editions' );
		if( EPrints::Utils::is_set( $local_editions ) )
		{
			$EDITIONS = EPrints::Utils::clone( $local_editions );
		}

		$self->{max_requests} = $self->{session}->config( 'wos', 'max_requests_per_session' );
	}

	$self->{max_requests} ||= 10_000;

	# this hash will hold the query parameters that are the same for every request
	$self->{query} = {};

	# the databaseID or databaseId is always "WOS" (case is important in SOAP)
	$self->{query}->{databaseId} = SOAP::Data->name( "databaseId" => "WOS" );

	foreach my $edition ( @$EDITIONS )
	{
		push @$SOAP_EDITIONS, SOAP::Data->name( "editions" => \SOAP::Data->value(
			SOAP::Data->name( "collection" => "WOS" ),
			SOAP::Data->name( "edition" => "$edition" ),
 	       ) );
	}

	# the query language is always English
	$self->{query}->{queryLanguage} = SOAP::Data->name( "queryLanguage" => "en" );

	# sf2 - counting the number of requests made - see "sub call()" at the end of this file
	$self->{requests} = 0;

	return $self;
}


#
# This plug-in only retrieves data for journal articles and conference paper
# with titles and authors
#
sub can_process
{
	my ( $plugin, $eprint ) = @_;

	if ( $eprint->is_set( "wos_cluster" ) )
	{
		# do not process eprints with ID set to "-"
		return 0 if $eprint->get_value( "wos_cluster" ) eq "-";

		# otherwise, we can use the existing UT to retrieve data
		return 1;
	}

	# Web of Science doesn't contain data for the following types
	my $type = $eprint->get_value( "type" );
	return 0 if $type eq "thesis";
	return 0 if $type eq "other";

	# otherwise, we can (try to) retrieve data if this eprint has a title and authors
	return $eprint->is_set( "title" ) && $eprint->is_set( "creators_name" );
}


#
# Get the response from Web of Science for a given eprint.
#
sub get_response
{
	my ( $plugin, $eprint ) = @_;

	# ensure that we have a WoS session
	if ( !defined( $plugin->{session_id} ) )
	{
		if ( !$plugin->get_session )
		{
			return undef;
		}
	}

	# build a SOAP object for this session
	my $soap = SOAP::Lite->new(
		proxy => $WOK_CONF->{WOKSEARCH_ENDPOINT},
		autotype => 0,
	);
	$soap->transport->http_request->header( "Cookie" => "SID=\"" . $plugin->{session_id} . "\";" );

	# get the WoS identifier ("UT") for this eprint
	my $ut;
	if ( $eprint->is_set( "wos_cluster" ) )
	{
		# we already know the identifier
		$ut = $eprint->get_value( "wos_cluster" );
	}
	else
	{
		# search for the WoS record for this eprint
		my $search = $plugin->get_search_for_eprint( $eprint, $soap );
		return undef if !defined( $search );
		return {} if ( scalar keys %{$search} == 0 );

		# extract the identifier from the response
		$ut = $plugin->get_identifier_from_search( $search, $eprint );
		if ( !defined( $ut ) )
		{
			$plugin->warning( "Could not parse search results for EPrint ID " . $eprint->get_id );
			return undef;
		}

		# return an empty response if the search didn't find any records
		return {} if ( $ut eq "" );
	}

	# search for the articles that cite this identifier, or return empty
	return $plugin->get_cites_for_identifier( $eprint, $ut, $soap );
}


#
# Search for a particular eprint on Web of Science. Returns the result of
# the call (i.e. SOAP::SOM->result), an empty hash if there was a SOAP
# fault, or undef if there was a network error.
#
# $soap should be a SOAP object that will call the $WOKSEARCH_ENDPOINT,
# and contains the session identifier for the session in which this
# request is made.
#
sub get_search_for_eprint
{
	my ( $plugin, $eprint, $soap ) = @_;

	# build a query string that will (hopefully) locate the eprint in WoS
	my $ti = $eprint->get_value( "title" );
	$ti =~ s/[^\p{Latin}\p{Number}]+/ /g; # WoS doesn't like punctuation
	my $creator = @{$eprint->get_value( "creators_name" )}[0];
	my $au = $creator->{family} . ", " . substr( $creator->{given}, 0, 1 ) . "*";
	$au =~ s/[-\'\x{2019}]/\*/g; # WoS is inconsistent with - and '
	my $q = "AU=($au) AND TI=(\"$ti\")";
	my $py;
	if ( $eprint->is_set( "date" ) )
	{
		$py = substr( $eprint->get_value( "date" ), 0, 4 );
		$q = $q . " AND PY=$py";
	}
	$q = unidecode($q); # Reduce any unicode characters to plain old ASCII. Strips diacritics, splits digraphs, etc.

	# the record could appear either the year before, the year, or the year after it was published
	my $date_begin = "1900-01-01";
	my $date_end = substr( EPrints::Time::get_iso_timestamp(), 0, 10 );
	if ( $eprint->is_set( "date" ) )
	{
		$date_begin = ( $py - 1 ) . "-01-01";
		$date_end = ( $py + 1) . "-12-31";
	}
	my $date_param = SOAP::Data->name( "timeSpan" => \SOAP::Data->value(
		SOAP::Data->name( "begin" )->value( $date_begin ),
		SOAP::Data->name( "end" )->value( $date_end )
	) );

	# search WoS for the eprint
	my $query_params = SOAP::Data->value(
		$plugin->{query}->{databaseId},
		SOAP::Data->name( "userQuery" => $q ),
		@$SOAP_EDITIONS,
		$date_param,
		$plugin->{query}->{queryLanguage},
	);

	# sf2 / TODO: v3 has a new format for fields (viewFields, sortFields)
	my $retrieve_params = SOAP::Data->value(
		SOAP::Data->name( "firstRecord" => "1" ),
		SOAP::Data->name( "count" => "10" ),
#		SOAP::Data->name( "fields" => \SOAP::Data->value(
#			SOAP::Data->name( "name" )->value( "Date" ),
#			SOAP::Data->name( "sort" )->value( "D" )
#		) ),
	);
	my $som;
	eval {
		my @params;
		push @params, SOAP::Data->name( "queryParameters" => \$query_params );
		push @params, SOAP::Data->name( "retrieveParameters" => \$retrieve_params );

		my $service = $WOK_CONF->{SERVICE_TYPE};

		# $som = $soap->call( SOAP::Data->name( "$service:search" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );
		$som = $plugin->call( $soap, SOAP::Data->name( "$service:search" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );
		1;
	}
	or do
	{
		$plugin->warning( "Unable to connect to the search service for EPrints ID " . $eprint->get_id . ": " . $@ );
		return undef;
	};
	if ( $som->fault )
	{
		$plugin->warning( "Unable to retrieve record for EPrint ID " . $eprint->get_id . " from Web of Science: " . $som->faultstring );
		return {};
	}

	return $som->result;
}
	

#
# Extract WoS' identifier for a paper from the search results for it.
# Returns an empty string if the search results do not contain any records,
# and undef if the search results can't be parsed.
#
# $search should be the output of SOAP::SOM::result() on the SOAP
# message object received from the "search" call.
#
sub get_identifier_from_search
{
	my ( $plugin, $search, $eprint ) = @_;

	# sanity check
	if ( !defined( $search->{recordsFound} ) )
	{
		return undef;
	}

	# extract the identifier ("UT")
	if ( $search->{recordsFound} > 0 )
	{
		# sanity check
		if ( !defined( $search->{records} ) )
		{
			return undef;
		}

		# the 'record' is string encapsulated in XML, so we need to parse it
		# We're looking for: <UID>WOS:(\d+)</UID> (the tag used to be <UT> in previous API versions)
		if ( $search->{recordsFound} == 1 )
		{
			# only one match; return that record

			my $doc;
			eval {
				$doc = $plugin->{session}->xml->parse_string( $search->{records} );
			};
			if( !defined $doc || $@ )
			{
				$plugin->warning( 'Failed to parse Record XML' );
				return "";
			}
			else
			{
				my @tags = $doc->getElementsByTagName( 'UID' );
				if( scalar( @tags ) )
				{
					return $tags[0]->textContent;
				}
			}
			return "";
		}

		my $doc;
		eval {
			$doc = $plugin->{session}->xml->parse_string( $search->{records} );
		};
		if( !defined $doc || $@ )
		{
			$plugin->warning( 'Failed to parse Record XML' );
			return "";
		}

		my $uctitle = uc( $eprint->get_value( "title" ) );
		my @records = $doc->getElementsByTagName( 'REC' );
		RECORD: foreach my $record ( @records )
		{
			foreach my $title ( $record->getElementsByTagName( 'title' ) )
			{
				next unless( $title->getAttribute( 'type' ) eq 'item' );
				if( uc( $title->textContent ) eq $uctitle )
				{
					my @tags = $record->getElementsByTagName( 'UID' );
					next RECORD unless( scalar( @tags ) );
					return $tags[0]->textContent;
				}
			}
		}

		return "";

	}
	else
	{
		# no records found; return an empty string
		return "";
	}
}


#
# Search for articles that cite the eprint with a given identifier ($ut) on
# Web of Science. Returns the result of the call (i.e. SOAP::SOM->result),
# an empty hash if there was a SOAP fault, or undef if there was a network
# error.
#
# $soap should be a SOAP object that will call the $WOKSEARCH_ENDPOINT,
# and contains the session identifier for the session in which this
# request is made.
#
sub get_cites_for_identifier
{
	my ( $plugin, $eprint, $ut, $soap ) = @_;

	# work out the date range in which citations might appear
	my $date_begin = "1970-01-01";
	if ( $eprint->is_set( "date" ) )
	{
		# citing articles might appear in the WoS year prior to the publication year
		$date_begin = ( substr( $eprint->get_value( "date" ), 0, 4 ) - 1 ) . "-01-01";
	}
	my $date_end = substr( EPrints::Time::get_iso_timestamp(), 0, 10 );
	my $date_param = SOAP::Data->name( "timeSpan" => \SOAP::Data->value(
		SOAP::Data->name( "begin" )->value( $date_begin ),
		SOAP::Data->name( "end" )->value( $date_end )
	) );

	# configure what we want to retrieve
	my $retrieve_params = SOAP::Data->value(
		SOAP::Data->name( "firstRecord" => "1" ),
		SOAP::Data->name( "count" => "1" ),
#		SOAP::Data->name( "fields" => \SOAP::Data->value(
#			SOAP::Data->name( "name" )->value( "Date" ),
#			SOAP::Data->name( "sort" )->value( "D" )
#		) ),
	);

	# search for citing articles
	my $som;
	eval {
		my @params;
		push @params, $plugin->{query}->{databaseId};
		push @params, SOAP::Data->name( "uid" => $ut );
		push @params, @$SOAP_EDITIONS;
		push @params, $date_param;
		push @params, $plugin->{query}->{queryLanguage};
		push @params, SOAP::Data->name( "retrieveParameters" => \$retrieve_params );
		
		my $service = $WOK_CONF->{SERVICE_TYPE};

		#$som = $soap->call( SOAP::Data->name( "$service:citingArticles" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );
		$som = $plugin->call( $soap, SOAP::Data->name( "$service:citingArticles" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );

	}
	or do
	{
		$plugin->warning( "Unable to connect to the citingArticles service for EPrint ID " . $eprint->get_id . ": " . $@ );
		return undef;
	};
	if ( $som->fault )
	{
		$plugin->warning( "Unable to retrieve citation data for EPrint ID " . $eprint->get_id . " from Web of Science: " . $som->faultstring );
		return {};
	}

	# we will need the identifier again later, so save it in the result
	$som->result->{ut} = $ut;

	return $som->result;

}


#
# Convert the response from the "citingArticles" operation into an "epdata"
# hash.
#
# $response should be the output of SOAP::SOM::result() on the
# "citingArticles" call.
#
sub response_to_epdata
{
	my ( $plugin, $eprint, $response ) = @_;

	# if the response is empty, it's because we couldn't find a record for this eprint
	if ( scalar keys %{$response} == 0 )
	{
		$plugin->warning( "No match for EPrint ID " . $eprint->get_id . "." );
		return {};
	}

	# sanity check
	if ( !defined( $response->{recordsFound} ) || !defined( $response->{ut} ) )
	{
		$plugin->warning( "Got an unusable response for EPrint ID " . $eprint->get_id . ": " . Data::Dumper( $response ) );
		return undef;
	}

	return {
		cluster => $response->{ut},
		impact => $response->{recordsFound},
	}
}


#
# Initiate a session with Web of Science. If successful, this routine
# sets the "session_id" member variable, and also returns it. Otherwise,
# it returns undef.
#
sub get_session
{
	my ( $plugin ) = @_;

	# if we already have a session, just return the existing session
	if ( defined $plugin->{session_id} )
	{
		return $plugin->{session_id};
	}

	my $soap = SOAP::Lite->new(
		proxy => $WOK_CONF->{AUTHENTICATE_ENDPOINT},
		default_ns => $WOK_CONF->{AUTHENTICATE_NS},
	);

	my $som;
	eval {
		# sf2 / using custom type as the WoS WS doesn't like the attributes added by SOAP::Lite. 
		# this will call SOAP::Serializer::as_authenticate (see below)
		$som = $soap->call( SOAP::Data->name( 'auth' )->prefix( 'auth' )->uri($WOK_CONF->{AUTHENTICATE_NS})->type( 'authenticate' => undef ) );

		1;
	}
	or do
	{
		$plugin->warning( "Unable to connect to Web of Science: " . $@ );
		return undef;
	};
	if ( $som->fault )
	{
		$plugin->warning( "Unable to authenticate to Web of Science: " . $som->faultstring );
		return undef;
	}

	$plugin->{session_id} = $som->result;

	return $plugin->{session_id};
}


sub SOAP::Serializer::as_authenticate
{
	return [ 'authenticate', { 'xmlns' => $WOK_CONF->{AUTHENTICATE_NS} } ]; 
}


#
# Terminate the session with Web of Science.
#
sub dispose
{
	my ( $plugin ) = @_;

	if ( defined $plugin->{session_id} )
	{
		# build a SOAP object
		my $soap = SOAP::Lite->new(
			proxy => $WOK_CONF->{AUTHENTICATE_ENDPOINT},
			default_ns => $WOK_CONF->{AUTHENTICATE_NS}
		);
		$soap->transport->http_request->header( "Cookie" => "SID=\"" . $plugin->{session_id} . "\";" );

		# close the session
		my $som;
		eval {
			# sf2 / using custom type as the WoS WS doesn't like the attributes added by SOAP::Lite. 
			# this will call SOAP::Serializer::as_closeSession (see below)
			$som = $soap->call( SOAP::Data->name( 'closeSession' )->prefix( 'auth' )->uri($WOK_CONF->{AUTHENTICATE_NS})->type( 'closeSession' => undef ) );
			1;
		}
		or do
		{
			$plugin->warning( "Unable to close Web of Science session: " . $@ );
		};
		if ( $som->fault )
		{
			$plugin->warning( "Unable to close Web of Science session: " . $som->faultstring );
		}
	}
}

sub SOAP::Serializer::as_closeSession
{
	return [ 'closeSession', { 'xmlns' => $WOK_CONF->{AUTHENTICATE_NS} } ]; 
}


# sf2 - having our own 'call' function allows us to count the number of requests which have been made to date. Thomson Reuters say there's a limit of 10,000 requests per session.
sub call
{
	my( $plugin, $soap, @params ) = @_;

	if( $plugin->{requests} >= $plugin->{max_requests} )
	{
		# we need a new session

		# close the current session
		$plugin->dispose;
		delete $plugin->{session_id};

		# get a new session ID - note this is eval'ed by the caller hence the use of die()
		$plugin->get_session or die( 'Failed to get a new session ID' );
		
		$soap->transport->http_request->header( "Cookie" => "SID=\"" . $plugin->{session_id} . "\";" );
		$plugin->{requests} = 0;
	}

	$plugin->{requests}++;

	# max 2 requests per sec so sleep for 510ms.
	select( undef, undef, undef, 0.51 );

	return $soap->call( @params );
}

1;

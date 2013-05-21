package EPrints::Plugin::Import::CitationService::WoS;
###############################################################################
#
# Web of Science citation ingest.
#
# This plug-in will retrieve citation data from Web of Science Web Services
# Premium. This data should be stored in the "wos" dataset.
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
# May 2013 / sf2:
#
# - if an EPrint's UT has changed, re-do a search instead of die()'ing
#
######################################################################
#
# May 2013 / gregson:
#
# - Revised and improved exception handling
# - Configured Web Services Premium by default
# - Added DOI filtering to remove ones with mismatched parenthesis
#   that WoS can't interpret
# - Fixed a character escaping issue in the userQuery element
# - Modified get_session() and dispose() to use $plugin->call()
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
	'WOKSEARCH_ENDPOINT' => 'http://search.webofknowledge.com/esti/wokmws/ws/WokSearch',
	'WOKSEARCH_NS' => 'http://woksearch.cxf.wokmws.thomsonreuters.com',
	'SERVICE_TYPE' => 'woksearch',
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
# Get the response from Web of Science for a given eprint or return an
# empty hash.
#
sub get_epdata
{
	my ( $plugin, $eprint ) = @_;

        $plugin->get_session();

	# Build a SOAP object for this session
	my $soap = SOAP::Lite->new(
		proxy => $WOK_CONF->{WOKSEARCH_ENDPOINT},
		autotype => 0,
	);
	$soap->transport->http_request->header( "Cookie" => "SID=\"" . $plugin->{session_id} . "\";" );

	# get the WoS identifier ("UT") for this eprint
	my $uid;
	if ( $eprint->is_set( "wos_cluster" ) )
	{
		# We already know the identifier
		$uid = $eprint->get_value( "wos_cluster" );
	}
	else
	{
	    # Search WoS for the eprint and retrieve the UID, no UID
	    # indicates the eprint is not indexed in WoS so return
	    # undef
	    $uid = $plugin->_retrieve_uid( $eprint, $soap );
	    return undef if ( !defined $uid );
	}

	# Search for the articles that cite this identifier, or return
	# an empty hash

        my $cites = $plugin->get_cites_for_identifier( $eprint, $uid, $soap );

	return $plugin->response_to_epdata( $cites );
}

#
# Returns the UID of $eprint by querying WoS or undef.
#
# Queries WoS by DOI first, if the record has one, and if that fails
# queries again using bibliographic metadata.
#
sub _retrieve_uid
{
    my ( $plugin, $eprint, $soap ) = @_;

    my $uid = undef;
    my $search = undef;

    # Try to retrieve the UID using a DOI if it is set
    if ( $eprint->is_set( 'id_number' )
         && _is_usable_doi( $eprint->get_value( 'id_number' ) ) )
    {
	$search = $plugin->get_search_for_eprint( $eprint,
                                                  $soap,
                                                  $plugin->_get_querystring_doi( $eprint ) );
	if ( defined $search )
	{
	    $uid = $plugin->get_identifier_from_search( $search, $eprint );
	}

    }
    # Try to retrieve using bibligraphic metadata if we've had no
    # success
    if ( !defined $uid )
    {
	$search = $plugin->get_search_for_eprint( $eprint,
                                                  $soap,
                                                  $plugin->_get_querystring_metadata( $eprint ) );
	if ( defined $search )
	{
	    $uid = $plugin->get_identifier_from_search( $search, $eprint );
	}
    }

    return $uid;
}


#
# Search for a particular eprint on Web of Science using the query,
# $q. Returns the result of the call (i.e. SOAP::SOM->result), an
# empty hash if there was a SOAP fault, or undef if there was a
# network error.
#
# $soap should be a SOAP object that will call the $WOKSEARCH_ENDPOINT,
# and contains the session identifier for the session in which this
# request is made.
#
sub get_search_for_eprint
{
	my ( $plugin, $eprint, $soap, $q ) = @_;

	my $date_begin = "1900-01-01";
	my $date_end = substr( EPrints::Time::get_iso_timestamp(), 0, 10 );
	if ( $eprint->is_set( "date" ) )
	{
	    # Add a limit on timespan to reduce the risk of erroneous
	    # results - the record could appear either the year
	    # before, the year, or the year after it was published.
	    my $date = substr( $eprint->get_value( "date" ), 0, 4 );
	    $date_begin = ( $date - 1 ) . "-01-01";
	    $date_end = ( $date + 1) . "-12-31";
	}
	my $date_param = SOAP::Data->name( "timeSpan" => \SOAP::Data->value(
					    SOAP::Data->name( "begin" )->value( $date_begin ),
					    SOAP::Data->name( "end" )->value( $date_end )
					) );

	# Build SOAP call
	my @query_params;
	push @query_params, $plugin->{query}->{databaseId};

        # Force the Data object to a string so special chars are
        # encoded properly during serialisation and then add the xsd
        # namespace declarataion to stop the server complaining
	push @query_params, SOAP::Data->name( "userQuery" => $q )->type( 'string' )->attr( { "xmlns:xsd" => "http://www.w3.org/2001/XMLSchema" } );

	push @query_params, @$SOAP_EDITIONS;
	push @query_params, $date_param;
	push @query_params, $plugin->{query}->{queryLanguage};
	
	my $q_params = SOAP::Data->value( @query_params );

	# sf2 / TODO: v3 has a new format for fields (viewFields, sortFields)
	my $retrieve_params = SOAP::Data->value(
		SOAP::Data->name( "firstRecord" => "1" ),
		SOAP::Data->name( "count" => "10" ),
#		SOAP::Data->name( "fields" => \SOAP::Data->value(
#			SOAP::Data->name( "name" )->value( "Date" ),
#			SOAP::Data->name( "sort" )->value( "D" )
#		) ),
	);

        my @params;
        push @params, SOAP::Data->name( "queryParameters" => \$q_params );
        push @params, SOAP::Data->name( "retrieveParameters" => \$retrieve_params );

        my $service = $WOK_CONF->{SERVICE_TYPE};

        my $som = $plugin->call( $soap, 0, SOAP::Data->name( "$service:search" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );

	if ( $som->fault() )
	{
            # Complain on receiving a SOAP error and then return undef
            # to allow remaining eprints to be processed.  Errors are
            # likely to be caused by data issues related to this
            # specific eprint and shared with a minority of others so
            # it's better to keep trying than to give up.

            # MG To Do: it would be useful to log the serialized call
            # here - logging the userQuery is a good start.
            $plugin->error( "Unable to retrieve UID from Web of Science for EPrint ID " . $eprint->get_id .
                            ": \n" . $plugin->_get_som_error( $som ) . ", userQuery = $q" );
            return undef;
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
        return undef if ( $search->{recordsFound} == 0 );

        # only one match; return that record
        my $doc;
        eval
        {
            $doc = $plugin->{session}->xml->parse_string( $search->{records} );
            1;
        } or do
        {
            $plugin->warning( "Unable to parse record XML: \n" . $@ . ": " . $search->{records} );
            die( 'Unable to parse response for WoS search request' );
        };

        # the 'record' is string encapsulated in XML, so we need to parse it
        # We're looking for: <UID>WOS:(\d+)</UID> (the tag used to be <UT> in previous API versions)
        if ( $search->{recordsFound} == 1 )
        {
            return $doc->getElementsByTagName( 'UID' )->[0]->textContent;
        }

        my $uctitle = uc( $eprint->get_value( "title" ) );
        my @records = $doc->getElementsByTagName( 'REC' );
      RECORD: foreach my $record ( @records )
        {
            foreach my $title ( $record->getElementsByTagName( 'title' ) )
            {
                next unless( $title->getAttribute( 'type' ) eq 'item' );
                if ( uc( $title->textContent ) eq $uctitle )
                {
                    my @tags = $record->getElementsByTagName( 'UID' );
                    next RECORD unless( scalar( @tags ) );
                    return $tags[0]->textContent;
                }
            }
        }

        return;
}


#
# Search for articles that cite the eprint with a given identifier
# ($uid) on Web of Science. Returns the result of the call
# (i.e. SOAP::SOM->result), an empty hash if there was a SOAP fault,
# or dies if there was a persistent network error.
#
# $soap should be a SOAP object that will call the $WOKSEARCH_ENDPOINT,
# and contains the session identifier for the session in which this
# request is made.
#
sub get_cites_for_identifier
{
	my ( $plugin, $eprint, $uid, $soap ) = @_;

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

        my @params;
        push @params, $plugin->{query}->{databaseId};
        push @params, SOAP::Data->name( 'uid' => $uid );
        push @params, @$SOAP_EDITIONS;
        push @params, $date_param;
        push @params, $plugin->{query}->{queryLanguage};
        push @params, SOAP::Data->name( "retrieveParameters" => \$retrieve_params );

        my $service = $WOK_CONF->{SERVICE_TYPE};

        $som = $plugin->call( $soap, 0, SOAP::Data->name( "$service:citingArticles" )->attr( { "xmlns:$service" => "http://$service.v3.wokmws.thomsonreuters.com" } ) => @params );

	if ( $som->fault() )
	{
		# sf2 / we can catch InvalidInputException here which is thrown when WoS doesn't know the id/UT. In this case we just need to search for that eprint again.
		my $fault = $som->faultdetail();
		if( defined $fault && ref( $fault ) eq 'HASH' && exists $fault->{InvalidInputException} )
		{
			# new uid?
			my $new_uid = $plugin->_retrieve_uid( $eprint, $soap );
			if( defined $new_uid && $new_uid ne $uid )	# not fearing a stack overflow!
			{
				return $plugin->get_cites_for_identifier( $eprint, $new_uid, $soap );
			}
			return undef;
		}

            # MG To do: it would be useful to log the serialized call
            # here if the faultcode eq 'Client'
	    die( "Unable to retrieve cites for EPrint ID " . $eprint->get_id .
                 " from Web of Science: \n" . $plugin->_get_som_error( $som ) );
	}

	# we will need the identifier again later, so save it in the result
	$som->result->{ut} = $uid;

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
	my ( $plugin, $response ) = @_;

	# sanity check
	if ( !defined( $response->{recordsFound} ) || !defined( $response->{ut} ) )
	{
            $plugin->warning( "Got an unusable response: " . Data::Dumper( $response ) );
            die( 'Unable to parse citingArticles response from WoS' );
	}

	return {
		cluster => $response->{ut},
		impact => $response->{recordsFound},
            };
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

        # sf2 / using custom type as the WoS WS doesn't like the
        # attributes added by SOAP::Lite.  this will call
        # SOAP::Serializer::as_authenticate (see below)
	my $som = $plugin->call($soap, 1, SOAP::Data->name( 'auth' )->prefix( 'auth' )->uri($WOK_CONF->{AUTHENTICATE_NS})->type( 'authenticate' => undef ), 1 );

	if ( $som->fault() )
	{
            die( "Unable to authenticate to WoS: \n" . $plugin->_get_som_error( $som ) );
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

                # sf2 / using custom type as the WoS WS doesn't like
                # the attributes added by SOAP::Lite.  this will call
                # SOAP::Serializer::as_closeSession (see below)
		my $som = $soap->call( SOAP::Data->name( 'closeSession' )->prefix( 'auth' )->uri($WOK_CONF->{AUTHENTICATE_NS})->type( 'closeSession' => undef ) );

                if ( $som->fault() )
                {
                    die( "Unable to close WoS session: \n" . $plugin->_get_som_error( $som ) );
                }
	}
}

sub SOAP::Serializer::as_closeSession
{
	return [ 'closeSession', { 'xmlns' => $WOK_CONF->{AUTHENTICATE_NS} } ]; 
}


# sf2 - having our own 'call' function allows us to count the number
# of requests which have been made to date. Thomson Reuters say
# there's a limit of 10,000 requests per session.
#
# If $ignore_session_limit is true it won't try to refresh the
# session. Useful when the call to call() is for creating or disposing
# the session.
#
sub call
{
	my( $plugin, $soap, $ignore_session_limit, @params ) = @_;

        $ignore_session_limit = $ignore_session_limit || 0;

	if ( !$ignore_session_limit
            && $plugin->{requests} >= $plugin->{max_requests} )
	{
		# we need a new session

		# close the current session
		$plugin->dispose;
		delete $plugin->{session_id};

		# get a new session ID
		$plugin->get_session;

		$soap->transport->http_request->header( "Cookie" => "SID=\"" . $plugin->{session_id} . "\";" );
		$plugin->{requests} = 0;
	}

        # Make up to $plugin->{net_retry}->{max} attempts to make the
        # SOAP call and die if unsuccessful.
        my $som;
        my $net_tries_left = $plugin->{net_retry}->{max};
        while ( !defined $som && $net_tries_left )
        {
            # max 2 requests per sec so sleep for 510ms.
            select( undef, undef, undef, 0.51 );
            $plugin->{requests}++;

            eval
            {
                $som = $soap->call( @params );
                1;
            } or do
            {
                # Assume this is a transport error, go to sleep before
                # trying again
                $plugin->warning(
				 "Problem connecting to the WoS server: \n" . $@ .
                                 ".\nWaiting " . $plugin->{net_retry}->{interval} . " seconds before trying again."
                             );
                sleep( $plugin->{net_retry}->{interval} );
                $som = undef;
            };
            $net_tries_left--;
        }

        if ( !defined $som )
        {
            die( "No response in " . $plugin->{net_retry}->{max} . " attempts. Giving up." );
        }

	return $som;
}

# Return a WoS query string using the eprints' DOI
sub _get_querystring_doi
{
    my ( $plugin, $eprint ) = @_;
    return 'DO=(' . $eprint->get_value( 'id_number' ) . ')';
}

# Return a WoS query string using bibliographic metadata: author,
# title, and year published
sub _get_querystring_metadata
{
    my ( $plugin, $eprint ) = @_;

    my $q;

    # Title
    my $ti = $eprint->get_value( "title" );
    $ti =~ s/[^\p{Latin}\p{Number}]+/ /g; # WoS doesn't like punctuation

    # First author
    my $creator = @{$eprint->get_value( "creators_name" )}[0];
    my $au = $creator->{family} . ", " . substr( $creator->{given}, 0, 1 ) . "*";
    $au =~ s/[-\'\x{2019}]/\*/g; # WoS is inconsistent with - and '
    $q = "AU=($au) AND TI=(\"$ti\")";

    # Date published
    my $py;
    if ( $eprint->is_set( "date" ) )
    {
	$py = substr( $eprint->get_value( "date" ), 0, 4 );
	$q = $q . " AND PY=$py";
    }

    # Reduce any unicode characters to plain old ASCII. Strips
    # diacritics, splits digraphs, etc.
    $q = unidecode($q); 

    return $q;
}

#
# Return a string containing the available elements from $som
# describing the SOAP fault
#
sub _get_som_error
{
    my ( $plugin, $som ) = @_;

    my $error = $som->faultcode() . "\n" . $som->faultstring();
    $error .= "\nActor: " . $som->faultactor() if ( defined $som->faultactor() );
    if ( defined $som->faultdetail() )
    {
        $error .= "\nDetail: ";
        if ( ref( $som->faultdetail() ) eq 'HASH' )
        {
             $error .= Data::Dumper::Dumper( $som->faultdetail() );
        }
        else
        {
            $error .= $som->faultdetail();
        }
    }
    return $error;
}


#
# Return 1 if a given DOI is usable for searching WoS, or 0 if it is
# not.
#
# Ideally, we would be able to encode all DOIs in such a manner as to
# make them acceptable. However, we do not have any documentation as
# to how problem characters might be encoded, or even any assurance
# that it is possible at all.
#
sub _is_usable_doi
{
    my ( $doi ) = @_;

    my $depth = 0;
    if ( $doi =~ /[()]/ )
    {
        # The DOI contains parentheses, check they matched as WoS will
        # only interpret the query correctly if they are matched.
        my @chars = split //, $doi;
        foreach my $char ( @chars )
        {
            if ( $char eq '(' )
            {
                $depth++;
            } elsif ( $char eq ')' )
            {
                $depth--;
            }
            # Negative depth indicates a closing parenthesis has
            # proceeded an opening parenthesis
            return 0 if $depth < 0;
        }
    }
    # If parentheses are matched, then depth will be zero at the end
    # of the string.
    return ($depth eq 0);
}

1;

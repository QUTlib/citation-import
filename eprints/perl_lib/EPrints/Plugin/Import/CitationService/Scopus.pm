package EPrints::Plugin::Import::Scopus;
###############################################################################
#
# Scopus Search API citation ingest.
#
# This plug-in will retrieve citation data from Scopus. This data should be
# stored in the "scopus" dataset.
#
###############################################################################

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

use LWP::UserAgent;
use URI;

our $SEARCHAPI = URI->new( "http://searchapi.scopus.com/search.url" );


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
	if ( !defined( $self->{dev_id} ) ) {
		$self->{error} = 'Unable to load the Scopus developer key.';
		$self->{disable} = 1;
		return $self;
	}

	return $self;
}


#
# Test whether or not this plug-in can hope to retrieve data for a given eprint.
#
sub can_process
{
	my ( $plugin, $eprint ) = @_;

	if ( $eprint->is_set( "scopus_cluster" ) )
	{
		# do not process eprints with EID set to "-"
		return 0 if $eprint->get_value( "scopus_cluster" ) eq "-";

		# otherwise, we can use the existing EID to retrieve data
		return 1;
	}

	# we can retrieve data if this eprint has a (usable) DOI
	return 1 if ( $eprint->is_set( "identifier" ) && is_usable_doi( $eprint->get_value( "identifier" ) ) );

	# Scopus doesn't contain data for the following types
	my $type = $eprint->get_value( "type" );
	return 0 if $type eq "thesis";
	return 0 if $type eq "other";

	# otherwise, we can (try to) retrieve data if this eprint has a title and authors
	return $eprint->is_set( "title" ) && $eprint->is_set( "creators_name" );
}


#
# Get the response from Scopus for a given eprint.
#
sub get_response
{
	my ( $plugin, $eprint ) = @_;

	# construct a search term that will find this eprint
	my $search;
	if ( $eprint->is_set( "scopus_cluster" ) )
	{
		# search using Scopus' identifier
		$search = "eid(" . $eprint->get_value( "scopus_cluster" ) . ")";
	}
	elsif ( $eprint->is_set( "identifier" ) && is_usable_doi( $eprint->get_value( "identifier" ) ) )
	{
		# search using DOI
		$search = "doi(" . $eprint->get_value( "identifier" ) . ")";
	}
	else
	{
		# search using title and first author
		my $title = $eprint->get_value( "title" );
		utf8::decode($title);
		$title =~ s/[^\p{Latin}\p{Number}]+/ /g;
		my $authlastname = @{$eprint->get_value( "creators_name" )}[0]->{family};
		utf8::decode($authlastname);
		$authlastname =~ s/\x{2019}/'/;
		$search = "title(\"$title\") and authlastname($authlastname)";
		if ( $eprint->is_set( "date" ) )
		{
			# limit by publication year
			my $pubyear = substr( $eprint->get_value( "date" ), 0, 4 );
			$search = $search . " and pubyear is $pubyear";
		}
	}

	# build the URL from which we can download the data
	my $quri = $SEARCHAPI->clone;
	$quri->query_form(
		format => "XML",
		devId => $plugin->{dev_id},
		search => $search,
		fields => "eid,citedbycount"
	);

	# send the query to Scopus
	my $ua = LWP::UserAgent->new;
	my $response = $ua->get( $quri );

	# Scopus has a maximum of 60 queries per minute, so sleep for a second
	sleep(1);

	if ( $response->is_success )
	{
		return $response;
	}
	else
	{
		$plugin->warning( "Unable to retrieve data from Scopus. The response was: " . $response->status_line . "\n" );
		return undef;
	}
}

#
# Convert the response from Scopus into an "epdata" hash.
#
sub response_to_epdata
{
	my ( $plugin, $eprint, $response ) = @_;

	# parse the document
	my $doc;
	my $xml = $plugin->{session}->xml;
	eval {
		$doc = $xml->parse_string( $response->content );
		1;
	}
	or do
	{
		$plugin->warning( "Got a malformed response for EPrint ID " . $eprint->get_id . ": " . $response->content );
		return undef;
	};

	# get the status code
	my $status_code = undef;
	my ( $status ) = $doc->documentElement->getChildrenByTagName( "status" );
	if ( defined( $status ) )
	{
		my ( $child ) = $status->getChildrenByTagName( "statusCode" );
		if ( defined( $child ) )
		{
			$status_code = $child->textContent;
		}
	}


	# get the citation count
	my $epdata = undef;
	if ( defined( $status_code ) )
	{
		if ( $status_code eq "OK" || $status_code eq "PartOK" )
		{
			# get the results of the search
			my ( $result ) = $doc->firstChild->getChildrenByTagName( "scopusSearchResults" );
			if ( defined( $result ) )
			{
				my ( $results_count ) = $result->getChildrenByTagName( "returnedResults" );
				if ( defined( $results_count ) && $results_count->textContent > 0 )
				{
					# get the electronic id and the citation count
					my ( $record ) = $result->getChildrenByTagName( "scopusResult" );
					if ( defined ( $record ) )
					{
						my $eid = shift @{$record->getChildrenByTagName( "eid" )};
						my $citation_count = shift @{$record->getChildrenByTagName( "citedbycount" )};
						$epdata = {
							cluster => $eid->textContent,
							impact => $citation_count->textContent,
						};
					}
				}
				else
				{
					$plugin->warning( "No records found for EPrint ID " . $eprint->get_id . "." );
					$epdata = {};
				}
			}
		}
		else
		{
			# the search failed; log the detailed error message
			my ( $detail ) = $status->getChildrenByTagName( "detail" );
			if ( defined ( $detail ) )
			{
				$plugin->warning( "EPrint ID " . $eprint->get_id . ": " . $detail->textContent );
			}
			$epdata = {};
		}
	}

	if ( !defined( $epdata ) )
	{
		$plugin->warning( "Could not parse the response for EPrint ID " . $eprint->get_id . ": " . $response->content );
	}


	# clean up
	$xml->dispose( $doc );

	return $epdata;
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
	my ( $doi ) = @_;

	# DOIs containing parentheses confuse Scopus because it uses them as delimiters
	return !( $doi =~ /[()]/ );
}

1;

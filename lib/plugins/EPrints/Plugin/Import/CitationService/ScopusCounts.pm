package EPrints::Plugin::Import::CitationService::ScopusCounts;

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( 'EPrints::Plugin::Import::CitationService' );

use LWP::UserAgent;
use Unicode::Normalize qw(NFKC);
use URI;

my $COUNTAPI  = URI->new( 'http://api.elsevier.com/content/abstract/citation-count' );  # https://api.elsevier.com/documentation/AbstractCitationCountAPI.wadl

my $BATCHSIZE = 50;

sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = 'Scopus Citation Count Ingest';

    # get the developer key
    $self->{dev_id} = $self->{session}->get_conf( 'scapi', 'developer_id' );
    if( !defined( $self->{dev_id} ) )
    {
	$self->{error}   = 'Unable to load the Scopus developer key.';
	$self->{disable} = 1;
	return $self;
    }

    # Plugin-specific net_retry parameters (command line > config > default)
    my $net_retry = $self->{session}->get_conf( 'scapi', 'net_retry' ) || {};
    $net_retry->{max} //= 4;
    $net_retry->{interval} //= 30;
    foreach my $k ( keys %{$net_retry} )
    {
	$self->{net_retry}->{$k} //= $net_retry->{$k};
    }

    # Other configurable parameters
    my $doi_field = $self->{session}->get_conf( 'scapi', 'doi_field' ) || 'id_number';
    $self->{doi_field} = $doi_field;

    return $self;
}

# Breaks a list of items into chunks of up to $BATCHSIZE elements,
# each of which is joined with commas.
sub _chunk
{
    my @chunks;
    push @chunks, join( ',', splice( @_, 0, $BATCHSIZE ) ) while @_;
    return @chunks;
}

#
# Retrieve citation counts for all $opts{eprintids} and
# returns a list of IDs successfully retrieved.
#
sub process_eprints
{
    my( $plugin, %opts ) = @_;

    my $eprintids = $opts{eprintids};

    my @eids;
    my @dois;
    my $eid_map;
    my $doi_map;
  EPRINT: foreach my $eprintid ( @{ $eprintids // [] } )
    {
	my $eprint = $plugin->{session}->eprint( $eprintid );

	if( $eprint )
	{
	    # preference 1: use the Scopus EID (if not '-')
	    if( $eprint->is_set( 'scopus_cluster' ) )
	    {
		my $eid = $eprint->get_value( 'scopus_cluster' );
		if( $eid ne '-' )
		{
		    push @eids, $eid;
		    $eid_map->{ $eid } = $eprint;
		}
		next EPRINT;
	    }

	    # preference 2: use the DOI
	    if( $eprint->is_set( $plugin->{doi_field} ) )
	    {
		my $doi = usable_doi( $eprint->get_value( $plugin->{doi_field} ) );
		if( $doi )
		{
		    push @dois, $doi;
		    $doi_map->{ $doi } = $eprint;
		}
		next EPRINT;
	    }
	}
	else
	{
	    $plugin->warning( "EPrint ID $eprintid does not exist." );
	}
    }

    # request in batches
    my @results;
    foreach my $chunk ( _chunk @eids )
    {
	push @results, @{ $plugin->_query( $eid_map, 'scopus_cluster', 'eid', scopus_id => $chunk ) };
    }
    foreach my $chunk ( _chunk @dois )
    {
	push @results, @{ $plugin->_query( $doi_map, $plugin->{doi_field}, 'doi', doi => $chunk ) };
    }
}

sub _query
{
    my( $plugin, $map, $fieldname, $element, %params ) = @_;

    my $uri = $COUNTAPI->clone;
    $uri->query_form(
		      httpAccept => 'application/xml',
		      apiKey     => $plugin->{dev_id},
		      %params
    );

    # FIXME
    my $RETRIES = 2;
    my $DELAY = 30;
    my $response = EPrints::Plugin::Import::CitationService::ScopusLookup::_call( $plugin, $uri, $RETRIES, $DELAY );

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
	    $plugin->error(
"Scopus responded with error condition for <$uri>: [$code] $status_code, $status_detail, Request URL: "
		  . $quri->as_string );
	}
	else
	{
	    $plugin->warning(
		 "Unable to parse response XML for <$uri>: [$code] Request URL: " . $quri->as_string . "\n$body" );
	}
	return undef;
    };

    if( $code != 200 )
    {
	# Don't die on errors because these may be caused by data
	# specific to a given eprint and dying would prevent
	# updates for the remaining eprints
	( $status_code, $status_detail ) = EPrints::Plugin::Import::CitationService::ScopusLookup::get_response_status( $plugin, $response_xml );
	if( $status_code || $status_detail )
	{
	    $status_code   ||= '-';
	    $status_detail ||= '-';
	    $plugin->error(
"Scopus responded with error condition for <$uri>: [$code] $status_code, $status_detail, Request URL: "
		  . $quri->as_string );
	}
	else
	{
	    $plugin->error( "Scopus responded with unknown error condition for <$uri>: [$code] Request URL: " .
			    $quri->as_string . "\n" . $response_xml->toString );
	}
	return undef;
    }

    my @hits;
  EPRINT: foreach my $document ( @{ $response_xml->getElementsByLocalName( 'document' ) } )
    {
	# TODO: ensure status="found"?

	my $key = $plugin->_extract( $document, $element );
	next EPRINT unless $key;
	# TODO: unescape?

	my $eprint = $map->{ $key };
	if( !$eprint) {
	    $plugin->error( "returned citations for eprint with $fieldname=$key, but there's no such record in the map" );
	    next EPRINT;
	}

	$eprintid = $eprint->id;
	my $need_save = 0;

	my $new_eid = $plugin->_extract( $document, 'eid' );
	if( defined $new_eid )
	{
	    my $old_eid = $eprint->get_value( 'scopus_cluster' );
	    if( $old_eid )
	    {
		if( $new_eid ne $old_eid )
		{
		    $plugin->error( "'eid' $new_eid for $eprintid doesn't match $old_eid in database" );
		    next EPRINT;
		}
	    }
	    else
	    {
		#$eprint->set_value( 'scopus_cluster', $new_eid );
		#$need_save = 1;
	    }
	}
	else
	{
	    $plugin->error( "no eid in response for $eprintid !?" );
	    next EPRINT;
	}

	my $new_doi = $plugin->_extract( $document, 'doi', 1 );
	if( defined $new_doi )
	{
	    my $old_doi = $eprint->get_value( $plugin->{doi_field} );
	    if( $old_doi )
	    {
		if( $new_doi ne $old_doi )
		{
		    $plugin->error( "'doi' $new_doi for $eprintid doesn't match $old_doi in database" );
		    #next EPRINT; # meh, who cares, really
		}
	    }
	    else
	    {
		$plugin->warning( "Scopus returned DOI $new_doi for $eprintid, which doesn't currently have one" );
		# FIXME: set field? add to comment? ??
	    }
	}

	my $citation_count = $plugin->_extract( $document, 'citation-count' );
	if( !defined $citation_count )
	{
	    $plugin->error( "no citation count in response for $eprintid !?" );
	    next EPRINT;
	}
	push @hits, { cluster => $new_eid, impact => $citation_count };
    }

    return @hits;
}

sub _extract
{
    my( $plugin, $container_node, $element_name, $quiet );
    my $element = shift @{ $container_node->getElementsByLocalName( $element_name ) };
    if( !$element )
    {
	$plugin->warning( "no <$element_name/>" ) unless $quiet;
	return undef;
    }

    my $value = $element->text_content;
    if( !EPrints::Utils::is_set( $value ) )
    {
	$plugin->error( "<$element_name/> has no value" ) unless $quiet;
	return undef;
    }

    return $value;
}

sub usable_doi
{
    my( $string, %opts ) = @_;

    my $NO = ($opts{test} ? 0 : undef);

    return $NO if( !EPrints::Utils::is_set( $doi ) );

    if( eval { require EPrints::DOI; } )
    {
	$doi = EPrints::DOI->parse( $string );
	return $NO unless $doi;
	return $opts{test} ? 1 : $doi->to_string( noprefix => 1 );
    }
    else
    {
	# dodgy fallback

	$doi = "$doi";
	$doi =~ s!^https?://+(dx\.)?doi\.org/+!!i;
	$doi =~ s!^info:(doi/+)?!!i;
	$doi =~ s!^doi:!!i;

	return $NO if( $doi !~ m!^10\.[^/]+/! );

	return 1 if $opts{test};
	return $doi;
    }
}

1;


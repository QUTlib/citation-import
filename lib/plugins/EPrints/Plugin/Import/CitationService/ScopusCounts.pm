package EPrints::Plugin::Import::CitationService::ScopusCounts;

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

use LWP::UserAgent;
use Unicode::Normalize qw(NFKC);
use URI;

my $COUNTAPI  = URI->new( "http://api.elsevier.com/content/abstract/citation-count" );  # https://api.elsevier.com/documentation/AbstractCitationCountAPI.wadl

sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = "Scopus Citation Count Ingest";

    # get the developer key
    $self->{dev_id} = $self->{session}->get_conf( "scapi", "developer_id" );
    if( !defined( $self->{dev_id} ) )
    {
	$self->{error}   = 'Unable to load the Scopus developer key.';
	$self->{disable} = 1;
	return $self;
    }

    # Plugin-specific net_retry parameters (command line > config > default)
    my $net_retry = $self->{session}->get_conf( "scapi", "net_retry" ) || {};
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
  EPRINT: foreach my $eprintid ( @{ $eprintids // [] } )
    {
	my $eprint = $plugin->{session}->eprint( $eprintid );

	if( $eprint )
	{
	    # preference 1: use the Scopus EID (if not "-")
	    if( $eprint->is_set( 'scopus_cluster' ) )
	    {
		my $eid = $eprint->get_value( 'scopus_cluster' );
		push @eids, $eid if $eid ne '-';
		next EPRINT;
	    }

	    # preference 2: use the DOI
	    if( $eprint->is_set( $plugin->{doi_field} ) )
	    {
		my $doi = usable_doi( $eprint->get_value( $plugin->{doi_field} ) );
		push @dois, $doi if $doi;
		next EPRINT;
	    }
	}
	else
	{
	    $plugin->warning( "EPrint ID $eprintid does not exist." );
	}
    }

    # request in batches
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


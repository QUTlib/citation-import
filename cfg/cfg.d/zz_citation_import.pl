###################################################
# From citation-import cfg.d/eprint_fields.pl.inc #
###################################################

#
# Eprint fields for citation data. These must be included as elements in the
#

push @{ $c->{fields}->{eprint} },

####### included in defaultcfg/cfg.d/eprints_fields.pl (N.B. without the render_style => 'short')

	  { 'name'     => 'scopus',
	    'type'     => 'compound',
	    'volatile' => 1,
	    'fields'   => [
			  { 'sub_name' => 'impact',    'type' => 'int', },
			  { 'sub_name' => 'cluster',   'type' => 'id', },
			  { 'sub_name' => 'datestamp', 'type' => 'time', 'render_style' => 'short', },
	    ],
	    'sql_index' => 0,
	  },

	  { 'name'     => 'wos',
	    'type'     => 'compound',
	    'volatile' => 1,
	    'fields'   => [
			  { 'sub_name' => 'impact',    'type' => 'int', },
			  { 'sub_name' => 'cluster',   'type' => 'id', },
			  { 'sub_name' => 'datestamp', 'type' => 'time', 'render_style' => 'short', },
	    ],
	    'sql_index' => 0,
	  },

	  #];

#######################################
# From citation-import cfg.d/scapi.pl #
#######################################

###############################################################################
#
# Scopus search API configuration. See http://searchapi.scopus.com
#
###############################################################################
$c->{scapi} = {};

#
# The Scopus API developer key
#
$c->{scapi}->{developer_id} = "";

#
# I don't know exactly what the "partner ID" is, but we need it to build the
# URL for a paper. "65" works for us.
#
$c->{scapi}->{partner_id} = 65;

#
# The base URL for Scopus
#
$c->{scapi}->{uri} = URI->new( 'http://www.scopus.com' );

#
# Build the "inward URL" for a paper. If we don't have an EID for this paper,
# this just returns the URL of Scopus' home page
#
$c->{scapi}->{get_uri_for_eprint} = sub {
    my( $eprint ) = @_;

    my $uri = $eprint->repository->config( 'scapi', 'uri' )->clone;
    if( $eprint->is_set( 'scopus_cluster' ) )
    {
	$uri->path( '/inward/record.url' );
	$uri->query_form( eid       => $eprint->get_value( 'scopus_cluster' ),
			  partnerID => $eprint->repository->config( 'scapi', 'partner_id' ), );
    }

    return $uri;

};

#####################################
# From citation-import cfg.d/wos.pl #
#####################################

###############################################################################
#
# Web of Science search configuration.
#
###############################################################################
$c->{wos} = {};

#
# The base URL for Web of Science and WoS OpenURL.
#
$c->{wos}->{uri}         = URI->new( 'http://isiknowledge.com/wos' );
$c->{wos}->{openurl_uri} = URI->new( 'http://ws.isiknowledge.com/cps/openurl/service' );

#
# Use WoS' OpenURL to link to the record.
#
$c->{wos}->{get_uri_for_eprint} = sub {
    my( $eprint ) = @_;

    if( $eprint->is_set( 'wos_cluster' ) )
    {
	my $uri = $eprint->repository->config( 'wos', 'openurl_uri' )->clone;
	$uri->query_form( 'url_ver'     => 'Z39.88-2004',
			  'rft_val_fmt' => 'info:ofi/fmt:kev:mtx:journal',
			  'svc.fullrec' => 'yes',
			  'rft_id'      => 'info:ut/' . $eprint->get_value( 'wos_cluster' ),
	);
	return $uri;
    }

    return $eprint->repository->config( 'wos', 'uri' )->clone;
};

#
# You may change the services type and endpoints here
#
# The default values are shown below (also see EPrints::Plugin::Import::CitationService::WoS)

# Authentication end-points:
# $c->{wos}->{AUTHENTICATE_ENDPOINT} = 'http://search.webofknowledge.com/esti/wokmws/ws/WOKMWSAuthenticate';
# $c->{wos}->{AUTHENTICATE_NS} = 'http://auth.cxf.wokmws.thomsonreuters.com';

# Configuration for a Premium account:
#$c->{wos}->{WOKSEARCH_ENDPOINT} = 'http://search.webofknowledge.com/esti/wokmws/ws/WokSearch';
#$c->{wos}->{WOKSEARCH_NS} = 'http://woksearch.cxf.wokmws.thomsonreuters.com';
#$c->{wos}->{SERVICE_TYPE} = 'woksearch';

# The maximum number of requests per session (default to 10,000):
# $c->{wos}->{max_requests_per_session} = 10000;

# The database editions to search:
# $c->{wos}->{editions} = [qw/ SCI SSCI AHCI IC CCR ISTP ISSHP /];

##############################################
# From citation-import cfg.d/datasets.pl.inc #
##############################################

#
# Citation datasets
#
# Each object in the "citation" dataset stores the results of a request for
# citation data from some third-party source. The structure of the record is
# based on the structure of the "gscholar" field defined in the default
# version of eprint_fields.pl
#

use EPrints::DataObj::CitationDatum;

# base dataset for all citation data
$c->{datasets}->{citation} = { class     => "EPrints::DataObj::CitationDatum",
			       sqlname   => "citation",
			       datestamp => "datestamp",
			       pluginmap => { scopus   => "Import::CitationService::Scopus",
					      wos      => "Import::CitationService::WoS",
			       },
};

# virtual dataset for Scopus data
$c->{datasets}->{scopus} = { class            => "EPrints::DataObj::CitationDatum",
			     sqlname          => "citation",
			     confid           => "citation",
			     dataset_id_field => "source",
			     filters          => [ { meta_fields => [ 'source' ], value => 'scopus', describe => 0 } ],
			     datestamp        => "datestamp",
			     virtual          => 1,
			     import           => 1,
};

# virtual dataset for Web of Science data
$c->{datasets}->{wos} = { class            => "EPrints::DataObj::CitationDatum",
			  sqlname          => "citation",
			  confid           => "citation",
			  dataset_id_field => "source",
			  filters          => [ { meta_fields => [ 'source' ], value => 'wos', describe => 0 } ],
			  datestamp        => "datestamp",
			  virtual          => 1,
			  import           => 1,
};

# when we receive new citation data, cache it in the eprint object to which it refers
$c->add_dataset_trigger(
    "citation",
    EP_TRIGGER_CREATED,
    sub {
	my( %o ) = @_;

	my $datum  = $o{"dataobj"};
	my $eprint = $datum->get_session->eprint( $datum->get_value( "referent_id" ) );
	if( defined( $eprint ) && $eprint->get_dataset->has_field( $datum->get_value( "source" ) ) )
	{
	    my $cache = { impact    => $datum->get_value( "impact" ),
			  cluster   => $datum->get_value( "cluster" ),
			  datestamp => $datum->get_value( "datestamp" ),
	    };
	    $eprint->set_value( $datum->get_value( "source" ), $cache );
	    $eprint->commit();
	}

    }
);


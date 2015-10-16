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
	$uri->query_form(
	    'url_ver'     => 'Z39.88-2004',
	    'rft_val_fmt' => 'info:ofi/fmt:kev:mtx:journal',
	    'svc.fullrec' => 'yes',
	    'rft_id'      => 'info:ut/' . $eprint->get_value( 'wos_cluster' ),

	    # MG: The following params were in the example but
	    # don't seem to be required ...
	    #'svc_val_fmt' => 'info:ofi/fmt:kev:mtx:sch_svc',
	    #'rft.genre' => 'article',
	    #'rfr_id' => 'info:sid/qut.edu.au:blah',
	    #'req_id' => 'mailto:blah@qut.edu.au',
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

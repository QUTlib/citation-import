###############################################################################
#
# Web of Science search configuration.
#
###############################################################################
$c->{wos} = {};

#
# The base URL for Web of Science.
#
$c->{wos}->{uri} = URI->new( 'http://isiknowledge.com/wos' );

#
# We don't (yet) have any way of linking to a particular paper within Web of
# Science, so this function just returns the base URL.
#
$c->{wos}->{get_uri_for_eprint} = sub
{
	my ( $eprint ) = @_;

	return $eprint->repository->config( 'wos', 'uri' )->clone;
}

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

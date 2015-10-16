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

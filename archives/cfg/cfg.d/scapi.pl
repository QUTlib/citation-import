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
# The base URL for Scopus
#
$c->{scapi}->{uri} = URI->new( 'http://www.scopus.com' );

#
# Build the "inward URL" for a paper. If we don't have a EID for this paper,
# this just returns the URL of Scopus' home page
#
$c->{scapi}->{get_uri_for_eprint} = sub
{
	my ( $eprint ) = @_;

	my $uri = $eprint->repository->config( 'scapi', 'uri' )->clone;
	if ( $eprint->is_set( 'scopus_cluster' ) )
	{
		$uri->path( '/inward/record.url' );
		$uri->query_form(
			eid => $eprint->get_value('scopus_cluster'),
			partnerID => 65,
		);
	}

	return $uri; 

};

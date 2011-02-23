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

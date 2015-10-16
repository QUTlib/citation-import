###############################################################################
#
# Google Scholar search configuration.
#
###############################################################################
$c->{gscholar} = {};

#
# The base URI for Google Scholar. You may prefer to use a local mirror.
#
$c->{gscholar}->{uri} = URI->new( "http://scholar.google.com/scholar" );

#
# Build a search for papers that cite a known cluster ID
#
$c->{gscholar}->{search_cites} = sub {
    my( $eprint ) = @_;

    my $quri = $eprint->repository->config( "gscholar", "uri" )->clone;
    $quri->query_form( cites => $eprint->get_value( "gscholar_cluster" ) );

    return $quri;
};

#
# Build a search for a paper using title and author
#
$c->{gscholar}->{search_title} = sub {
    my( $eprint ) = @_;

    my $quri = $eprint->repository->config( "gscholar", "uri" )->clone;
    my $q = "";

    # get the title and encode it for Google
    my $title = $eprint->get_value( "title" );
    $title =~ s/[^\p{Latin}\p{Number}]/ /g;
    utf8::encode( $title );
    $q = "intitle:\"$title\"";

    # get the creators' name and encode it for Google
    if( $eprint->is_set( "creators_name" ) )
    {
	my $creator = ( @{ $eprint->get_value( "creators_name" ) } )[ 0 ];
	$creator = substr( $creator->{given}, 0, 1 ) . "-" . $creator->{family};
	utf8::encode( $creator );
	$q .= " author:$creator";
    }
    $quri->query_form( q => $q );

    return $quri;
};

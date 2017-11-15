package EPrints::Plugin::Import::CitationService::WoSLAMR;

###############################################################################
#
# Web of Science Links AMR API citation ingest.
#
# This plug-in will retrieve citation data from WoS. This data should be
# stored in the "wos" dataset.
#
###############################################################################
#
# Copyright 2016 Queensland University of Technology. All Rights Reserved.
#
#  This file is part of the Citation Count Dataset and Import Plug-ins for GNU
#  EPrints 3.
#
#  Copyright (c) 2015 Queensland University of Technology, Queensland, Australia
#
#  The plug-ins are free software; you can redistribute them and/or modify
#  them under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The plug-ins are distributed in the hope that they will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with EPrints 3; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
######################################################################
#
# May 2016 / Matty K:
#
# - create plugin
#
######################################################################

use strict;

use EPrints::Plugin::Import::CitationService;
our @ISA = ( "EPrints::Plugin::Import::CitationService" );

use LWP::UserAgent;
use Unicode::Normalize qw(NFKC);
use URI;

our $DEBUG;

# service endpoints and namespaces - these can be locally defined (e.g. if you have a Premium account)
our $WOK_CONF = { 'LAMR_ENDPOINT'=>'https://ws.isiknowledge.com/cps/xrpc',
		  'AUTH_USERNAME'=>undef,
		  'AUTH_PASSWORD'=>undef,
		};

#
# Create a new plug-in object.
#
sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters
    $self->{name} = "Web of Science(R) LAMR Citation Ingest";

    # get config parameters
    foreach my $confid ( keys %$WOK_CONF )
    {
	if( defined $self->{session}->config( 'wos-lamr', $confid ) )
	{
	    # locally defined?
	    $WOK_CONF->{$confid} = $self->{session}->config( 'wos-lamr', $confid );
	}
    }

    return $self;
}

#
# Test whether or not this plug-in can hope to retrieve data for a given eprint.
#
sub can_process
{
    my( $plugin, $eprint ) = @_;

    if( $eprint->is_set( "wos_cluster" ) )
    {
	# do not process eprints with ID set to "-"
	return 0 if $eprint->get_value( "wos_cluster" ) eq "-";

	# otherwise, we can use the existing UT to retrieve data
	return 1;
    }

    # Web of Science doesn't contain data for the following types
    my $type = $eprint->get_value( "type" );
    return 0 if $type eq "thesis";
    return 0 if $type eq "other";

    # otherwise, we can (try to) retrieve data if this eprint has a DOI, or title and authors
    return $eprint->is_set( "id_number" ) || ( $eprint->is_set( "title" ) && $eprint->is_set( "creators_name" ) );
}

sub _get_query_xml
{
    my( $session, $eprint ) = @_;

    my $eprintid = $eprint->id;

    # WHO'S REQUESTING
    my $map1 = $session->make_element( 'map' );
    $map1->appendChild( $session->render_data_element( 0, 'val', $WOK_CONF->{AUTH_USERNAME}, 'name'=>'username' ) );
    $map1->appendChild( $session->render_data_element( 0, 'val', $WOK_CONF->{AUTH_PASSWORD}, 'name'=>'password' ) );

    # WHAT'S REQUESTED
    my $map2 = $session->make_element( 'map' );
    my $data_list = $session->make_element( 'list', 'name'=>'WOS' );
    $data_list->appendChild( $session->render_data_element( 0, 'val', 'timesCited' ) );
    $data_list->appendChild( $session->render_data_element( 0, 'val', 'ut' ) );
    $map2->appendChild( $data_list );

    # LOOKUP DATA
    my $map3 = $session->make_element( 'map' );
    my $cite_map = $session->make_element( 'map', 'name'=>"cite_$eprintid" );
    if( $eprint->is_set( 'wos_cluster' ) )
    {
	# Search by UT
	my $ut = $eprint->get_value( 'wos_cluster' );
	$cite_map->appendChild( $session->render_data_element( 0, 'val', $ut, 'name'=>'ut' ) );
    }
    elsif( $eprint->is_set( 'id_number' ) )
    {
	# Search by DOI
	my $doi = $eprint->get_value( 'id_number' );
	$doi =~ s!^http://(dx\.)?doi\.org/!!;
	$doi =~ s!^doi:!!;
	$cite_map->appendChild( $session->render_data_element( 0, 'val', $doi, 'name'=>'doi' ) );
    }
    else
    {
	# Search by metadata
	my $title = $eprint->get_value( 'title' );

	#$cite_map->appendChild( $session->render_data_element( 0, 'val', $title, 'name'=>'atitle' ) );
	# URGH
	my $title_elem = $session->make_element( 'val', 'name'=>'atitle' );
	$title_elem->appendChild( $session->xml->create_cdata_section( $title ) );
	$cite_map->appendChild( $title_elem );

	if( $eprint->is_set( 'date' ) )
	{
	    my $year = substr( $eprint->get_value( 'date' ), 0, 4 );
	    $cite_map->appendChild( $session->render_data_element( 0, 'val', $year, 'name'=>'year' ) );
	}

	my $author_list = $session->make_element( 'list', 'name'=>'authors' );
	my $creators = $eprint->get_value( 'creators_name' );
	foreach my $creator ( @{$creators} )
	{
	    my $author = $creator->{family} . ', ' . substr( $creator->{given}, 0, 1 );
	    $author_list->appendChild( $session->render_data_element( 0, 'val', $author ) );
	}
	$cite_map->appendChild( $author_list );
    }
    $map3->appendChild( $cite_map );

    my $body = '';
    $body .= EPrints::XML::to_string( $map1 );
    EPrints::XML::dispose( $map1 );
    $body .= EPrints::XML::to_string( $map2 );
    EPrints::XML::dispose( $map2 );
    $body .= EPrints::XML::to_string( $map3 );
    EPrints::XML::dispose( $map3 );

    my $xml = <<XML;
<?xml version="1.0" encoding="UTF-8" ?>
<request xmlns="http://www.isinet.com/xrpc42" src="app.id=API Demo">
  <fn name="LinksAMR.retrieve">
    <list>
$body
    </list>
  </fn>
</request>
XML

    utf8::encode( $xml );
    return $xml;
}

sub _post_query
{
    my( $plugin, $query ) = @_;

    use bytes;

    my $ua = LWP::UserAgent->new( conn_cache => $plugin->{conn_cache} );
    if( EPrints::Utils::is_set( $ENV{http_proxy} ) )
    {
	$ua->proxy( 'http', $ENV{http_proxy} );
    }

    my $request = HTTP::Request->new( 'POST', $WOK_CONF->{LAMR_ENDPOINT} );
    $request->header( 'accept'=>'application/xml' );
    $request->header( 'content-type'=>'application/xml;charset=utf-8' );
    $request->header( 'content-length'=>length( $query ) );
    $request->content( $query );

    my $response = $ua->request( $request );
    return $response;
}

#
# Returns an epdata hashref for a citation datum for $eprint or undef
# if no matches were found in the citation service.
#
# Croaks if there are problems receiving or parsing responses from the
# citation service, or if the citation service returns an error
# response.
#
sub get_epdata
{
    my( $plugin, $eprint ) = @_;

    my $session = $plugin->{session};

    my $eprintid = $eprint->id;

    my $query_xml = _get_query_xml( $session, $eprint );

    my $response = $plugin->_post_query( $query_xml );

    if( !$response->is_success )
    {
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The response was: " . $response->status_line ) if $DEBUG;
	return undef;
    }

    # Got a response, now try to parse it
    # FIXME: everything from here down would be so much nicer with XML::XPath
    my $xml_parser = $plugin->{session}->xml;

    my $response_xml = $xml_parser->parse_string( $response->content );

    my $fn = $response_xml->documentElement->getChildrenByTagName( 'fn' )->[ 0 ];
    if( !defined $fn )
    {
	# TODO: look for <error/> element ('code' attr and textContent)
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The response has no <fn/> element." ) if $DEBUG;
	if( $DEBUG )
	{
	    print STDERR $query_xml, "\n\n";
	    print STDERR $response_xml->toString, "\n\n";
	    die 'debug';
	}
	return undef;
    }

    my $rc = $fn->getAttribute( 'rc' );
    if( !defined $rc )
    {
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The <fn/> element in the response has no 'rc' attribute." ) if $DEBUG;
	return undef;
    }

    if( $rc ne 'OK' )
    {
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The response was: $rc" ) if $DEBUG;
	return undef;
    }

    my $outer_map = $fn->getChildrenByTagName( 'map' )->[ 0 ];
    if( !defined $outer_map )
    {
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The response has no outer <map/> element." ) if $DEBUG;
	return undef;
    }

    # FIXME: exactly one?
    my $inner_map = $outer_map->getChildrenByTagName( 'map' )->[ 0 ];
    if( !defined $inner_map )
    {
	$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The response has no inner <map/> element." ) if $DEBUG;
	return undef;
    }

    # FIXME: if $inner_map->getAttribute( 'name' )->value ne "cite_$eprintid" ?
    my $cite_data = $inner_map->getChildrenByTagName( 'map' )->[ 0 ];
    if( !defined $cite_data )
    {
	$plugin->warning(
			"Unable to retrieve data from WoS for eprint $eprintid. The response has no citation <map/> element." ) if $DEBUG;
	return undef;
    }

    # FIXME: if $cite_data->getAttribute( 'name' ) ne 'WOS' ?

    my $timesCited;
    my $ut;
    my $message;
    foreach my $val ( @{ $cite_data->getChildrenByTagName( 'val' ) } )
    {
	my $name = $val->getAttribute( 'name' );
	if( $name && $name eq 'timesCited' )
	{
	    $timesCited = $val->textContent;
	}
	elsif( $name && $name eq 'ut' )
	{
	    $ut = $val->textContent;
	}
	elsif( $name && $name eq 'message' )
	{
	    $message = $val->textContent;
	}
    }

    #if( !defined $timesCited || !defined $ut )
    if( !defined $ut )
    {
	if( $DEBUG )
	{
	    $timesCited //= '';
	    $ut //= '';
	    if( $message )
	    {
		$plugin->warning( "Unable to retrieve data from WoS for eprint $eprintid. The message was: $message" );
	    }
	    else
	    {
	    $plugin->warning(
"Unable to retrieve data from WoS for eprint $eprintid. The response was missing data: timesCited=$timesCited, ut=$ut" );
	    }
	}
	return undef;
    }

    return { cluster=>$ut, impact=>$timesCited };
}

1;

# vim: set ts=8 sts=4 sw=4 :

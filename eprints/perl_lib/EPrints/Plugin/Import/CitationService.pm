package EPrints::Plugin::Import::CitationService;
###############################################################################
#
# Base class for plug-ins that retrieve citation data from a remote service.
#
# This class implements the common functionality for all citation service
# plug-ins. Each plug-in accepts a list of eprint IDs in a text file (one ID
# per line), and queries an external service for citation data for each eprint
# in the input file.
#
# This class implements the input_text_fh function, which parses the input
# file, builds the list of eprints to be processed and inserts the data into
# the dataset supplied by the caller. This function also re-tries failed
# requests according to the "net_retry" parameter.
#
# Each sub-class of CitationService must implement can_process() and
# get_epdata(). See the comments for the individual functions for
# documentation.
#
###############################################################################
#
# Copyright 2011 Queensland University of Technology. All Rights Reserved.
#
#  This file is part of the Citation Count Dataset and Import Plug-ins for GNU
#  EPrints 3.
#
#  Copyright (c) 2011 Queensland University of Technology, Queensland, Australia
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
# May 2013 / gregson:
#
# - Refactored process_eprints() to improve the abstract-concrete
#   class interaction
# - Revised exception handling
# - Removed parse_retry functionality - individual eprints fail on a
#   parse error or other error response from the web service (not
#   transport errors) but processing of remaining eprints continues
#
######################################################################

use strict;

use EPrints::Plugin::Import::TextFile;
our @ISA = ( "EPrints::Plugin::Import::TextFile" );

# disable this plug-in because it is an abstract class
$EPrints::Plugin::Import::CitationService::DISABLE = 1;

#
# Create a new plug-in object.
#
sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new( %params );

    # set some parameters that are common to all sub-classes
    $self->{produce} = [ 'list/citation', 'dataobj/citation' ];
    $self->{visible} = "api";

    return $self;
}

#
# Retrieve citation data for a list of eprint ids in a text file
#
sub input_text_fh
{
    my( $plugin, %opts ) = @_;

    my @eprintids;

    my $fh = $opts{fh};

    while( my $line = <$fh> )
    {
	next if( !( $line =~ /^(\d+)/ ) );
	push @eprintids, $1;
    }

    $opts{eprintids} = \@eprintids;
    my $ids = $plugin->process_eprints( %opts ) || [];

    # clean up
    $plugin->dispose;

    return
      EPrints::List->new( dataset=>$opts{dataset},
			  session=>$plugin->{session},
			  ids=>$ids
			);
}

#
# Retrieve citation counts for all eprints in the live archive.
#
sub process_eprint_dataset
{
    my( $plugin, %opts ) = @_;

    my $list = $plugin->{session}->dataset( 'archive' )->search();
    my @eprintids = @{ $list->ids || [] };

    $opts{eprintids} = \@eprintids;

    my $ids = $plugin->process_eprints( %opts ) || [];

    # clean up
    $plugin->dispose;

    return
      EPrints::List->new( dataset=>$opts{dataset},
			  session=>$plugin->{session},
			  ids=>$ids
			);

}

#
# Retrieve citation counts for all $opts{eprintids} and
# returns a list of IDs successfully retrieved.
#
sub process_eprints
{
    my( $plugin, %opts ) = @_;

    #print STDERR "processing_eprints() \n";

    my $eprintids = $opts{eprintids};

    my @ids;

    # Iterate through each eprint in $eprintids
  EPRINT: foreach my $eprintid ( @{ $eprintids || [] } )
    {
	#print STDERR "eprintid: $eprintid \n";
	my $eprint = $plugin->{session}->eprint( $eprintid );
	if( defined( $eprint ) )
	{
	    next if !$plugin->can_process( $eprint );

	    my $citedata;
	    eval {
		$citedata = $plugin->get_epdata( $eprint );
		1;
	      } or do
	    {
		# Give up if get_epdata() fails and doesn't handle
		# the exception
		$plugin->error( "Error importing cites for EPrint ID $eprintid, skipping ALL eprints: " . $@ );
		last EPRINT;
	    };

	    # Skip to the next eprint if get_response() has returned
	    # undef
	    if( !defined $citedata )
	    {
		$plugin->warning( "No matches found for EPrint ID $eprintid" );
		next EPRINT;
	    }

	    # convert it to a data object
	    $citedata->{referent_id} = $eprintid;
	    $citedata->{datestamp}   = EPrints::Time::get_iso_timestamp();

	    #print STDERR Dumper( $citedata ), "\n";
	    my $dataobj = $plugin->epdata_to_dataobj( $opts{dataset}, $citedata );
	    if( defined $dataobj )
	    {
		#print STDERR "[debug] Cite stored for EPrint ID $eprintid.\n";
		push @ids, $dataobj->get_id;
	    }
	}
	else
	{
	    $plugin->warning( "EPrint ID $eprintid does not exist." );
	}

    }    # End EPRINT

    return \@ids;
}

#
# Check whether or not the plug-in can hope to retrieve citation data
# for an eprint.
#
# Return 1 if the eprint contains sufficient information to get a
# response from the service, and 0 otherwise.
#
sub can_process
{
    my( $plugin, $eprint ) = @_;

    $plugin->error( "EPrints::Plugin::Import::CitationService::can_process must be over-ridden." );

    return 0;
}

#
# Returns an epdata hashref for a citation datum for $eprint or undef
# if no matches were found in the citation service.
#
# Dies if there are problems receiving responses from the citation
# service, and returns undef if the citation service returns an error
# response (to allow service requests for subsequent eprints).
#
sub get_epdata
{
    my( $plugin, $eprint ) = @_;

    $plugin->error( "EPrints::Plugin::Import::CitationService::get_response must be over-ridden." );

    return undef;

}

#
# Perform any clean up required at the end of the importation. This
# default version does nothing.
#
sub dispose
{
    return;
}

1;

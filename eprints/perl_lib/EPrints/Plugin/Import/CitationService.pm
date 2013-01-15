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
# requests according to the "net_retry" and "parse_retry" parameters.
#
# Each sub-class of CitationService must implement the can_process(),
# get_response() and response_to_epdata() functions. See the comments for the
# individual functions for documentation.
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
		next if ( !( $line =~ /^(\d+)/ ) );
		push @eprintids, $1;
	}

	$opts{eprintids} = \@eprintids;
	my $ids = $plugin->process_eprints( %opts ) || [];

	# clean up
	$plugin->dispose;

	return EPrints::List->new( 
		dataset => $opts{dataset}, 
		session => $plugin->{session},
		ids => $ids );
}

sub process_eprint_dataset
{
	my( $plugin, %opts ) = @_;

	my $list = $plugin->{session}->dataset( 'archive' )->search();
	my @eprintids = @{ $list->ids || [] };

	$opts{eprintids} = \@eprintids;

	my $ids = $plugin->process_eprints( %opts ) || [];
	
	# clean up
	$plugin->dispose;

	return EPrints::List->new( 
		dataset => $opts{dataset}, 
		session => $plugin->{session},
		ids => $ids );

}

sub process_eprints
{
	my( $plugin, %opts ) = @_;

	my $eprintids = $opts{eprintids};

	my @ids;

	LINE: foreach my $eprintid ( @{$eprintids||[]} )
	{
		my $eprint = $plugin->{session}->eprint( $eprintid );
		if ( defined( $eprint ) )
		{
			next if !$plugin->can_process( $eprint );

			# get citation data for this eprint, trying up to $plugin->{parse_retry}->{max} times
			my $parse_tries_left = $plugin->{parse_retry}->{max};

			my $citedata = undef;
			my $net_tries_left = $plugin->{net_retry}->{max};
			while ( !defined( $citedata ) && $parse_tries_left > 0 )
			{
				# get a response from the service, trying up to $plugin->{net_retry}->{max} times
				my $response = undef;
				while ( !defined( $response ) && $net_tries_left > 0 )
				{
					$response = $plugin->get_response( $eprint );
					if ( !defined( $response ) && $net_tries_left > 0 )
					{
						# no response; go to sleep before trying again
						$plugin->warning(
							"No response for EPrints ID " . $eprint->get_id . ". " .
							"Waiting " . $plugin->{net_retry}->{interval} . " seconds before trying again."
						);
						sleep( $plugin->{net_retry}->{interval} );
						$net_tries_left--;
					}
				}

				# if $response is undefined, the server is not responding
				if ( !defined( $response ) )
				{
					$plugin->error( "No response after " . $plugin->{net_retry}->{max} . " attempts. Giving up." );
					last LINE;
				}

				# got a response; now try to parse it
				$citedata = $plugin->response_to_epdata( $eprint, $response );
				$parse_tries_left--;
				if ( defined( $citedata ) )
				{
					# if there are keys in the hash, there was a hit
					if ( scalar keys %{$citedata} > 0 ) {
						# convert it to a data object
						$citedata->{referent_id} = $eprint->get_id;
						$citedata->{datestamp} = EPrints::Time::get_iso_timestamp();
						my $dataobj = $plugin->epdata_to_dataobj( $opts{dataset}, $citedata );
						if ( defined( $dataobj ) )
						{
							push @ids, $dataobj->get_id;
						}
					}
				}
				elsif ( $parse_tries_left > 0 )
				{
					# malformed response; go to sleep before trying again
					$plugin->warning(
						"Waiting " . $plugin->{parse_retry}->{interval} . " before trying again."
					);
					sleep( $plugin->{parse_retry}->{interval} );
				}
			}

			# if $citedata is undefined, the server is sending back stuff we can't parse
			if ( !defined( $citedata ) )
			{
				$plugin->error( "Got " . $plugin->{parse_retry}->{max} . " malformed responses. Giving up." );
				next LINE;

			}

		}
		else
		{
			$plugin->warning( "EPrint ID " . $eprintid . " does not exist." );
		}
	}

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
	my ( $plugin, $eprint ) = @_;

	$plugin->error( "EPrints::Plugin::Import::CitationService::can_process must be over-ridden." );

	return 0;
}


#
# Get a response from the citation data service but don't parse it.
#
# The return value from this function will be passed to
# response_to_epdata() at a later time.
#
# Return an undefined value if the service didn't respond, or responded
# with an error.
#
sub get_response
{
	my ( $plugin, $eprint ) = @_;

	$plugin->error( "EPrints::Plugin::Import::CitationService::get_response must be over-ridden." );

	return undef;

}


#
# Convert the response from an external service to an "epdata" hash
# suitable for processing by EPrints::Plugin::Import::epdata_to_dataobj().
#
# Return a hash with no keys of the response indicates that the service has
# no data for this eprint.
#
# Return an undefined value if the response could not be parsed.
#
sub response_to_epdata
{
	my ( $plugin, $eprint, $response ) = @_;

	$plugin->error( "EPrints::Plugin::Import::CitationService::get_cites must be over-ridden." );

	return undef;

}


#
# Perform any clean up required at the end of the importation. This
# default version does nothing.
#
sub dispose
{
}

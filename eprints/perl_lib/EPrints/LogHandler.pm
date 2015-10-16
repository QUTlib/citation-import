package EPrints::LogHandler;
###############################################################################
#
# Log handler for scripts.
#
# This class is a re-implementation of EPrints::CLIProcessor oriented towards
# storing data in a log file instead of printing it to the screen.
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

#
# Create a new log handler.
#
# The members of %params are:
#  session - the EPrints session (mandatory)
#  logfile - the name of the log file (default: standard output)
#  prefix  - a string that will appear at the beginning of each line (optional)
#  stderr  - set to 1 to repeat errors to STDERR (default: 0)
#
sub new
{
    my( $class, %params ) = @_;

    my %self;
    bless \%self;

    # save some parameters
    $self{session} = $params{session};
    $self{prefix}  = $params{prefix};
    $self{stderr}  = ( defined $params{stderr} ) ? $params{stderr} : 0;

    # initialise member variables
    $self{parsed} = 0;
    $self{wrote}  = 0;
    $self{ids}    = [];

    # open the log file
    $self{fh} = undef;
    if( defined( $params{logfile} ) )
    {
	open( $self{fh}, ">>:utf8", $params{logfile} ) || return undef;
    }
    else
    {
	open( $self{fh}, ">-:utf8" );
    }

    return \%self;
}

#
# Add a message to the log
#
*add_message = \&message;

sub message
{
    my( $self, $type, $msg ) = @_;

    # this will contain the output string
    my $str = "";

    # insert the prefix, if desired
    if( defined $self->{prefix} )
    {
	$str = $str . "[" . $self->{prefix} . "] ";
    }

    $msg = EPrints::Utils::tree_to_utf8( $msg );
    if( $type eq "warning" )
    {
	$str = $str . "Warning: $msg";
    }
    elsif( $type eq "error" )
    {
	$str = $str . "Error: $msg";
    }
    elsif( defined $type )
    {
	# don't know what this is; use the same behaviour as CLIProcessor
	$str = $str . "$type: $msg";
    }
    else
    {
	$str = $str . $msg;
    }

    # output to the log
    print { $self->{fh} } "$str\n";

    # report errors to STDERR, if desired
    if( $self->{stderr} && $type eq "error" )
    {
	print STDERR "$str\n";
    }
}

#
# Handle a "parsed item" event
#
sub parsed
{
    my( $self, $epdata ) = @_;

    $self->{parsed}++;

    if( $self->{session}->get_noise > 1 )
    {
	print { $self->{fh} } "Item parsed.\n";
    }
}

#
# Handle a "new object" event
#
sub object
{
    my( $self, $dataset, $dataobj ) = @_;

    $self->{wrote}++;

    push @{ $self->{ids} }, $dataobj->get_id;

    if( $self->{session}->get_noise > 1 )
    {
	print { $self->{fh} } "Imported " . $dataset->id . " " . $dataobj->get_id . "\n";
    }
}

=item $dataobj = $processor->epdata_to_dataobj( $epdata, %opts )

Requests the handler create the new object from $epdata.

=cut

sub epdata_to_dataobj
{
    my( $self, $epdata, %opts ) = @_;

    return $self->{epdata_to_dataobj}( $epdata, %opts ) if defined $self->{epdata_to_dataobj};

    return $opts{dataset}->create_dataobj( $epdata );
}

1;

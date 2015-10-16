package EPrints::DataObj::CitationDatum;
###############################################################################
#
# Citation datum data object.
#
# This data object stores the results of a single (successful) querty for
# citation data from an external servce.
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

use EPrints::DataObj;
our @ISA = ( "EPrints::DataObj" );

#
# Define the fields for objects in this dataset.
#
sub get_system_field_info
{
    my( $class ) = @_;

    return (
	# unique id
	{  name=>"datumid",
	   type=>"counter",
	   sql_counter=>"datumid",
	   required=>1,
	},

	# source
	{  name=>"source",
	   type=>"set",
	   options=>[ qw/ scopus wos gscholar / ],
	   required=>1,
	},

	# the eprint to which this datum refers
	{  name=>"referent_id",
	   type=>"int",
	   required=>1,
	},

	# datestamp
	{  name=>"datestamp",
	   type=>"time",
	   required=>1,
	},

	# number of times cited
	{  name=>"impact",
	   type=>"int",
	   required=>0,
	},

	# the data source's id for this record
	{  name=>"cluster",
	   type=>"id",
	   required=>0,
	},
    );

}

#
# Get the dataset id
#
sub get_dataset_id
{
    return "citation";
}

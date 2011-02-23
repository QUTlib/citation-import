package EPrints::DataObj::CitationDatum;
###############################################################################
#
# Citation datum data object.
#
# This data object stores the results of a single (successful) querty for
# citation data from an external servce.
#
###############################################################################

use strict;

use EPrints::DataObj;
our @ISA = ( "EPrints::DataObj" );

#
# Define the fields for objects in this dataset.
#
sub get_system_field_info
{
	my ( $class ) = @_;

	return
	(
		# unique id
		{
			name => "datumid",
			type => "counter",
			sql_counter => "datumid",
			required => 1,
		},

		# source
		{
			name => "source",
			type => "set",
			options => [qw/ scopus wos gscholar /],
			required => 1,
		},

		# the eprint to which this datum refers
		{
			name => "referent_id",
			type => "int",
			required => 1,
		},

		# datestamp
		{
			name => "datestamp",
			type => "time",
			required => 1,
		},

		# number of times cited
		{
			name => "impact",
			type => "int",
			required => 0,
		},

		# the data source's id for this record
		{
			name => "cluster",
			type => "id",
			required => 0,
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

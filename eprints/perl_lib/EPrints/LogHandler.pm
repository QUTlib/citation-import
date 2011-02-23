package EPrints::LogHandler;
###############################################################################
#
# Log handler for scripts.
#
# This class is a re-implementation of EPrints::CLIProcessor oriented towards
# storing data in a log file instead of printing it to the screen.
#
###############################################################################

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
	my ( $class, %params ) = @_;

	my %self;
	bless \%self;

	# save some parameters
	$self{session} = $params{session};
	$self{prefix} = $params{prefix};
	$self{stderr} = ( defined $params{stderr} )? $params{stderr} : 0;

	# initialise member variables
	$self{parsed} = 0;
	$self{wrote} = 0;
	$self{ids} = [];

	# open the log file
	$self{fh} = undef;
	if ( defined( $params{logfile} ) )
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
	my ( $self, $type, $msg ) = @_;

	# this will contain the output string
	my $str = "";

	# insert the prefix, if desired
	if ( defined $self->{prefix} )
	{
		$str = $str . "[" . $self->{prefix} . "] ";
	}

	$msg = EPrints::Utils::tree_to_utf8( $msg );
	if ( $type eq "warning" )
	{
		$str = $str . "Warning: $msg";
	}
	elsif ( $type eq "error" )
	{
		$str = $str . "Error: $msg";
	}
	elsif ( defined $type )
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
	if ( $self->{stderr} && $type eq "error" )
	{
		print STDERR "$str\n";
	}
}


#
# Handle a "parsed item" event
#
sub parsed
{
	my ( $self, $epdata ) = @_;

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
	my ( $self, $dataset, $dataobj ) = @_;

	$self->{wrote}++;

	push @{$self->{ids}}, $dataobj->get_id;

	if( $self->{session}->get_noise > 1 )
	{
		print { $self->{fh} } "Imported ". $dataset->id . " " . $dataobj->get_id . "\n";
	}
}

1;

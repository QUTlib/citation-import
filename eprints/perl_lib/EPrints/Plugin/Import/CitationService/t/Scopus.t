 #!/usr/bin/env perl
use lib qw(/opt/eprints3/perl_lib);
use lib qw(/opt/eprints3/archives/quteprints/cfg/plugins);

# The test data contains Unicode so this file should be saved as UTF-8
use utf8;

use strict;
use warnings;

use EPrints;
use Test::More;

BEGIN { use_ok( 'EPrints::Plugin::Import::CitationService::Scopus' ); }

binmode( Test::More->builder->output, ':encoding(UTF-8)' );
binmode( Test::More->builder->failure_output, ':encoding(UTF-8)' );

# Create some eprint records stubs with an epdata hash

# These ones shouldn't be expected to match in Scopus for one reason
# or another
my $nomatches_epdata = [
	    {
                title => 'Analysis of Virtual Method Invocation for Binary Translation',
                creators => [
			  {
			   name => {
				    family => 'Tröger',
				   },
			  },
                      ],
                date => '2002',
                eprint_status => 'inbox',
            },
	    {
                # This one doesn't match because Scopus uses some
                # character other than the mid dot
                title => 'Thermal stability of the ‘cave’ mineral ardealite Ca2(HPO4)(SO4)•4H2O',
                creators => [
			  {
			   name => {
				    family => 'Frost',
				   },
			  },
			 ],
             date => '2012',
	     eprint_status => 'inbox',
	    },
	    {
	     title => '"I’m making it different to the book” : transmediation in young children’s print and digital texts',
	     creators => [
			  {
			   name => {
				    family => 'Mills',
				   },
			  },
			 ],
             date => '2011',
	     eprint_status => 'inbox',
	    },
            # It's not clear why this one doesn't match -- it can't
            # even be matched from the Scopus search form if you try
            # to match the ℝ char
	    {
	     title => 'Ligthlike ruled surfaces in ℝ1 4',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Kiliç',
	        		   },
	        	  },
	        	 ],
             date => '2006',
	     eprint_status => 'inbox',
	    },
];


# These ones should match in Scopus
my $matches_epdata = [
	    {
	     title => 'Market shares, R&D agreements, and the EU block exemption',
	     creators => [
			  {
			   name => {
				    family => 'Ruble',
				   },
			  },
			 ],
             date => '2014',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Which tests do neuropsychologists use?',
	     creators => [
			  {
			   name => {
				    family => 'Sullivan',
				   },
			  },
			 ],
             date => '1997',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Carbon monoxide and isocyanide complexes of trivalent uranium metallocenes',
	     creators => [
			  {
			   name => {
				    family => 'del Mar Conejo',
				   },
			  },
			 ],
             date => '1999',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Is adiponectin implicated in venous thromboembolism?',
	     creators => [
			  {
			   name => {
				    family => 'Fernández',
				   },
			  },
			 ],
             date => '2006',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Optically inspired biomechanical model of the human eyeball',
	     creators => [
			  {
			   name => {
				    family => 'Śródka',
				   },
			  },
			 ],
             date => '2008',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Audit Firm Manuals and Audit Experts’ Approaches to Internal Control Evaluation',
	     creators => [
			  {
			   name => {
				    family => 'O’Leary',
				   },
			  },
			 ],
             date => '2006',
	     eprint_status => 'inbox',
	    },
	    {
                # Same as above with apostrophes instead of curly
                # single quotes
	     title => 'Audit Firm Manuals and Audit Experts\' Approaches to Internal Control Evaluation',
	     creators => [
			  {
			   name => {
				    family => 'O\'Leary',
				   },
			  },
			 ],
             date => '2006',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Burden of care and general health in families of patients with schizophrenia',
	     creators => [
			  {
			   name => {
				    family => 'Gutiérrez-Maldonado',
				   },
			  },
			 ],
             date => '2005',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Sign consumption in the 19th century department store: An examination of visual merchandising in the grand emporiums (1846-1900)',
	     creators => [
			  {
			   name => {
				    family => 'Parker',
				   },
			  },
			 ],
             date => '2003',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Hydrogen bonding in 1:1 proton-transfer compounds of 5-sulfosalicylic acid with 4- X-substituted anilines (X = F, Cl or Br)',
	     creators => [
			  {
			   name => {
				    family => 'Smith',
				   },
			  },
			 ],
             date => '2005',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Paul D. Reynolds : entrepreneurship research innovator, coordinator, and disseminator',
	     creators => [
			  {
			   name => {
				    family => 'Davidsson',
				   },
			  },
			 ],
             date => '2005',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Why justice? Which justice? Impartiality or objectivity?',
	     creators => [
			  {
			   name => {
				    family => 'Rasmussen',
				   },
			  },
			 ],
             date => '2013',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'The national programme of digitisation of archival, library and museum holdings and the project "Croatian Cultural Heritage"',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Seiter-Šverko',
	        		   },
	        	  },
	        	 ],
             date => '2013',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Compressive deformation behaviour of nanocrystalline Al-5 at.% Ti alloys prepared by reactive ball milling in H2 and ultra high-pressure hot pressing',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Moon',
	        		   },
	        	  },
	        	 ],
             date => '2002',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'The classiﬁcation and nomenclature of endogenous viruses of the family Caulimoviridae',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Geering',
	        		   },
	        	  },
	        	 ],
             date => '2010',
	     eprint_status => 'inbox',
	    },
	    {
	     title => '(Qs̄)(*)(Qs̄)(*) molecular states from QCD sum rules: A view on Y(4 1 4 0)',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Zhang',
	        		   },
	        	  },
	        	 ],
             date => '2010',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Stability of the d-wave resonating-valence-bond state against the 1 4(π/2)-flux phase state on a triangular lattice',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Wang',
	        		   },
	        	  },
	        	 ],
             date => '1992',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Theoretical surface morphology of {0 1 1̄ 2} acute rhombohedron of calcite. A comparison with experiments and {1 0 1̄ 4} cleavage rhombohedron',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Massaro',
	        		   },
	        	  },
	        	 ],
             date => '2008',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Kaolinite particle sizes in the <2 μM range using laser scattering',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Mackinnon',
	        		   },
	        	  },
	        	 ],
             date => '1993',
	     eprint_status => 'inbox',
	    },
	    {
	     title => 'Scaling of free convection heat transfer in a triangular cavity for Pr>1',
	     creators => [
	        	  {
	        	   name => {
	        		    family => 'Saha',
	        		   },
	        	  },
	        	 ],
             date => '2011',
	     eprint_status => 'inbox',
	    },
	   ];


# Setup repo
my $eprints = EPrints->new();
my $repo = $eprints->repository( 'quteprints' );
my $ds = $repo->dataset( 'eprint' );

my $plugin = $repo->plugin( 'Import::CitationService::Scopus' );

test_eprints( $nomatches_epdata, 0 );
test_eprints( $matches_epdata, 1 );

sub test_eprints
{
    my ( $eprints, $check_for_match ) = @_;

    # Create an eprint for each item of test data, query Scopus and
    # check what happened
    foreach my $test_item ( @{$eprints} )
    {
        my $eprint = $plugin->epdata_to_dataobj( $ds, $test_item );
        my $querystring = $plugin->_get_querystring_metadata( $eprint );
        my $quri = $plugin->_get_query_uri( $querystring );
        my $response = $plugin->_call( $quri, 0, 0 );

        # Give up if there is a problem with the HTTP connection
        if ( !defined $response )
        {
            fail( 'HTTP transport error, can\'t test.' );
            last;
        }
        ;

        #print STDERR $response->content, "\n";

        # Fail if a non-OK status code was returned
        my $status_code = _parse_element_content( $response->content, 'statusCode' );
        if ( !is( $status_code, 'OK', 'query returned OK status' ) )
        {
            diag( 'Title: ' . $test_item->{title} );
            diag( 'Status code: ' . $status_code .
                  ': Error detail: ' . _parse_element_content( $response->content, 'detail' ) );
            diag ( 'Query: ' . $quri->as_string );
        }
        elsif ( $check_for_match )
        {
            if ( !ok( _parse_element_content( $response->content, 'totalResults' ) > 0, 'Match found' ) )
            {
                diag( 'Title: ' . $test_item->{title} );
                diag ( 'Query: ' . $quri->as_string );
            }
        }
    }
}


done_testing();


#
# Returns the text content of element in $xml_string called $tagname,
# or an empty string if the tag wasn't found
#
# Assumes the element is a simple name-value pair, e.g.,
# <name>data</name>.  The starting tag can have attributes and it does
# they are ignored.
#
sub _parse_element_content
  {
    my ( $xml_string, $tagname ) = @_;
    return $1 if ( $xml_string =~ m/<${tagname}[^>]*>([^<]+)/g );
    return '';
  }


1;

#
# Citation datasets
#
# Each object in the "citation" dataset stores the results of a request for
# citation data from some third-party source. The structure of the record is
# based on the structure of the "gscholar" field defined in the default
# version of eprint_fields.pl
#

use EPrints::DataObj::CitationDatum;

# base dataset for all citation data
$c->{datasets}->{citation} = { class     => "EPrints::DataObj::CitationDatum",
			       sqlname   => "citation",
			       datestamp => "datestamp",
			       pluginmap => { scopus   => "Import::CitationService::Scopus",
					      wos      => "Import::CitationService::WoS",
					      gscholar => "Import::CitationService::GScholar",
			       },
};

# virtual dataset for Scopus data
$c->{datasets}->{scopus} = { class            => "EPrints::DataObj::CitationDatum",
			     sqlname          => "citation",
			     confid           => "citation",
			     dataset_id_field => "source",
			     filters          => [ { meta_fields => [ 'source' ], value => 'scopus', describe => 0 } ],
			     datestamp        => "datestamp",
			     virtual          => 1,
			     import           => 1,
};

# virtual dataset for Web of Science data
$c->{datasets}->{wos} = { class            => "EPrints::DataObj::CitationDatum",
			  sqlname          => "citation",
			  confid           => "citation",
			  dataset_id_field => "source",
			  filters          => [ { meta_fields => [ 'source' ], value => 'wos', describe => 0 } ],
			  datestamp        => "datestamp",
			  virtual          => 1,
			  import           => 1,
};

# virtual dataset for Google Scholar data
$c->{datasets}->{gscholar} = { class            => "EPrints::DataObj::CitationDatum",
			       sqlname          => "citation",
			       confid           => "citation",
			       dataset_id_field => "source",
			       filters          => [ { meta_fields => [ 'source' ], value => 'gscholar', describe => 0 } ],
			       datestamp        => "datestamp",
			       virtual          => 1,
			       import           => 1,
};

# when we receive new citation data, cache it in the eprint object to which it refers
$c->add_dataset_trigger(
    "citation",
    EP_TRIGGER_CREATED,
    sub {
	my( %o ) = @_;

	my $datum  = $o{"dataobj"};
	my $eprint = $datum->get_session->eprint( $datum->get_value( "referent_id" ) );
	if( defined( $eprint ) && $eprint->get_dataset->has_field( $datum->get_value( "source" ) ) )
	{
	    my $cache = { impact    => $datum->get_value( "impact" ),
			  cluster   => $datum->get_value( "cluster" ),
			  datestamp => $datum->get_value( "datestamp" ),
	    };
	    $eprint->set_value( $datum->get_value( "source" ), $cache );
	    $eprint->commit();
	}

    }
);

